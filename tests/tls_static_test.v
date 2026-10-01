// vtest build: linux && vanilla_tls?
// Static files over HTTPS on the epoll TLS worker. A static_assets body of at
// least sendfile_min_bytes leaves a kernel-TLS connection with sendfile(2):
// the headers go out with MSG_MORE and the kernel encrypts the file into
// their record, with no userspace copy. A userspace-TLS connection never takes
// a file (sendfile writes plaintext): its handler appends the bytes, from RAM
// (memory_fallback, the /static/ mount here) or read from disk (the /disk/
// mount). Every case runs on both paths: with the default config, which
// engages kTLS when the `tls` kernel module is loaded (/sys/module/tls), and
// with cfg.set_ktls(false). Each case checks the path it got: the connection's
// TCP ULP (a handler route reads it) and, on kTLS, a rise of TlsTxSw in
// /proc/net/tls_stat; a case that serves static bodies also checks that
// static_assets handed some to sendfile on kTLS and none on userspace TLS.
// Without the module both runs take the userspace path and the kTLS-only
// asserts are skipped.
//
// Only runs with `-d vanilla_tls` on Linux (see tls_timeouts_test.v; the
// client and backstops follow tls_pipelining_test.v). The leak case only
// measures under -gc none, where nothing is freed:
//
//   sudo modprobe tls   # exercise kTLS; the suite also runs without it
//   v -cc gcc -no-parallel -d vanilla_tls test tests/tls_static_test.v
//   v -gc none -cc gcc -no-parallel -d vanilla_tls test tests/tls_static_test.v
//
// No Limits: a stranded response then hangs instead of being reaped, and the
// openssl read timeout is only the hang backstop — a regression fails the
// elapsed assert or the byte compare, it never blocks forever.
import os
import time
import net.openssl
import server
import core
import tls
import static_assets
import sync.stdatomic
import vtest

#include <netinet/tcp.h>

// static_assets serves bodies of at least one TLS record (16 KiB) with
// sendfile(2) where it can: the size HttpArena configures.
const ts_threshold = i64(16 * 1024)
// The served bundle: one body below the threshold, the rest above it.
const ts_small_len = 1000
const ts_mid_len = 47 * 1024 + 123 // the size of a large static-tls variant
const ts_big_len = 1 << 20
const ts_app_len = 3000
const ts_app_br_len = 20000
// A raw route's file that is shorter than the Content-Length it is sent
// under (the file shrank after the head was built), and a raw route's
// file sent by a step that closes.
const ts_short_len = 10
const ts_short_promise = i64(100000)
const ts_close_len = 2000
const ts_short_head = 'HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nConnection: keep-alive\r\n\r\n'.bytes()
const ts_close_head = 'HTTP/1.1 200 OK\r\nContent-Length: 2000\r\nConnection: close\r\n\r\n'.bytes()
const ts_ok_req = 'GET /ok HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const ts_ok_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
const ts_ulp_req = 'GET /ulp HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const ts_ulp_head = 'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n'.bytes()
const ts_bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
// Requests in the leak case, after a warm-up that takes every buffer to its
// high-water mark. The bound catches a leak of about 100 bytes per request (a
// 47 KiB copy would be about 235 MB); the measured growth is 0 under -gc none
// and at most 24 KiB under -race.
const ts_leak_requests = 5000
const ts_leak_warmup = 200
const ts_leak_max_growth = i64(512 * 1024)
// Hang backstop for the openssl client only (see the header).
const ts_backstop = time.Duration(5 * time.second)
// Every exchange below completes in milliseconds on loopback (the slow
// reader's in a few hundred); this bound stays far below the backstop.
const ts_bound_ms = 3000
// How long a client that stops reading waits for the TLS worker to park
// (see tls_pipelining_test.v): only reaching the park depends on it.
const ts_park_wait = time.Duration(200 * time.millisecond)

// TsFixture is one case's bundle on disk, its two asset servers and the raw
// routes' files. The handler reads it through a pointer: every field is set
// before the server starts and only the counters change after.
@[heap]
struct TsFixture {
	root   string
	assets string // the static_assets root
mut:
	mem        static_assets.AssetServer // /static/: memory_fallback, as HttpArena configures it
	disk       static_assets.AssetServer // /disk/: no RAM copy, a userspace connection reads the file
	short_file os.File
	close_file os.File
	accepted   &core.Counter = unsafe { nil } // core.queue_file hand-offs the worker accepted
	handed     &core.Counter = unsafe { nil } // static_assets bodies left to core.queue_file (see ts_handed_off)
}

// ts_pattern is `n` pseudo-random bytes (xorshift32 from `seed`): a body
// that is shifted, cut, duplicated or mixed with another never compares
// equal.
fn ts_pattern(n int, seed u32) []u8 {
	mut b := []u8{len: n}
	mut x := seed * 2654435761 + 1
	for i in 0 .. n {
		x ^= x << 13
		x ^= x >> 17
		x ^= x << 5
		b[i] = u8(x)
	}
	return b
}

