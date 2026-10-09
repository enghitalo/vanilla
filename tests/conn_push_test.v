// vtest build: linux
// Server push (vanilla#230) on the epoll plain worker: a taken-over
// connection subscribes (event_loop.subscribe) and is woken by posts from any
// thread (ConnHandle.post_wake / post_bytes through the worker's mailbox), by
// its wake_after timer, by Server.shutdown(), and, last, by its close.
//
// The protocol is a line protocol over takeover (cp_line_conn): `ping` ->
// `pong`, `wait <ms>` arms wake_after, `close` closes, anything else is
// echoed. The wake fn (cp_wake) writes `push:<data>` / `wake:<tag>` for a
// post, `timeout` for its timer (closing on the second), `shutdown`, and
// counts .closed. GET /sub upgrades and subscribes, answering
// `sub <index> <worker>` with the subscription's slot in a shared registry.
//
// The checks follow the issue's acceptance list: reads while subscribed; a
// post from another worker; .closed exactly once and the stale counter; fd
// reuse (a handle never reaches the connection that reuses its number);
// ordering and atomicity from two producer threads; backpressure (.full, the
// push watermark, a .close whose flush parks); wake_after liveness with
// default Limits; .shutdown; the unsupported paths; and no allocation per
// post under -gc none. Takeover is inert under tcc (#173): run with gcc.
import server
import core
import sync
import sync.stdatomic
import time
import transport
import vtest

#include <sys/socket.h>
#include <malloc.h>

fn C.recv(fd int, buf voidptr, len usize, flags int) int
fn C.setsockopt(fd int, level int, optname int, optval voidptr, optlen u32) int
fn C.pipe(fds &i32) int
fn C.close(fd int) int
fn C.shutdown(fd int, how int) int

struct C.mallinfo2 {
	uordblks usize
	hblkhd   usize
}

fn C.mallinfo2() C.mallinfo2

// cp_tag_bye: a post with this tag makes the wake fn say `bye` and close.
const cp_tag_bye = u64(0xb7e)

const cp_101 = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: lines\r\nConnection: Upgrade\r\n\r\n'

const cp_ok_head = 'HTTP/1.1 200 OK\r\nContent-Length: '

// CpSub is one subscription: its registry slot, handle and timer bookkeeping
// (the takeover state and the wake fn's sub_state).
@[heap]
struct CpSub {
mut:
	idx      int
	handle   core.ConnHandle
	wait_ms  int
	timeouts int
	park_w   int = -1 // the write end of the pipe `park` waits on (never written)
}

// CpRegistry is the application's handle registry, shared by every worker
// and the test thread.
struct CpRegistry {
mut:
	mu      &sync.Mutex = sync.new_mutex()
	handles [64]core.ConnHandle
	next    int
}

// CpCounts is what the wake fns saw, for the checks: atomics only.
struct CpCounts {
mut:
	closed      i64
	timeouts    i64
	next_worker i64
	park_runs   i64 // runs of the `park` continuation
	park_w      i64 // the write end of the last `park`'s pipe
}

const cp_reg = &CpRegistry{}
const cp = &CpCounts{}

struct CpWorker {
	id int
}

fn cp_state() voidptr {
	mut c := unsafe { cp }
	return voidptr(&CpWorker{
		id: int(stdatomic.add_i64(&c.next_worker, 1) - 1)
	})
}

fn cp_reg_add(h core.ConnHandle) int {
	mut r := unsafe { cp_reg }
	r.mu.lock()
	idx := r.next
	r.next++
	r.handles[idx % 64] = h
	r.mu.unlock()
	return idx
}

fn cp_reg_get(idx int) core.ConnHandle {
	mut r := unsafe { cp_reg }
	r.mu.lock()
	h := r.handles[idx % 64]
	r.mu.unlock()
	return h
}

fn cp_reg_remove(idx int) {
	mut r := unsafe { cp_reg }
	r.mu.lock()
	r.handles[idx % 64] = core.ConnHandle{}
	r.mu.unlock()
}

fn cp_reset() {
	mut c := unsafe { cp }
	stdatomic.store_i64(&c.closed, 0)
	stdatomic.store_i64(&c.timeouts, 0)
	stdatomic.store_i64(&c.next_worker, 0)
	stdatomic.store_i64(&c.park_runs, 0)
}

fn cp_prefix(b []u8, p string) bool {
	if b.len < p.len {
		return false
	}
	for i in 0 .. p.len {
		if b[i] != p[i] {
			return false
		}
	}
	return true
}

// cp_dec appends n's decimal digits.
fn cp_dec(mut out []u8, n i64) {
	if n < 0 {
		out << `-`
		cp_dec(mut out, -n)
		return
	}
	if n >= 10 {
		cp_dec(mut out, n / 10)
	}
	out << u8(`0` + n % 10)
}

fn cp_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	w := unsafe { &CpWorker(worker_state) }
	if cp_prefix(req, 'GET /sub') {
		mut sub := &CpSub{}
		if !core.queue_takeover(cp_line_conn, voidptr(sub)) {
			core.append_str(mut out, 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n')
			return .close
		}
		if cp_prefix(req, 'GET /sub?small') {
			// A small send buffer, so a client that stops reading leaves bytes
			// pending in the write buffer after a few KiB.
			small := 4096
			C.setsockopt(client_fd, C.SOL_SOCKET, C.SO_SNDBUF, &small, 4)
		}
		sub.handle = event_loop.subscribe(cp_wake, voidptr(sub))
		sub.idx = cp_reg_add(sub.handle)
		core.append_str(mut out, cp_101)
		core.append_str(mut out, 'sub ')
		cp_dec(mut out, sub.idx)
		out << ` `
		cp_dec(mut out, w.id)
		out << ` `
		out << u8(if sub.handle.is_nil() { `n` } else { `y` })
		out << `\n`
		return .done
	}
	if cp_prefix(req, 'GET /notify/') {
		// Post to registry slot <k> from whichever worker serves this request.
		mut k := 0
		mut i := 12
		for i < req.len && req[i] >= `0` && req[i] <= `9` {
			k = k * 10 + int(req[i] - `0`)
			i++
		}
		res := cp_reg_get(k).post_bytes(7, 'from-another-worker'.bytes())
		mut body := []u8{cap: 16}
		cp_dec(mut body, w.id)
		body << ` `
		cp_dec(mut body, int(res))
		body << `\n`
		core.append_str(mut out, cp_ok_head)
		cp_dec(mut out, body.len)
		core.append_str(mut out, '\r\n\r\n')
		out << body
		return .done
	}
	if cp_prefix(req, 'GET /busy ') {
		time.sleep(300 * time.millisecond) // the worker takes no post meanwhile
		core.append_str(mut out, cp_ok_head)
		core.append_str(mut out, '4\r\n\r\nbusy')
		return .done
	}
	if cp_prefix(req, 'GET /h1sub ') {
		// No takeover: an HTTP/1.1 connection cannot subscribe.
		h := event_loop.subscribe(cp_wake, unsafe { nil })
		core.append_str(mut out, cp_ok_head)
		core.append_str(mut out, '1\r\n\r\n')
		out << u8(if h.is_nil() { `n` } else { `y` })
		return .done
	}
	core.append_str(mut out, cp_ok_head)
	core.append_str(mut out, '2\r\n\r\nok')
	return .done
}

// cp_line_conn is the line protocol (see the top of the file).
fn cp_line_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut sub := unsafe { &CpSub(takeover_state) }
	mut consumed := 0
	for {
		mut end := consumed
		for end < buf.len && buf[end] != `\n` {
			end++
		}
		if end == buf.len {
			break // partial line
		}
		line := unsafe { (&buf[consumed]).vbytes(end - consumed) }
		consumed = end + 1
		if line.len == 4 && cp_prefix(line, 'ping') {
			core.append_str(mut out, 'pong\n')
		} else if line.len == 5 && cp_prefix(line, 'close') {
			return consumed, core.Step.close
		} else if line.len == 4 && cp_prefix(line, 'park') {
			// Wait mid-protocol on something that never comes (a hung
			// database): the connection is parked, not subscribed-and-reading.
			mut fds := [2]i32{}
			C.pipe(&fds[0])
			sub.park_w = int(fds[1])
			mut c := unsafe { cp }
			stdatomic.store_i64(&c.park_w, i64(fds[1]))
			event_loop.watch_fd(int(fds[0]), .readable, cp_park_cont, voidptr(sub))
			return consumed, core.Step.suspend
		} else if cp_prefix(line, 'wait ') {
			mut ms := 0
			for c in line[5..] {
				ms = ms * 10 + int(c - `0`)
			}
			sub.wait_ms = ms
			core.append_str(mut out, if event_loop.wake_after(ms) { 'armed\n' } else { 'unarmed\n' })
		} else {
			core.append_str(mut out, 'echo:')
			unsafe { out.push_many(line.data, line.len) }
			out << `\n`
		}
	}
	return consumed, core.Step.done
}