// ts_unbufferable_len is a body size the kernel cannot hold while a
// ts_slow_reader client is not reading (tp_unbufferable_len in
// tls_pipelining_test.v): more than the server's largest send buffer plus the
// client's locked receive buffer.
fn ts_unbufferable_len() int {
	mem := (os.read_file('/proc/sys/net/ipv4/tcp_wmem') or { '' }).fields() // min default max
	return (1 << 20) + if mem.len == 3 { mem[2].int() } else { 32 << 20 }
}

// ts_fixture writes a fresh bundle under a per-case directory and loads it
// twice: follow_disk with revalidate_ms 0, so every request sees the file as
// it is now. `huge` adds huge.bin, a body the kernel cannot buffer.
fn ts_fixture(tag string, huge bool) !&TsFixture {
	root := os.join_path(os.temp_dir(), 'vanilla_tls_static_${tag}_${os.getpid()}')
	os.rmdir_all(root) or {}
	assets := os.join_path(root, 'assets')
	raw := os.join_path(root, 'raw')
	os.mkdir_all(assets)!
	os.mkdir_all(raw)!
	os.write_file_array(os.join_path(assets, 'small.txt'), ts_pattern(ts_small_len, 1))!
	os.write_file_array(os.join_path(assets, 'mid.bin'), ts_pattern(ts_mid_len, 2))!
	os.write_file_array(os.join_path(assets, 'big.bin'), ts_pattern(ts_big_len, 3))!
	os.write_file_array(os.join_path(assets, 'app.js'), ts_pattern(ts_app_len, 4))!
	os.write_file_array(os.join_path(assets, 'app.js.br'), ts_pattern(ts_app_br_len, 5))!
	if huge {
		os.write_file_array(os.join_path(assets, 'huge.bin'), ts_pattern(ts_unbufferable_len(),
			6))!
	}
	os.write_file_array(os.join_path(raw, 'short.bin'), ts_pattern(ts_short_len, 7))!
	os.write_file_array(os.join_path(raw, 'close.bin'), ts_pattern(ts_close_len, 8))!
	mem := static_assets.new(static_assets.Config{
		root:               assets
		url_prefix:         '/static/'
		spa_fallback:       ''
		sendfile_min_bytes: ts_threshold
		follow_disk:        true
		revalidate_ms:      0
		memory_fallback:    true
	})!
	disk := static_assets.new(static_assets.Config{
		root:               assets
		url_prefix:         '/disk/'
		spa_fallback:       ''
		sendfile_min_bytes: ts_threshold
		follow_disk:        true
		revalidate_ms:      0
	})!
	return &TsFixture{
		root:       root
		assets:     assets
		mem:        mem
		disk:       disk
		short_file: os.open(os.join_path(raw, 'short.bin'))!
		close_file: os.open(os.join_path(raw, 'close.bin'))!
		accepted:   &core.Counter{}
		handed:     &core.Counter{}
	}
}

// ts_cleanup closes the raw routes' files and removes the bundle. The asset
// servers' own fds stay open: a snapshot's fd is never closed.
fn ts_cleanup(mut fx TsFixture) {
	fx.short_file.close()
	fx.close_file.close()
	os.rmdir_all(fx.root) or {}
}

// ts_target_is reports whether the request target starts with `prefix`,
// without allocating (the leak case runs it on every request).
@[direct_array_access]
fn ts_target_is(req []u8, prefix string) bool {
	mut sp := 0
	for sp < req.len && req[sp] != ` ` {
		sp++
	}
	start := sp + 1
	return start + prefix.len <= req.len
		&& unsafe { vmemcmp(&req[start], prefix.str, prefix.len) } == 0
}

// ts_ulp_is_tls reports whether the kernel TLS ULP is attached to the
// connection: kTLS engaged.
fn ts_ulp_is_tls(fd int) bool {
	mut name := [16]u8{}
	mut l := u32(16)
	if C.getsockopt(fd, C.IPPROTO_TCP, C.TCP_ULP, &name[0], &l) != 0 {
		return false
	}
	return l >= 3 && name[0] == `t` && name[1] == `l` && name[2] == `s`
}

// ts_handed_off reports whether the answer static_assets just appended at
// res[from..] left its body to core.queue_file: its head promises more body
// than follows it. A HEAD answer promises a body it never carries, so it does
// not count. Allocation-free (the leak case runs it on every request).
@[direct_array_access]
fn ts_handed_off(req []u8, res []u8, from int) bool {
	if req.len > 0 && req[0] == `H` {
		return false
	}
	key := '\r\nContent-Length: '
	mut clen := i64(-1)
	for i := from; i + 3 < res.len; i++ {
		if res[i] == `\r` && res[i + 1] == `\n` && res[i + 2] == `\r` && res[i + 3] == `\n` {
			return clen > i64(res.len - i - 4)
		}
		if clen < 0 && i + key.len <= res.len
			&& unsafe { vmemcmp(&res[i], key.str, key.len) } == 0 {
			clen = 0
			for j := i + key.len; j < res.len && res[j] >= `0` && res[j] <= `9`; j++ {
				clen = clen * 10 + i64(res[j] - `0`)
			}
		}
	}
	return false
}