// cp_wake is the subscription's wake fn.
fn cp_wake(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut c := unsafe { cp }
	match event_loop.reason() {
		.posted {
			if event_loop.post_tag() == cp_tag_bye {
				core.append_str(mut out, 'bye\n')
				return .close
			}
			data := event_loop.post_data()
			if data.len == 0 {
				core.append_str(mut out, 'wake:')
				cp_dec(mut out, i64(event_loop.post_tag()))
			} else {
				core.append_str(mut out, 'push:')
				unsafe { out.push_many(data.data, data.len) }
			}
			out << `\n`
		}
		.timeout {
			mut sub := unsafe { &CpSub(watch_payload) }
			sub.timeouts++
			stdatomic.add_i64(&c.timeouts, 1)
			core.append_str(mut out, 'timeout\n')
			if sub.timeouts >= 2 {
				return .close // the peer never answered: reap it
			}
			event_loop.wake_after(sub.wait_ms)
		}
		.shutdown {
			core.append_str(mut out, 'shutdown\n')
			return .close
		}
		.closed {
			stdatomic.add_i64(&c.closed, 1)
			if watch_payload != unsafe { nil } {
				mut sub := unsafe { &CpSub(watch_payload) }
				cp_reg_remove(sub.idx)
				if sub.park_w >= 0 {
					C.close(sub.park_w)
					sub.park_w = -1
				}
			}
		}
		else {}
	}
	return .done
}

// cp_park_cont is `park`'s continuation: its fd is never written, so it must
// never run.
fn cp_park_cont(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut c := unsafe { cp }
	stdatomic.add_i64(&c.park_runs, 1)
	core.append_str(mut out, 'resumed\n')
	return .done
}

fn cp_config(workers int, slots int, watermark int) server.ServerConfig {
	return server.ServerConfig{
		io_multiplexing:      .epoll
		handler:              cp_handler
		make_state:           cp_state
		workers:              workers
		push_mailbox_slots:   slots
		push_watermark_bytes: watermark
	}
}

// CpClient is a raw client connection that accumulates what it reads.
struct CpClient {
	fd int
mut:
	acc []u8
}

fn cp_dial(port int, req string) !CpClient {
	fd := transport.dial_tcp('127.0.0.1', port)!
	mut c := CpClient{
		fd: fd
	}
	c.send(req)!
	return c
}

fn (mut c CpClient) send(s string) ! {
	for _ in 0 .. 2000 {
		n := C.send(c.fd, s.str, usize(s.len), C.MSG_NOSIGNAL)
		if n == s.len {
			return
		}
		if n > 0 {
			return error('short send')
		}
		time.sleep(time.millisecond) // still connecting
	}
	return error('send failed')
}

// until reads until `needle` is in what was read, EOF, or `ms` pass.
fn (mut c CpClient) until(needle string, ms int) bool {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	mut buf := [4096]u8{}
	for {
		if c.acc.bytestr().contains(needle) {
			return true
		}
		n := C.recv(c.fd, &buf[0], 4096, C.MSG_DONTWAIT)
		if n > 0 {
			unsafe { c.acc.push_many(&buf[0], n) }
			continue
		}
		if n == 0 || time.sys_mono_now() > deadline {
			return c.acc.bytestr().contains(needle)
		}
		time.sleep(time.millisecond)
	}
	return false
}

// line_after waits until what was read holds `marker` followed by a line
// end, and returns the text in between (none after `ms`).
fn (mut c CpClient) line_after(marker string, ms int) ?string {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	mut buf := [4096]u8{}
	for {
		s := c.acc.bytestr()
		if s.contains(marker) && s.all_after(marker).contains('\n') {
			return s.all_after(marker).all_before('\n')
		}
		n := C.recv(c.fd, &buf[0], 4096, C.MSG_DONTWAIT)
		if n > 0 {
			unsafe { c.acc.push_many(&buf[0], n) }
			continue
		}
		if n == 0 || time.sys_mono_now() > deadline {
			return none
		}
		time.sleep(time.millisecond)
	}
	return none
}

// eof reads until the server closes (true) or `ms` pass.
fn (mut c CpClient) eof(ms int) bool {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	mut buf := [4096]u8{}
	for time.sys_mono_now() < deadline {
		n := C.recv(c.fd, &buf[0], 4096, C.MSG_DONTWAIT)
		if n > 0 {
			unsafe { c.acc.push_many(&buf[0], n) }
			continue
		}
		if n == 0 || (n < 0 && C.errno != C.EAGAIN) {
			return true
		}
		time.sleep(time.millisecond)
	}
	return false
}

fn (mut c CpClient) close() {
	transport.close_fd(c.fd)
}

// cp_sub opens a subscribed connection: its client, registry index and worker.
fn cp_sub(port int, path string) !(CpClient, int, int) {
	mut c := cp_dial(port, 'GET ' + path + ' HTTP/1.1\r\nHost: x\r\n\r\n')!
	line := c.line_after('\r\n\r\nsub ', 3000) or {
		return error('no subscription: ${c.acc.bytestr()}')
	}
	parts := line.split(' ')
	if parts.len < 3 || parts[2] != 'y' {
		return error('subscribe gave a nil handle: ${line}')
	}
	c.acc.clear()
	return c, parts[0].int(), parts[1].int()
}

fn cp_until(p &i64, want i64, ms int) i64 {
	for _ in 0 .. ms {
		if stdatomic.load_i64(p) >= want {
			break
		}
		time.sleep(time.millisecond)
	}
	return stdatomic.load_i64(p)
}

fn cp_stats_until(mut h vtest.Harness, stale u64, ms int) server.PushStats {
	for _ in 0 .. ms {
		s := h.server_ref().push_stats()
		if s.stale >= stale {
			return s
		}
		time.sleep(time.millisecond)
	}
	return h.server_ref().push_stats()
}

// --- the checks -----------------------------------------------------------------

// Repro A inverted: a subscribed connection keeps reading its client — echo
// and pong come back while no post is pending — and a post from another
// thread arrives between bursts.
fn test_epoll_push_reads_while_subscribed() ! {
	$if tinyc {
		eprintln('[test] takeover is inert under tcc; skipping')
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 64, 0))!
	defer {
		h.stop()
	}
	mut a, idx, _ := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	a.send('one\n')!
	assert a.until('echo:one\n', 2000)
	a.send('two\n')!
	assert a.until('echo:two\n', 2000), 'a subscribed connection must keep reading: ${a.acc.bytestr()}'
	a.send('ping\n')!
	assert a.until('pong\n', 2000)
	handle := cp_reg_get(idx)
	t := spawn fn [handle] () core.PostResult {
		return handle.post_bytes(1, 'hello'.bytes())
	}()
	assert t.wait() == .ok
	assert a.until('push:hello\n', 2000), a.acc.bytestr()
	assert handle.post_wake(42) == .ok
	assert a.until('wake:42\n', 2000), a.acc.bytestr()
	// Still reading after the posts.
	a.send('three\n')!
	assert a.until('echo:three\n', 2000)
}

// Repro E inverted: a post made by a request on another worker reaches the
// subscribed connection on its own worker.
fn test_epoll_push_cross_worker() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(2, 64, 0))!
	defer {
		h.stop()
	}
	mut a, idx, worker_a := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	// Accept round-robins: one of the next connections lands on the other worker.
	mut other := -1
	for _ in 0 .. 4 {
		mut b := cp_dial(h.port(), 'GET /notify/' + idx.str() + ' HTTP/1.1\r\nHost: x\r\n\r\n')!
		body := b.line_after('\r\n\r\n', 2000) or { '' }
		b.close()
		w := body.all_before(' ').int()
		assert body.all_after(' ') == int(core.PostResult.ok).str(), body
		assert a.until('push:from-another-worker\n', 2000), a.acc.bytestr()
		a.acc.clear()
		if w != worker_a {
			other = w
			break
		}
	}
	assert other >= 0 && other != worker_a, 'no request landed on another worker'
	// The connection still reads its client.
	a.send('x\n')!
	assert a.until('echo:x\n', 2000)
}