// ts_handler serves /static/ and /disk/ through static_assets (counting the
// bodies it hands off in fx.handed), and raw routes that hand a file to the
// worker themselves:
//   /short    Content-Length ts_short_promise over a ts_short_len file;
//   /gone     the same head over a region that starts at that file's end (the
//             file was truncated under it): sendfile(2) sends nothing;
//   /close    a whole file, by a step that returns .close;
//   /suspend  queues a file, then returns .suspend (the TLS worker drops it);
//   /ulp      "tls" when the connection runs kTLS, else "---";
//   anything else: ts_ok_resp.
// A route whose hand-off the worker refuses (core.queue_file false: a
// userspace-TLS connection) appends the bytes itself.
fn ts_handler(fx &TsFixture) core.Handler {
	return fn [fx] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		if ts_target_is(req, '/static/') {
			from := res.len
			fx.mem.respond_into(req, mut res) or {
				res << ts_bad_request
				return .close
			}
			if ts_handed_off(req, res, from) {
				stdatomic.add_i64(&fx.handed.n, 1)
			}
			return .done
		}
		if ts_target_is(req, '/disk/') {
			from := res.len
			fx.disk.respond_into(req, mut res) or {
				res << ts_bad_request
				return .close
			}
			if ts_handed_off(req, res, from) {
				stdatomic.add_i64(&fx.handed.n, 1)
			}
			return .done
		}
		if ts_target_is(req, '/short') {
			res << ts_short_head
			if core.queue_file(fx.short_file.fd, 0, ts_short_promise) {
				stdatomic.add_i64(&fx.accepted.n, 1)
				return .done
			}
			if core.append_file_region(mut res, fx.short_file.fd, 0, ts_short_promise) < ts_short_promise {
				return .close // the file is shorter than the head says: end the response here
			}
			return .done
		}
		if ts_target_is(req, '/gone') {
			res << ts_short_head
			if core.queue_file(fx.short_file.fd, ts_short_len, ts_short_promise) {
				stdatomic.add_i64(&fx.accepted.n, 1)
				return .done
			}
			return .close // nothing past the file's end: end the response here
		}
		if ts_target_is(req, '/close') {
			res << ts_close_head
			if core.queue_file(fx.close_file.fd, 0, ts_close_len) {
				stdatomic.add_i64(&fx.accepted.n, 1)
			} else {
				core.append_file_region(mut res, fx.close_file.fd, 0, ts_close_len)
			}
			return .close
		}
		if ts_target_is(req, '/suspend') {
			if core.queue_file(fx.close_file.fd, 0, ts_close_len) {
				stdatomic.add_i64(&fx.accepted.n, 1)
			}
			return .suspend
		}
		if ts_target_is(req, '/ulp') {
			res << ts_ulp_head
			if ts_ulp_is_tls(client_fd) {
				res << `t`
				res << `l`
				res << `s`
			} else {
				res << `-`
				res << `-`
				res << `-`
			}
			return .done
		}
		res << ts_ok_resp
		return .done
	}
}

// ts_start serves fx over HTTPS on one epoll TLS worker (so every connection
// of a case shares one thread's sendfile slot). ktls false turns kernel TLS
// off on the config: every connection stays on userspace Mbed TLS.
fn ts_start(fx &TsFixture, ktls bool) !&vtest.Harness {
	os.signal_ignore(.pipe) // see tt_start in tls_timeouts_test.v
	$if linux {
		cfg := tls.new_self_signed()!
		if !ktls {
			cfg.set_ktls(false)
		}
		return vtest.start(server.ServerConfig{
			io_multiplexing: .epoll
			workers:         1
			tls_config:      cfg
			handler:         ts_handler(fx)
		})
	} $else {
		return error('the TLS worker is the Linux epoll backend')
	}
}

// ts_expect_ktls reports whether a run asked for kTLS gets it: only when the
// `tls` kernel module is loaded.
fn ts_expect_ktls(ktls bool) bool {
	return ktls && os.exists('/sys/module/tls')
}

// ts_tls_tx is the kernel's count of TLS TX sessions installed in software so
// far (TlsTxSw), or -1 without /proc/net/tls_stat.
fn ts_tls_tx() i64 {
	stat := os.read_file('/proc/net/tls_stat') or { return -1 }
	for line in stat.split_into_lines() {
		f := line.fields()
		if f.len == 2 && f[0] == 'TlsTxSw' {
			return f[1].i64()
		}
	}
	return -1
}

// --- openssl client helpers (return values; asserts stay in the scenario fn,
// docs/VTEST.md rule 1) -------------------------------------------------------

fn ts_dial(port int) !&openssl.SSLConn {
	mut c := openssl.new_ssl_conn(validate: false)!
	c.dial('127.0.0.1', port)!
	c.set_read_timeout(ts_backstop)
	return c
}

fn ts_close(mut c openssl.SSLConn) {
	c.shutdown() or {}
}

// ts_get is GET `path`, with `extra` header lines (each ending in CRLF).
fn ts_get(path string, extra string) []u8 {
	return 'GET ${path} HTTP/1.1\r\nHost: x\r\n${extra}\r\n'.bytes()
}

// ts_read_n reads until n bytes of plaintext arrived, the connection ended or
// the backstop fired, and returns what arrived.
fn ts_read_n(mut c openssl.SSLConn, n int) []u8 {
	mut acc := []u8{cap: n}
	mut buf := []u8{len: 64 * 1024}
	for acc.len < n {
		k := c.read(mut buf) or { break }
		if k <= 0 {
			break
		}
		acc << buf[..k]
	}
	return acc
}

// ts_at_eof reports whether the server has closed the connection: a read
// ends without a byte well before the backstop (on a connection still open
// only the backstop ends it).
fn ts_at_eof(mut c openssl.SSLConn) bool {
	sw := time.new_stopwatch()
	mut buf := []u8{len: 256}
	k := c.read(mut buf) or { 0 }
	return k <= 0 && sw.elapsed().milliseconds() < ts_bound_ms
}

// ts_exchange writes `req` and returns the next `n` bytes of the answer.
fn ts_exchange(mut c openssl.SSLConn, req []u8, n int) []u8 {
	c.write(req) or { return []u8{} }
	return ts_read_n(mut c, n)
}

// ts_same reports whether two buffers are equal. Asserted through it, a
// mismatch prints a bool instead of both buffers, which for a body of
// megabytes takes minutes.
fn ts_same(a []u8, b []u8) bool {
	return a == b
}

// ts_body_is reports whether the answer `got` ends with exactly `body`, after
// a head.
fn ts_body_is(got []u8, body []u8) bool {
	return got.len > body.len && got[got.len - body.len..] == body
}

// ts_expect is the full answer to `req` (one of ts_handler's static routes),
// built by the case's own asset server: same snapshot, same bytes.
fn ts_expect(fx &TsFixture, req []u8) ![]u8 {
	if ts_target_is(req, '/disk/') {
		return fx.disk.respond(req)!
	}
	if ts_target_is(req, '/static/') {
		return fx.mem.respond(req)!
	}
	return ts_ok_resp
}

// ts_mode_ok asks the connection which path it runs (/ulp) and reports
// whether it is the one the run asked for: kTLS (and TlsTxSw rose past
// `tx0`) with the default config on a host with the module, userspace TLS
// otherwise. The second value says what was found.
fn ts_mode_ok(mut c openssl.SSLConn, ktls bool, tx0 i64) (bool, string) {
	got := ts_exchange(mut c, ts_ulp_req, ts_ulp_head.len + 3)
	want := if ts_expect_ktls(ktls) { 'tls' } else { '---' }
	if got.len != ts_ulp_head.len + 3 || got[ts_ulp_head.len..].bytestr() != want {
		return false, 'connection ULP: got "${got.bytestr()}", want body "${want}" (set_ktls ${ktls}, /sys/module/tls ${os.exists('/sys/module/tls')})'
	}
	if ts_expect_ktls(ktls) && ts_tls_tx() <= tx0 {
		return false, 'kTLS engaged but /proc/net/tls_stat TlsTxSw did not rise past ${tx0}'
	}
	return true, ''
}

// ts_handoffs_ok reports whether static_assets left bodies to sendfile(2)
// when, and only when, the connection can take them: at least once on a kTLS
// run (every case that calls it serves a body above the threshold), never on
// a userspace one, whose handler appends every body. The second value says
// what was counted.
fn ts_handoffs_ok(fx &TsFixture, ktls bool) (bool, string) {
	n := stdatomic.load_i64(&fx.handed.n)
	if ts_expect_ktls(ktls) {
		return n > 0, 'kTLS: static_assets never handed a body to core.queue_file'
	}
	return n == 0, 'userspace TLS: static_assets handed ${n} bodies to core.queue_file'
}

// ts_slow_reader locks the client's receive buffer small (tp_slow_reader in
// tls_pipelining_test.v): a ts_unbufferable_len body is then certain to park
// the TLS worker while the client is not reading.
fn ts_slow_reader(c &openssl.SSLConn) {
	v := 32 * 1024
	C.setsockopt(c.handle, C.SOL_SOCKET, C.SO_RCVBUF, &v, sizeof(v))
}

// ts_rss is this process's resident set size in bytes (VmRSS), or -1.
fn ts_rss() i64 {
	status := os.read_file('/proc/self/status') or { return -1 }
	for line in status.split_into_lines() {
		if line.starts_with('VmRSS:') {
			f := line.fields()
			if f.len >= 2 {
				return f[1].i64() * 1024 // kB
			}
		}
	}
	return -1
}

// ts_drain sends `count` requests one after another, alternating between the
// two of `reqs`, and reads each answer (lens[i] bytes) into `buf` without
// keeping it: no allocation per request, client side. Returns how many
// answers arrived whole.
fn ts_drain(mut c openssl.SSLConn, reqs [][]u8, lens []int, count int, mut buf []u8) int {
	for i in 0 .. count {
		k := i & 1
		c.write(reqs[k]) or { return i }
		mut left := lens[k]
		for left > 0 {
			n := c.read(mut buf) or { return i }
			if n <= 0 {
				return i
			}
			left -= n
		}
		if left < 0 {
			return i // more bytes than the answer has: the framing broke
		}
	}
	return count
}

// --- scenarios ---------------------------------------------------------------