// The close notification: the wake fn runs exactly once with .closed when
// the client goes; a post to the old handle is accepted, then dropped on the
// owning worker and counted as stale.
fn test_epoll_push_closed_once_then_stale() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 64, 0))!
	defer {
		h.stop()
	}
	mut a, idx, _ := cp_sub(h.port(), '/sub')!
	handle := cp_reg_get(idx)
	a.close()
	c := unsafe { cp }
	assert cp_until(&c.closed, 1, 3000) == 1
	assert cp_reg_get(idx).is_nil(), '.closed did not unregister'
	before := h.server_ref().push_stats()
	assert handle.post_bytes(1, 'late'.bytes()) == .ok
	after := cp_stats_until(mut h, before.stale + 1, 3000)
	assert after.stale == before.stale + 1
	assert after.delivered == before.delivered
	time.sleep(100 * time.millisecond)
	assert stdatomic.load_i64(&c.closed) == 1, '.closed ran more than once'
}

// Repros D/F: a handle taken before its connection closed never reaches the
// connections that reuse the fd number: they receive nothing.
fn test_epoll_push_fd_reuse_is_safe() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 64, 0))!
	defer {
		h.stop()
	}
	mut a, idx, _ := cp_sub(h.port(), '/sub')!
	handle := cp_reg_get(idx)
	a.close()
	c := unsafe { cp }
	assert cp_until(&c.closed, 1, 3000) == 1
	// Subscribed connections (repro F's shape): one of them gets A's number.
	mut subs := []CpClient{}
	mut reused := -1
	for _ in 0 .. 4 {
		mut s, sidx, _ := cp_sub(h.port(), '/sub')!
		subs << s
		if cp_reg_get(sidx).fd == handle.fd {
			reused = sidx
			break
		}
	}
	defer {
		for mut s in subs {
			s.close()
		}
	}
	// Idle connections (repro D): never subscribed, they take more
	// numbers.
	mut b := cp_dial(h.port(), '')!
	defer {
		b.close()
	}
	mut d := cp_dial(h.port(), '')!
	defer {
		d.close()
	}
	time.sleep(50 * time.millisecond)
	before := h.server_ref().push_stats()
	assert handle.post_bytes(1, 'patient-A:queue-position=3'.bytes()) == .ok
	assert handle.post_wake(9) == .ok
	after := cp_stats_until(mut h, before.stale + 2, 3000)
	assert after.stale == before.stale + 2
	assert !b.until('patient', 200) && b.acc.len == 0, 'an idle connection got a stale post: ${b.acc.bytestr()}'
	assert !d.until('patient', 50) && d.acc.len == 0, 'an idle connection got a stale post: ${d.acc.bytestr()}'
	for mut s in subs {
		assert !s.until('patient', 50) && s.acc.len == 0, 'a subscriber got a stale post: ${s.acc.bytestr()}'
	}
	if reused >= 0 {
		// The number's new owner is reached through its own handle.
		assert cp_reg_get(reused).post_bytes(1, 'mine'.bytes()) == .ok
		assert subs[subs.len - 1].until('push:mine\n', 2000)
	} else {
		eprintln('[test] no subscriber got the closed connection fd number this run')
	}
}

// 10000 posts from two producer threads to one connection arrive whole, in
// each producer's order.
fn test_epoll_push_two_producers_keep_order() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 1024, 8 * 1024 * 1024))!
	defer {
		h.stop()
	}
	mut a, idx, _ := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	handle := cp_reg_get(idx)
	per := 5000
	mut producers := []thread int{}
	for p in 0 .. 2 {
		producers << spawn fn [handle, p, per] () int {
			mut full := 0
			mut msg := []u8{cap: 32}
			for i in 0 .. per {
				unsafe {
					msg.len = 0
				}
				msg << u8(`a` + p)
				cp_dec(mut msg, i)
				for handle.post_bytes(1, msg) == .full {
					full++
					time.sleep(50 * time.microsecond)
				}
			}
			return full
		}()
	}
	mut next := [0, 0]
	mut lines := 0
	mut buf := [65536]u8{}
	mut pending := []u8{cap: 64}
	deadline := time.sys_mono_now() + 20 * u64(time.second)
	for lines < 2 * per && time.sys_mono_now() < deadline {
		n := C.recv(a.fd, &buf[0], 65536, 0)
		if n < 0 && C.errno == C.EAGAIN {
			time.sleep(50 * time.microsecond) // the client fd is non-blocking
			continue
		}
		if n <= 0 {
			break
		}
		for i in 0 .. n {
			if buf[i] != `\n` {
				pending << buf[i]
				continue
			}
			s := pending.bytestr()
			pending.clear()
			assert s.starts_with('push:'), 'a torn or foreign message: ${s}'
			p := int(s[5] - `a`)
			assert p == 0 || p == 1, s
			assert s[6..].int() == next[p], 'producer ${p}: got ${s[6..]}, want ${next[p]}'
			next[p]++
			lines++
		}
	}
	producers.wait()
	assert next[0] == per && next[1] == per
}