// Bodies above the threshold arrive byte-exact on one keep-alive connection:
// with sendfile(2) on kTLS (from either mount), from RAM or read from disk on
// userspace TLS.
fn check_large_files(ktls bool) ! {
	mut fx := ts_fixture('large', false)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut c := ts_dial(h.port())!
	defer {
		ts_close(mut c)
	}
	mode_ok, mode_why := ts_mode_ok(mut c, ktls, tx0)
	assert mode_ok, mode_why
	for path in ['/static/mid.bin', '/static/big.bin', '/disk/mid.bin', '/disk/big.bin',
		'/static/mid.bin'] {
		req := ts_get(path, '')
		want := ts_expect(fx, req)!
		got := ts_exchange(mut c, req, want.len)
		assert ts_same(got, want), 'ktls=${ktls} ${path}: ${got.len} of ${want.len} bytes, or not byte-exact'
	}
	handed_ok, handed_why := ts_handoffs_ok(fx, ktls)
	assert handed_ok, handed_why
}

// Big, small and big bodies pipelined in one write are answered in order,
// byte-exact: on kTLS each file is sent (or parked and drained) before the
// next request is answered, and nothing is appended behind a pending file.
fn check_pipelined_big_small_big(ktls bool) ! {
	mut fx := ts_fixture('pipelined', false)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut c := ts_dial(h.port())!
	defer {
		ts_close(mut c)
	}
	mode_ok, mode_why := ts_mode_ok(mut c, ktls, tx0)
	assert mode_ok, mode_why
	reqs := [ts_get('/static/big.bin', ''), ts_get('/static/small.txt', ''),
		ts_get('/static/mid.bin', ''), ts_ok_req, ts_get('/disk/big.bin', ''),
		ts_get('/disk/small.txt', ''), ts_get('/disk/mid.bin', '')]
	mut burst := []u8{}
	mut want := []u8{}
	for r in reqs {
		burst << r
		want << ts_expect(fx, r)!
	}
	sw := time.new_stopwatch()
	c.write(burst)!
	got := ts_read_n(mut c, want.len)
	elapsed := sw.elapsed().milliseconds()
	assert got.len == want.len, 'ktls=${ktls}: ${got.len} of ${want.len} bytes of ${reqs.len} pipelined answers'
	assert ts_same(got, want), 'ktls=${ktls}: the pipelined answers must arrive in order, byte-exact'
	assert elapsed < ts_bound_ms, 'ktls=${ktls}: took ${elapsed}ms (${ts_backstop.milliseconds()}ms = an answer never came)'
	// The connection keeps serving after the burst.
	assert ts_exchange(mut c, ts_ok_req, ts_ok_resp.len) == ts_ok_resp
	handed_ok, handed_why := ts_handoffs_ok(fx, ktls)
	assert handed_ok, handed_why
}

// A client that stops reading parks the worker mid-file (a body the kernel
// cannot buffer: on kTLS the park is in the sendfile phase, the headers being
// tiny), and the request pipelined behind it — in the same write, or sent
// while it is parked — is answered after it, byte-exact.
fn check_slow_reader_parks_mid_file(ktls bool, same_write bool) ! {
	mut fx := ts_fixture('slow', true)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut c := ts_dial(h.port())!
	defer {
		ts_close(mut c)
	}
	mode_ok, mode_why := ts_mode_ok(mut c, ktls, tx0)
	assert mode_ok, mode_why
	ts_slow_reader(c)
	// From RAM (memory_fallback) or read from disk on userspace TLS.
	req := if same_write { ts_get('/static/huge.bin', '') } else { ts_get('/disk/huge.bin', '') }
	want := ts_expect(fx, req)!
	sw := time.new_stopwatch()
	mut got := []u8{}
	if same_write {
		mut burst := req.clone()
		burst << ts_ok_req
		c.write(burst)!
	} else {
		c.write(req)!
		got << ts_read_n(mut c, 512) // the head: the server is in the body now
		c.write(ts_ok_req)!
	}
	time.sleep(ts_park_wait) // not reading: the worker parks the rest
	got << ts_read_n(mut c, want.len + ts_ok_resp.len - got.len)
	elapsed := sw.elapsed().milliseconds()
	total := want.len + ts_ok_resp.len
	assert got.len == total, 'ktls=${ktls} same_write=${same_write}: ${got.len} of ${total} bytes'
	assert ts_same(got[..want.len], want), 'ktls=${ktls} same_write=${same_write}: the parked body must arrive whole and unmixed'
	assert got[want.len..] == ts_ok_resp, 'ktls=${ktls} same_write=${same_write}: the request behind the parked body must be answered after it, got: ${got[want.len..].bytestr()}'
	assert elapsed < ts_bound_ms, 'ktls=${ktls} same_write=${same_write}: took ${elapsed}ms'
	handed_ok, handed_why := ts_handoffs_ok(fx, ktls)
	assert handed_ok, handed_why
}