// The mailbox never blocks a producer: with the worker busy, a 4-slot mailbox
// reports .full past 4 posts; the 4 accepted are delivered afterwards.
fn test_epoll_push_full_mailbox_reports_full() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 4, 0))!
	defer {
		h.stop()
	}
	mut a, idx, _ := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	handle := cp_reg_get(idx)
	mut busy := cp_dial(h.port(), 'GET /busy HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		busy.close()
	}
	time.sleep(50 * time.millisecond) // the worker is in /busy's handler now
	mut results := []core.PostResult{}
	for i in 0 .. 10 {
		results << handle.post_wake(u64(i))
	}
	assert results[..4].all(it == .ok), results.str()
	assert results[4..].all(it == .full), results.str()
	assert busy.until('busy', 3000)
	assert a.until('wake:3\n', 3000), a.acc.bytestr()
	assert !a.acc.bytestr().contains('wake:4'), 'a refused post was delivered'
	assert h.server_ref().push_stats().full == 6
}

// A subscriber that stops reading is closed at the push watermark, with
// default Limits (no write timeout); a healthy one on the same worker keeps
// receiving; the producer never blocks.
fn test_epoll_push_watermark_closes_a_slow_subscriber() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 1024, 64 * 1024))!
	defer {
		h.stop()
	}
	mut slow, slow_idx, _ := cp_sub(h.port(), '/sub?small')!
	defer {
		slow.close()
	}
	mut fast, fast_idx, _ := cp_sub(h.port(), '/sub')!
	defer {
		fast.close()
	}
	small := 2048
	C.setsockopt(slow.fd, C.SOL_SOCKET, C.SO_RCVBUF, &small, 4)
	slow_h := cp_reg_get(slow_idx)
	payload := []u8{len: 200, init: `x`}
	c := unsafe { cp }
	mut posts := 0
	for posts < 200_000 && stdatomic.load_i64(&c.closed) == 0 {
		r := slow_h.post_bytes(1, payload)
		if r == .full {
			time.sleep(100 * time.microsecond)
			continue
		}
		assert r == .ok
		posts++
	}
	assert cp_until(&c.closed, 1, 5000) == 1, 'the slow subscriber was not closed after ${posts} posts'
	fast_h := cp_reg_get(fast_idx)
	assert fast_h.post_bytes(1, 'still here'.bytes()) == .ok
	assert fast.until('push:still here\n', 3000), 'the healthy subscriber stopped receiving'
}

// A wake fn's .close whose last bytes cannot all be sent at once: they still
// go out, then the connection closes, and no client byte reaches the
// ConnHandler in between.
fn test_epoll_push_close_with_a_parked_flush() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 1024, 8 * 1024 * 1024))!
	defer {
		h.stop()
	}
	mut a, idx, _ := cp_sub(h.port(), '/sub?small')!
	defer {
		a.close()
	}
	handle := cp_reg_get(idx)
	payload := []u8{len: 200, init: `y`}
	for _ in 0 .. 2000 {
		for handle.post_bytes(1, payload) == .full {
			time.sleep(100 * time.microsecond)
		}
	}
	for handle.post_wake(cp_tag_bye) == .full {
		time.sleep(100 * time.microsecond)
	}
	time.sleep(100 * time.millisecond) // the bye is appended; its flush is parked
	a.send('late\n')!
	assert a.eof(10_000), 'the connection did not close'
	got := a.acc.bytestr()
	assert got.count('push:') == 2000, 'pushes lost before the close: ${got.count('push:')}'
	assert got.ends_with('bye\n'), 'the closing bytes were cut: ...${got#[-40..]}'
	assert !got.contains('echo:late'), 'a client byte reached the ConnHandler while closing'
}