// A file replaced on disk (rename of a same-length file) is served on the
// next request of the same keep-alive connection — on kTLS from the new
// snapshot's fd — then on a fresh connection, and a restore by rename is
// served just as fast.
fn check_follows_the_disk(ktls bool) ! {
	mut fx := ts_fixture('follow', false)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut c := ts_dial(h.port())!
	defer {
		ts_close(mut c)
	}
	mode_ok, mode_why := ts_mode_ok(mut c, ktls, tx0)
	assert mode_ok, mode_why
	path := os.join_path(fx.assets, 'mid.bin')
	tmp := os.join_path(fx.assets, 'mid.bin.tmp')
	body_a := ts_pattern(ts_mid_len, 2)
	body_b := ts_pattern(ts_mid_len, 77)
	smem := ts_get('/static/mid.bin', '')
	sdisk := ts_get('/disk/mid.bin', '')

	got_a := ts_exchange(mut c, smem, ts_expect(fx, smem)!.len)
	assert ts_same(got_a, ts_expect(fx, smem)!), 'ktls=${ktls}: the first answer is not byte-exact'
	assert ts_body_is(got_a, body_a), 'ktls=${ktls}: the first answer must carry the original file'

	os.write_file_array(tmp, body_b)!
	os.rename(tmp, path)!
	// Same length, so the same answer length; read it before asking the
	// asset server what it now serves, so the worker is the one to rebuild.
	got_b := ts_exchange(mut c, smem, got_a.len)
	assert got_b.len == got_a.len && ts_body_is(got_b, body_b), 'ktls=${ktls}: the replaced file must be served on the same connection'
	assert ts_same(got_b, ts_expect(fx, smem)!), 'ktls=${ktls}: the answer must be the new snapshot, byte-exact'
	assert !ts_same(got_b[..got_b.len - ts_mid_len], got_a[..got_a.len - ts_mid_len]), 'ktls=${ktls}: a new version needs a new ETag'
	got_db := ts_exchange(mut c, sdisk, ts_expect(fx, sdisk)!.len)
	assert ts_body_is(got_db, body_b), 'ktls=${ktls}: /disk/ must serve the replaced file'

	mut c2 := ts_dial(h.port())!
	defer {
		ts_close(mut c2)
	}
	got_fresh := ts_exchange(mut c2, smem, got_a.len)
	assert ts_same(got_fresh, got_b), 'ktls=${ktls}: a fresh connection must get the replaced file'

	os.write_file_array(tmp, body_a)!
	os.rename(tmp, path)!
	got_back := ts_exchange(mut c2, smem, got_a.len)
	assert got_back.len == got_a.len && ts_body_is(got_back, body_a), 'ktls=${ktls}: the restored file must be served'
	got_dback := ts_exchange(mut c, sdisk, got_db.len)
	assert got_dback.len == got_db.len && ts_body_is(got_dback, body_a), 'ktls=${ktls}: /disk/ must serve the restored file'
	handed_ok, handed_why := ts_handoffs_ok(fx, ktls)
	assert handed_ok, handed_why
}

// A file shorter than the Content-Length already sent for it (it shrank
// after the head was built) ends the connection promptly instead of leaving
// the client waiting for bytes that do not exist: on kTLS sendfile(2) hits
// EOF and the worker closes; on userspace TLS nothing is ever queued, and the
// handler's short read closes.
fn check_shrunk_file_closes(ktls bool) ! {
	mut fx := ts_fixture('shrunk', false)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut c := ts_dial(h.port())!
	defer {
		ts_close(mut c)
	}
	mode_ok, mode_why := ts_mode_ok(mut c, ktls, tx0)
	assert mode_ok, mode_why
	mut whole := ts_short_head.clone()
	whole << ts_pattern(ts_short_len, 7)
	sw := time.new_stopwatch()
	got := ts_exchange(mut c, ts_get('/short', ''), ts_short_head.len + int(ts_short_promise))
	elapsed := sw.elapsed().milliseconds()
	eof := ts_at_eof(mut c)
	assert eof && elapsed < ts_bound_ms, 'ktls=${ktls}: a shrunk file must end the connection promptly (eof ${eof} after ${elapsed}ms)'
	// The head and the whole short file arrive before the close: on kTLS the
	// record held open for the file is pushed when sendfile(2) hits EOF after
	// sending some of it (Linux 6.5+), else by the worker's fatal alert (see
	// check_failed_file_keeps_earlier_answers).
	assert ts_same(got, whole), 'ktls=${ktls}: got ${got.len} of the ${whole.len} bytes of the head and file, or not byte-exact'
	want_accepted := if ts_expect_ktls(ktls) { i64(1) } else { i64(0) }
	accepted := stdatomic.load_i64(&fx.accepted.n)
	assert accepted == want_accepted, 'ktls=${ktls}: ${accepted} hand-offs, want ${want_accepted}'
}