// wake_after with default Limits: the timer fires .timeout (and the wake fn
// re-arms it), and a peer that never answers is reaped at the second one.
fn test_epoll_push_wake_after_liveness() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 0, 0))! // no mailbox: timers and .closed still work
	defer {
		h.stop()
	}
	mut a, _, _ := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	sw := time.new_stopwatch()
	a.send('wait 200\n')!
	assert a.until('armed\n', 2000)
	assert a.until('timeout\n', 2000)
	first := sw.elapsed().milliseconds()
	assert a.eof(3000), 'not reaped at the second timeout'
	total := sw.elapsed().milliseconds()
	assert a.acc.bytestr().count('timeout\n') == 2
	assert first >= 180 && first < 1500, 'first timeout after ${first} ms'
	assert total >= 380 && total < 3000, 'reaped after ${total} ms'
	c := unsafe { cp }
	assert cp_until(&c.closed, 1, 2000) == 1
}

// Server.shutdown(grace) with the mailbox on: subscribed connections get
// .shutdown (here: say it and close), and they do not hold the drain.
fn test_epoll_push_shutdown_says_goodbye() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(2, 64, 0))!
	defer {
		h.stop()
	}
	mut a, _, _ := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	mut b, _, _ := cp_sub(h.port(), '/sub')!
	defer {
		b.close()
	}
	sw := time.new_stopwatch()
	h.server_ref().shutdown(5000)
	waited := sw.elapsed().milliseconds()
	assert waited < 2000, 'subscribed connections held shutdown(5000) for ${waited} ms'
	assert a.until('shutdown\n', 2000) && a.eof(2000)
	assert b.until('shutdown\n', 2000) && b.eof(2000)
	c := unsafe { cp }
	assert cp_until(&c.closed, 2, 2000) == 2
}

// Repro C inverted: a taken-over connection parked on a watch that never
// fires, whose client sends a frame and then its FIN. The connection closes at
// once (it no longer waits for the watch), the continuation never runs, the
// frame before the FIN is dropped (the frame-before-FIN policy:
// read_while_parked), and its subscription gets .closed. Before, only a
// 1-byte peek looked at a parked connection: it saw the frame, never the FIN.
fn test_epoll_parked_takeover_sees_fin_behind_a_frame() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 0, 0))!
	defer {
		h.stop()
	}
	mut a, _, _ := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	a.send('park\n')!
	time.sleep(50 * time.millisecond) // parked
	a.send('late\n')!
	time.sleep(50 * time.millisecond) // the frame is in, unprocessed
	C.shutdown(a.fd, C.SHUT_WR) // FIN behind it
	sw := time.new_stopwatch()
	assert a.eof(3000), 'a parked connection whose peer left was not closed'
	assert sw.elapsed().milliseconds() < 1000
	assert !a.acc.bytestr().contains('echo:late'), 'a frame reached the ConnHandler while parked'
	assert !a.acc.bytestr().contains('resumed')
	c := unsafe { cp }
	assert cp_until(&c.closed, 1, 2000) == 1
	assert stdatomic.load_i64(&c.park_runs) == 0, 'the continuation of a closed park ran'
}

// While parked the connection keeps taking its client's bytes into its
// buffer, and its ConnHandler gets them, in order, once the park ends.
fn test_epoll_parked_takeover_buffers_frames_for_the_resume() ! {
	$if tinyc {
		return
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 0, 0))!
	defer {
		h.stop()
	}
	mut a, _, _ := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	a.send('park\n')!
	time.sleep(50 * time.millisecond)
	a.send('one\ntwo\n')!
	assert !a.until('echo:', 200), 'the ConnHandler ran while parked: ${a.acc.bytestr()}'
	// End the park: its fd becomes readable.
	c := unsafe { cp }
	one := u8(1)
	C.write(int(stdatomic.load_i64(&c.park_w)), &one, 1)
	assert a.until('resumed\necho:one\necho:two\n', 2000), a.acc.bytestr()
}

// The unsupported paths: a plain EventLoop (unit tests) and an HTTP/1.1
// connection subscribe to nothing; the nil handle and a handle without a
// mailbox post nothing.
fn test_epoll_push_unsupported_paths() ! {
	mut el := core.EventLoop{}
	nh := el.subscribe(cp_wake, unsafe { nil })
	assert nh.is_nil()
	assert nh.post_wake(1) == .unsupported
	assert nh.post_bytes(1, 'x'.bytes()) == .unsupported
	assert !el.wake_after(10)
	assert el.reason() == .ready && el.post_tag() == 0 && el.post_data().len == 0
	cp_reset()
	mut h := vtest.start(cp_config(1, 0, 0))!
	defer {
		h.stop()
	}
	mut x := cp_dial(h.port(), 'GET /h1sub HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		x.close()
	}
	assert x.until('\r\n\r\nn', 2000), 'an HTTP/1.1 connection subscribed: ${x.acc.bytestr()}'
	$if !tinyc {
		// Mailbox off: the subscription works, posts are unsupported.
		mut a, idx, _ := cp_sub(h.port(), '/sub')!
		defer {
			a.close()
		}
		assert cp_reg_get(idx).post_wake(1) == .unsupported
		assert cp_reg_get(idx).post_bytes(1, 'x'.bytes()) == .unsupported
		a.send('ping\n')!
		assert a.until('pong\n', 2000)
	}
}

// io_uring has no takeover, hence no subscriptions: the upgrade is refused
// and nothing breaks.
fn test_iouring_push_unsupported() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring unavailable; skipping')
		return
	}
	cp_reset()
	mut h := vtest.start(server.ServerConfig{
		...cp_config(1, 64, 0)
		io_multiplexing: .io_uring
	})!
	defer {
		h.stop()
	}
	mut x := cp_dial(h.port(), 'GET /sub HTTP/1.1\r\nHost: x\r\n\r\n')!
	defer {
		x.close()
	}
	assert x.until('501', 2000), x.acc.bytestr()
	assert h.server_ref().push_stats().posted == 0
}

fn cp_heap() i64 {
	mi := C.mallinfo2()
	return i64(mi.uordblks) + i64(mi.hblkhd)
}

// cp_read_lines reads until `want` more newlines arrived, into a fixed buffer
// (nothing allocated on the client side either).
fn cp_read_lines(fd int, want int) int {
	mut buf := [16384]u8{}
	mut got := 0
	for got < want {
		n := C.recv(fd, &buf[0], 16384, 0)
		if n < 0 && C.errno == C.EAGAIN {
			time.sleep(20 * time.microsecond) // the client fd is non-blocking
			continue
		}
		if n <= 0 {
			break
		}
		for i in 0 .. n {
			if buf[i] == `\n` {
				got++
			}
		}
	}
	return got
}

// No allocation per post under -gc none (nothing is freed there): after a
// warm-up, 100k post_wake and 100k post_bytes (64 B) delivered and read move
// the heap by less than a fixed bound. Bytes in use over every arena
// (mallinfo2), not RSS (see tests/tls_static_test.v).
fn test_epoll_push_posts_allocate_nothing() ! {
	$if tinyc {
		return
	}
	$if gcboehm ? {
		return // a collector frees a per-post allocation
	}
	$if race ? {
		return // ThreadSanitizer's allocator replaces malloc; mallinfo2 does not see it
	}
	cp_reset()
	mut h := vtest.start(cp_config(1, 4096, 8 * 1024 * 1024))!
	defer {
		h.stop()
	}
	mut a, idx, _ := cp_sub(h.port(), '/sub')!
	defer {
		a.close()
	}
	handle := cp_reg_get(idx)
	data := []u8{len: 64, init: `z`}
	assert cp_post_and_read(handle, data, a.fd, 20_000) == 20_000 // warm-up
	base := cp_heap()
	assert cp_post_and_read(handle, data, a.fd, 200_000) == 200_000
	grew := cp_heap() - base
	assert grew < 256 * 1024, '200k posts grew the heap by ${grew} bytes'
}

// cp_post_and_read posts n times, alternating post_wake and post_bytes, and
// reads every resulting line as it goes: the count read.
fn cp_post_and_read(handle core.ConnHandle, data []u8, fd int, n int) int {
	mut read := 0
	mut posted := 0
	for posted < n {
		r := if posted & 1 == 0 {
			handle.post_wake(u64(posted) + 1_000_000) // never cp_tag_bye
		} else {
			handle.post_bytes(1, data)
		}
		if r == .full {
			read += cp_read_lines(fd, 1)
			continue
		}
		posted++
		if posted - read >= 256 {
			read += cp_read_lines(fd, posted - read)
		}
	}
	read += cp_read_lines(fd, posted - read)
	return read
}