// A file that fails in the sendfile phase ends the connection, but what the
// batch carried ahead of it still arrives: the complete answer pipelined
// before it, then its head. Here the region starts at the file's end, so
// sendfile(2) sends nothing (an EOF pushes the open record only once some of
// the file went out). On kTLS those bytes wait in the record the batch's
// MSG_MORE send held open, which a bare close discards (the client would get
// no byte): the worker sends a fatal alert first, which pushes it.
// On userspace TLS the handler appends nothing and closes after the same bytes.
fn check_failed_file_keeps_earlier_answers(ktls bool) ! {
	mut fx := ts_fixture('failed', false)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut c := ts_dial(h.port())!
	defer {
		ts_close(mut c)
	}
	mode_ok, mode_why := ts_mode_ok(mut c, ktls, tx0)
	assert mode_ok, mode_why
	mut burst := ts_ok_req.clone()
	burst << ts_get('/gone', '')
	mut want := ts_ok_resp.clone()
	want << ts_short_head
	sw := time.new_stopwatch()
	c.write(burst)!
	got := ts_read_n(mut c, want.len)
	elapsed := sw.elapsed().milliseconds()
	eof := ts_at_eof(mut c)
	assert ts_same(got, want), 'ktls=${ktls}: got ${got.len} of the ${want.len} bytes of the answer pipelined ahead of the failed file and its head, or not byte-exact'
	assert eof && elapsed < ts_bound_ms, 'ktls=${ktls}: a failed file must end the connection promptly (eof ${eof} after ${elapsed}ms)'
	want_accepted := if ts_expect_ktls(ktls) { i64(1) } else { i64(0) }
	accepted := stdatomic.load_i64(&fx.accepted.n)
	assert accepted == want_accepted, 'ktls=${ktls}: ${accepted} hand-offs, want ${want_accepted}'
}

// The sendfile slot is thread-local, so the TLS worker drains it after EVERY
// handler step. One worker: every connection below shares its slot.
//   1. GET /close queues a file and returns .close: the answer still carries
//      the whole file (read into the batch before the close), then EOF.
//   2. GET /ok twice on a fresh connection: exactly ts_ok_resp each time. A
//      file left queued by step 1 would be sent after the first answer.
//   3. GET /suspend queues a file and suspends: no bytes, EOF.
//   4. Step 2 again: the file step 3 queued was dropped.
fn check_slot_cleared_on_close(ktls bool) ! {
	mut fx := ts_fixture('slot', false)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut m := ts_dial(h.port())!
	defer {
		ts_close(mut m)
	}
	mode_ok, mode_why := ts_mode_ok(mut m, ktls, tx0)
	assert mode_ok, mode_why

	mut want_close := ts_close_head.clone()
	want_close << ts_pattern(ts_close_len, 8)
	mut a := ts_dial(h.port())!
	defer {
		ts_close(mut a)
	}
	got_close := ts_exchange(mut a, ts_get('/close', ''), want_close.len)
	assert ts_same(got_close, want_close), 'ktls=${ktls}: the .close answer must carry its queued file, byte-exact (${got_close.len} of ${want_close.len} bytes)'
	assert ts_at_eof(mut a), 'ktls=${ktls}: .close must end the connection'

	mut b := ts_dial(h.port())!
	defer {
		ts_close(mut b)
	}
	assert ts_exchange(mut b, ts_ok_req, ts_ok_resp.len) == ts_ok_resp
	assert ts_exchange(mut b, ts_ok_req, ts_ok_resp.len) == ts_ok_resp, 'ktls=${ktls}: a file queued by a .close step leaked into the next request'

	mut s := ts_dial(h.port())!
	defer {
		ts_close(mut s)
	}
	s.write(ts_get('/suspend', ''))!
	assert ts_at_eof(mut s), 'ktls=${ktls}: .suspend must close the connection without an answer'

	mut d := ts_dial(h.port())!
	defer {
		ts_close(mut d)
	}
	assert ts_exchange(mut d, ts_ok_req, ts_ok_resp.len) == ts_ok_resp
	assert ts_exchange(mut d, ts_ok_req, ts_ok_resp.len) == ts_ok_resp, 'ktls=${ktls}: a file queued by a .suspend step leaked into the next request'
	want_accepted := if ts_expect_ktls(ktls) { i64(2) } else { i64(0) }
	accepted := stdatomic.load_i64(&fx.accepted.n)
	assert accepted == want_accepted, 'ktls=${ktls}: ${accepted} hand-offs, want ${want_accepted}'
}

// Every kind of answer on one connection, one at a time and then all
// pipelined in one write: in-memory bodies, a br representation sent with
// sendfile on kTLS, a raw route, HEAD, a 304, a 206 from RAM and a 206 from
// a file offset (sendfile of a region on kTLS), a 404.
fn check_mixed_routes(ktls bool) ! {
	mut fx := ts_fixture('mixed', false)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut c := ts_dial(h.port())!
	defer {
		ts_close(mut c)
	}
	mode_ok, mode_why := ts_mode_ok(mut c, ktls, tx0)
	assert mode_ok, mode_why
	etag := fx.mem.etag_for('mid.bin')!
	reqs := [ts_get('/static/small.txt', ''), ts_get('/static/app.js', 'Accept-Encoding: br\r\n'),
		ts_ok_req, 'HEAD /static/big.bin HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(),
		ts_get('/static/mid.bin', 'If-None-Match: ${etag}\r\n'),
		ts_get('/static/big.bin', 'Range: bytes=1000-30999\r\n'),
		ts_get('/disk/big.bin', 'Range: bytes=500000-600000\r\n'),
		ts_get('/disk/app.js', 'Accept-Encoding: br\r\n'), ts_get('/static/nope.bin', ''),
		ts_get('/disk/mid.bin', ''), ts_get('/static/app.js', '')]
	mut burst := []u8{}
	mut want_all := []u8{}
	for i, r in reqs {
		want := ts_expect(fx, r)!
		got := ts_exchange(mut c, r, want.len)
		assert ts_same(got, want), 'ktls=${ktls} request ${i} (${r.bytestr().all_before('\r\n')}): not byte-exact, got ${got.len} of ${want.len} bytes'
		burst << r
		want_all << want
	}
	c.write(burst)!
	got_all := ts_read_n(mut c, want_all.len)
	assert ts_same(got_all, want_all), 'ktls=${ktls}: the same requests pipelined must get the same answers, in order (${got_all.len} of ${want_all.len} bytes)'
	handed_ok, handed_why := ts_handoffs_ok(fx, ktls)
	assert handed_ok, handed_why
}

// No allocation per request on either path: under -gc none (nothing is ever
// freed) the process's RSS grows less than ts_leak_max_growth over
// ts_leak_requests requests for a 47 KiB body, alternating the in-memory and
// the disk-backed mount. The client reads into one buffer, so the growth is
// the server's.
fn check_no_leak(ktls bool) ! {
	$if gcboehm ? {
		return // a collector hides a per-request allocation from RSS
	}
	mut fx := ts_fixture('leak', false)!
	defer {
		ts_cleanup(mut fx)
	}
	mut h := ts_start(fx, ktls)!
	defer {
		h.stop()
	}
	tx0 := ts_tls_tx()
	mut c := ts_dial(h.port())!
	defer {
		ts_close(mut c)
	}
	mode_ok, mode_why := ts_mode_ok(mut c, ktls, tx0)
	assert mode_ok, mode_why
	reqs := [ts_get('/static/mid.bin', ''), ts_get('/disk/mid.bin', '')]
	want0 := ts_expect(fx, reqs[0])!
	lens := [want0.len, ts_expect(fx, reqs[1])!.len]
	mut buf := []u8{len: 64 * 1024}
	warm := ts_drain(mut c, reqs, lens, ts_leak_warmup, mut buf)
	rss0 := ts_rss()
	done := ts_drain(mut c, reqs, lens, ts_leak_requests, mut buf)
	rss1 := ts_rss()
	assert warm == ts_leak_warmup && done == ts_leak_requests, 'ktls=${ktls}: ${warm}/${ts_leak_warmup} warm-up and ${done}/${ts_leak_requests} measured answers arrived whole'
	growth := rss1 - rss0
	assert rss0 > 0 && growth < ts_leak_max_growth, 'ktls=${ktls}: RSS grew ${growth} bytes over ${ts_leak_requests} requests (${growth / ts_leak_requests} B/request)'
	assert ts_same(ts_exchange(mut c, reqs[0], want0.len), want0), 'ktls=${ktls}: still byte-exact after the run'
	handed_ok, handed_why := ts_handoffs_ok(fx, ktls)
	assert handed_ok, handed_why
}

// --- tests -------------------------------------------------------------------

fn test_tls_static_large_files() ! {
	$if linux {
		$if vanilla_tls ? {
			check_large_files(true)!
			check_large_files(false)!
		}
	}
}

fn test_tls_static_pipelined_big_small_big() ! {
	$if linux {
		$if vanilla_tls ? {
			check_pipelined_big_small_big(true)!
			check_pipelined_big_small_big(false)!
		}
	}
}

fn test_tls_static_slow_reader_parks_mid_file() ! {
	$if linux {
		$if vanilla_tls ? {
			check_slow_reader_parks_mid_file(true, true)!
			check_slow_reader_parks_mid_file(true, false)!
			check_slow_reader_parks_mid_file(false, true)!
			check_slow_reader_parks_mid_file(false, false)!
		}
	}
}

fn test_tls_static_follows_the_disk() ! {
	$if linux {
		$if vanilla_tls ? {
			check_follows_the_disk(true)!
			check_follows_the_disk(false)!
		}
	}
}

fn test_tls_static_shrunk_file_closes() ! {
	$if linux {
		$if vanilla_tls ? {
			check_shrunk_file_closes(true)!
			check_shrunk_file_closes(false)!
		}
	}
}

fn test_tls_static_failed_file_keeps_earlier_answers() ! {
	$if linux {
		$if vanilla_tls ? {
			check_failed_file_keeps_earlier_answers(true)!
			check_failed_file_keeps_earlier_answers(false)!
		}
	}
}

fn test_tls_static_slot_cleared_on_close() ! {
	$if linux {
		$if vanilla_tls ? {
			check_slot_cleared_on_close(true)!
			check_slot_cleared_on_close(false)!
		}
	}
}

fn test_tls_static_mixed_routes() ! {
	$if linux {
		$if vanilla_tls ? {
			check_mixed_routes(true)!
			check_mixed_routes(false)!
		}
	}
}

fn test_tls_static_no_leak_under_gc_none() ! {
	$if linux {
		$if vanilla_tls ? {
			check_no_leak(true)!
			check_no_leak(false)!
		}
	}
}
