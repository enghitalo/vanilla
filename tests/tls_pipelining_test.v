// vtest build: linux && vanilla_tls?
// HTTP/1.1 pipelining over HTTPS on the epoll TLS worker (issue #152): every
// complete request a burst carries is answered, in order — in one TLS record,
// in several records that arrive together, with a partial one behind them —
// and a response parked on WANT_WRITE is finished, byte-exact, before the
// requests pipelined behind it are answered, whether they came with it or
// while it was parked. A pipelined partial gets its own read deadline. kTLS
// sets TLS_RX_EXPECT_NO_PAD only when the config opts in.
//
// Only runs with `-d vanilla_tls` on Linux (see tls_timeouts_test.v, whose
// client this follows: vlib net.openssl, not net.mbedtls, whose bundled Mbed
// TLS clashes with the -lmbedtls the server links):
//
//   v -cc gcc -d vanilla_tls test tests/tls_pipelining_test.v
//
// No Limits unless a case is about deadlines: a stranded request then hangs
// instead of being reaped, and the openssl read timeout is only the hang
// backstop — a regression fails the elapsed assert, it never blocks forever.
import os
import time
import net.openssl
import server
import core
import tls
import vtest

#include <netinet/tcp.h>
#include <signal.h>

struct C.linger {
	l_onoff  int
	l_linger int
}

fn C.signal(sig int, handler voidptr) voidptr

// Every request path is 4 bytes: `/big`, `/pad`, or `/NNN`, which the handler
// echoes as the body, so the client can check the order of the answers.
const tp_ok_head = 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\n'.bytes()
// GET /big answers with a body larger than loopback can absorb while the
// client is not reading (see tp_slow_reader), so the worker must park it and
// drain it on EPOLLOUT.
const tp_big_req = 'GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const tp_big_len = tp_unbufferable_len()
const tp_big_head = 'HTTP/1.1 200 OK\r\nContent-Length: ${tp_big_len}\r\nConnection: keep-alive\r\n\r\n'.bytes()
// GET /pad answers `/pa` and the server socket's TLS_RX_EXPECT_NO_PAD state
// (see tp_no_pad_state). getsockopt(2) names from linux/tls.h (since 6.0).
const tp_pad_req = 'GET /pad HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const tp_sol_tls = 282
const tp_tls_rx_expect_no_pad = 4
// Hang backstop for the openssl client only (see the header).
const tp_backstop = time.Duration(5 * time.second)
// Every exchange below completes in milliseconds on loopback (the big
// response in a few hundred); this bound stays far below the backstop.
const tp_bound_ms = 3000
// How long a client that stops reading waits for the TLS worker to park a
// /big response: its send loop fills the bounded kernel buffers (see
// tp_slow_reader) in a few ms. Only reaching the park depends on it; a wait
// too short makes a case miss the path it targets, it never fails one.
const tp_park_wait = time.Duration(200 * time.millisecond)

fn tp_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.len > 5 && req[5] == `b` { // GET /big
		res << tp_big_head
		old := res.len
		unsafe {
			res.grow_len(tp_big_len)
			vmemset(&res[old], `x`, tp_big_len)
		}
		return .done
	}
	res << tp_ok_head
	unsafe { res.push_many(&req[4], 4) } // the path
	if req[5] == `p` { // GET /pad
		res[res.len - 1] = tp_no_pad_state(client_fd)
	}
	return .done
}

// tp_no_pad_state is TLS_RX_EXPECT_NO_PAD as the server's socket reports it:
// `1` set, `0` not set, `-` when getsockopt fails (the connection is not on
// kTLS, or the kernel predates the option).
fn tp_no_pad_state(fd int) u8 {
	mut v := 0
	mut l := u32(sizeof(v))
	if C.getsockopt(fd, tp_sol_tls, tp_tls_rx_expect_no_pad, &v, &l) != 0 {
		return `-`
	}
	return if v != 0 { `1` } else { `0` }
}

// tp_unbufferable_len is a body size the kernel cannot hold while a
// tp_slow_reader client is not reading: more than the largest send buffer TCP
// autotuning may grow the server's socket to (the last field of tcp_wmem;
// nothing sets SO_SNDBUF) plus the client's locked receive buffer. Record and
// skb overhead only shrink what fits.
fn tp_unbufferable_len() int {
	mem := (os.read_file('/proc/sys/net/ipv4/tcp_wmem') or { '' }).fields() // min default max
	return (1 << 20) + if mem.len == 3 { mem[2].int() } else { 32 << 20 }
}

// tp_start serves tp_handler over HTTPS on one epoll TLS worker.
fn tp_start(limits server.Limits) !&vtest.Harness {
	return tp_start_no_pad(limits, false)
}

// tp_start_no_pad is tp_start, opting in to TLS_RX_EXPECT_NO_PAD when no_pad
// is set (otherwise the config keeps its default).
fn tp_start_no_pad(limits server.Limits, no_pad bool) !&vtest.Harness {
	os.signal_ignore(.pipe) // see tt_start
	$if linux {
		cfg := tls.new_self_signed()!
		if no_pad {
			cfg.set_ktls_rx_no_pad(true)
		}
		return vtest.start(server.ServerConfig{
			io_multiplexing: .epoll
			workers:         1
			tls_config:      cfg
			handler:         tp_handler
			limits:          limits
		})
	} $else {
		return error('the TLS worker is the Linux epoll backend')
	}
}

// --- openssl client helpers (return values; asserts stay in the scenario fn,
// docs/VTEST.md rule 1) -------------------------------------------------------

fn tp_dial(port int) !&openssl.SSLConn {
	mut c := openssl.new_ssl_conn(validate: false)!
	c.dial('127.0.0.1', port)!
	c.set_read_timeout(tp_backstop)
	return c
}

// tp_req is GET /NNN.
fn tp_req(i int) []u8 {
	return 'GET /${i:03} HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
}

// tp_resp is the answer to tp_req(i).
fn tp_resp(i int) []u8 {
	mut r := tp_ok_head.clone()
	r << '/${i:03}'.bytes()
	return r
}

// tp_resps is the answers to requests first..last, concatenated in order.
fn tp_resps(first int, last int) []u8 {
	mut r := []u8{}
	for i in first .. last + 1 {
		r << tp_resp(i)
	}
	return r
}

// tp_read_n reads until n bytes of plaintext arrived, the connection ended or
// the backstop fired, and returns what arrived.
fn tp_read_n(mut c openssl.SSLConn, n int) []u8 {
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

// tp_cork holds (on) or releases (off) the client's TCP segments: TLS records
// written while corked leave together, so they reach the server in the same
// burst.
fn tp_cork(c &openssl.SSLConn, on bool) {
	v := int(on)
	C.setsockopt(c.handle, C.IPPROTO_TCP, C.TCP_CORK, &v, sizeof(v))
}

// tp_slow_reader locks the client's receive buffer small (no receive
// autotuning): while the client is not reading, the kernel then holds at most
// the server's send buffer (wmem max) plus this, so a /big body just past
// wmem max is certain to park the TLS worker — instead of one past wmem +
// rmem max (tt_unbufferable_len in tls_timeouts_test.v), which is slow to
// read through a small window.
fn tp_slow_reader(c &openssl.SSLConn) {
	v := 32 * 1024
	C.setsockopt(c.handle, C.SOL_SOCKET, C.SO_RCVBUF, &v, sizeof(v))
}

// tp_big_ok reports whether `got` starts with the whole /big response,
// byte-exact: its head, then tp_big_len bytes of `x`. A second write issued
// while the response was parked would duplicate, drop or interleave bytes.
fn tp_big_ok(got []u8) bool {
	if got.len < tp_big_head.len + tp_big_len || got[..tp_big_head.len] != tp_big_head {
		return false
	}
	for b in got[tp_big_head.len..tp_big_head.len + tp_big_len] {
		if b != `x` {
			return false
		}
	}
	return true
}

fn tp_close(mut c openssl.SSLConn) {
	c.shutdown() or {}
}

// --- scenarios ---------------------------------------------------------------

// Requests pipelined in one write (one TLS record) are all answered, in order.
// Before #152 the worker framed the first, trimmed the rest away, and the
// second response never came.
fn check_tls_pipelined_one_record(n int) ! {
	mut h := tp_start(server.Limits{})!
	defer {
		h.stop()
	}
	mut c := tp_dial(h.port())!
	defer {
		tp_close(mut c)
	}
	mut reqs := []u8{}
	for i in 1 .. n + 1 {
		reqs << tp_req(i)
	}
	sw := time.new_stopwatch()
	c.write(reqs)!
	want := tp_resps(1, n)
	got := tp_read_n(mut c, want.len)
	elapsed := sw.elapsed().milliseconds()
	assert got == want, 'all ${n} pipelined requests must be answered in order: got ${got.len} of ${want.len} bytes'
	assert elapsed < tp_bound_ms, '${n} pipelined requests took ${elapsed}ms (${tp_backstop.milliseconds()}ms = a response never came)'
	// The connection keeps serving after the burst.
	c.write(tp_req(n + 1))!
	assert tp_read_n(mut c, tp_resp(n + 1).len) == tp_resp(n + 1)
}

// Requests in separate TLS records that reach the server together: the worker
// must read past the first complete request (edge-triggered: no new edge
// reports the records already queued).
fn check_tls_pipelined_separate_records() ! {
	mut h := tp_start(server.Limits{})!
	defer {
		h.stop()
	}
	mut c := tp_dial(h.port())!
	defer {
		tp_close(mut c)
	}
	sw := time.new_stopwatch()
	tp_cork(c, true)
	for i in 1 .. 4 {
		c.write(tp_req(i))! // one record each
	}
	tp_cork(c, false)
	want := tp_resps(1, 3)
	got := tp_read_n(mut c, want.len)
	elapsed := sw.elapsed().milliseconds()
	assert got == want, 'every queued record must be read and answered in order: got ${got.len} of ${want.len} bytes'
	assert elapsed < tp_bound_ms, 'took ${elapsed}ms'
}

// A complete request and the start of the next in one write: the first is
// answered at once, the partial is kept and answered once its tail arrives.
fn check_tls_pipelined_partial_tail() ! {
	mut h := tp_start(server.Limits{})!
	defer {
		h.stop()
	}
	mut c := tp_dial(h.port())!
	defer {
		tp_close(mut c)
	}
	second := tp_req(2)
	cut := 20 // mid-header
	mut burst := tp_req(1)
	burst << second[..cut]
	c.write(burst)!
	first := tp_read_n(mut c, tp_resp(1).len)
	assert first == tp_resp(1), 'the complete request must be answered: ${first.bytestr()}'
	c.write(second[cut..])!
	got := tp_read_n(mut c, tp_resp(2).len)
	assert got == tp_resp(2), 'the partial must be kept and answered once complete, got: ${got.bytestr()}'
}

// A response parked on WANT_WRITE is finished byte-exact before the requests
// pipelined behind it are answered — sent in the same write (same_write) or
// while it is parked (the client has read the start of the response, so the
// server has read the first request, and then stops reading until the server
// parked the rest: far more than the socket buffers hold). Before #152 the first form trimmed the second request
// away; the second form served it on top of the parked response: mbedTLS was
// re-called with different data after WANT_WRITE, and the parked buffer was
// overwritten.
fn check_tls_pipelined_behind_parked(same_write bool) ! {
	mut h := tp_start(server.Limits{})!
	defer {
		h.stop()
	}
	mut c := tp_dial(h.port())!
	defer {
		tp_close(mut c)
	}
	tp_slow_reader(c)
	sw := time.new_stopwatch()
	mut got := []u8{}
	if same_write {
		mut burst := tp_big_req.clone()
		burst << tp_req(1)
		burst << tp_req(2)
		c.write(burst)!
	} else {
		c.write(tp_big_req)!
		got << tp_read_n(mut c, tp_big_head.len)
		c.write(tp_req(1))!
		c.write(tp_req(2))!
	}
	time.sleep(tp_park_wait) // not reading: the worker parks the rest
	tail := tp_resps(1, 2)
	got << tp_read_n(mut c, tp_big_head.len + tp_big_len + tail.len - got.len)
	elapsed := sw.elapsed().milliseconds()
	assert tp_big_ok(got), 'the parked response must arrive whole and unmixed (${got.len} bytes received)'
	assert got[tp_big_head.len + tp_big_len..] == tail, 'the requests behind the parked response must be answered after it, in order, got: ${got[tp_big_head.len +
		tp_big_len..].bytestr()}'
	assert elapsed < tp_bound_ms, 'took ${elapsed}ms'
}

// A partial request pipelined behind a complete one gets its own read
// deadline, armed when the burst ends, not the accept-time one the first
// request ran on. The client waits half the budget before sending, then
// completes the partial just after the accept-time deadline has passed on the
// server's clock — witnessed by a silent connection dialed right after it,
// which that deadline reaps.
fn check_tls_pipelined_partial_fresh_deadline() ! {
	budget := 800
	mut h := tp_start(server.Limits{
		read_timeout_ms: budget
		idle_timeout_ms: -1
	})!
	defer {
		h.stop()
	}
	mut c := tp_dial(h.port())!
	defer {
		tp_close(mut c)
	}
	mut witness := tp_dial(h.port())!
	defer {
		tp_close(mut witness)
	}
	wsw := time.new_stopwatch()
	time.sleep(budget / 2 * time.millisecond)
	second := tp_req(2)
	mut burst := tp_req(1)
	burst << second[..20]
	c.write(burst)!
	assert tp_read_n(mut c, tp_resp(1).len) == tp_resp(1)
	reaped := tp_read_n(mut witness, 1)
	reaped_ms := wsw.elapsed().milliseconds()
	assert reaped.len == 0 && reaped_ms < tp_bound_ms, 'the silent witness must be reaped by its accept-time deadline, read ${reaped.len} bytes after ${reaped_ms}ms'
	c.write(second[20..])!
	got := tp_read_n(mut c, tp_resp(2).len)
	assert got == tp_resp(2), 'a pipelined partial must not inherit the accept-time deadline, got: "${got.bytestr()}" (empty = reaped)'
}

// A client that resets the connection mid-response must not kill the
// server. Userspace mbedTLS used to send with write(): the send that meets the
// reset fails with ECONNRESET, and the next write to the dead socket — the
// close_notify as the server drops the session — raised SIGPIPE, whose
// default action ends the whole process (every worker, every connection). The
// client reads at full speed, so the server is inside its send loop when the
// reset lands, then aborts. SIGPIPE is at its default action here: were it
// raised, this test binary would die with it.
fn check_tls_client_reset_mid_response() ! {
	mut h := tp_start(server.Limits{})!
	defer {
		h.stop()
	}
	C.signal(C.SIGPIPE, C.SIG_DFL)
	defer {
		os.signal_ignore(.pipe)
	}
	for _ in 0 .. 5 {
		mut a := tp_dial(h.port())!
		a.write(tp_big_req)!
		tp_read_n(mut a, 256 * 1024)
		// Abort: linger 0 makes close() send a RST. The openssl client never
		// writes to this connection again (no close_notify), so only the
		// server can hit the dead socket.
		linger := C.linger{
			l_onoff:  1
			l_linger: 0
		}
		C.setsockopt(a.handle, C.SOL_SOCKET, C.SO_LINGER, &linger, sizeof(linger))
		C.close(a.handle)
	}
	// One worker handles events in order: the resets come before this
	// connection's handshake. The server must still be serving.
	mut b := tp_dial(h.port())!
	defer {
		tp_close(mut b)
	}
	b.write(tp_req(1))!
	assert tp_read_n(mut b, tp_resp(1).len) == tp_resp(1), 'the server must survive clients that reset mid-response'
}

// TLS_RX_EXPECT_NO_PAD is opt-in: kernels before commit 1c8629651cb5 corrupt
// what recv() returns once a record turns out padded, so a default config must
// leave the kTLS socket without it. Opted in, the socket has it, and records
// pipelined in one burst (the kernel decrypts them straight into the request
// buffer) are still answered in order. A `-` state (no kTLS: the tls module is
// not loaded, or the kernel predates the option) passes either way.
fn check_tls_ktls_rx_no_pad(enabled bool) ! {
	mut h := tp_start_no_pad(server.Limits{}, enabled)!
	defer {
		h.stop()
	}
	mut c := tp_dial(h.port())!
	defer {
		tp_close(mut c)
	}
	tp_cork(c, true)
	for i in 1 .. 11 {
		c.write(tp_req(i))! // one record each
	}
	c.write(tp_pad_req)!
	tp_cork(c, false)
	mut want := tp_resps(1, 10)
	want << tp_ok_head
	want << '/pa'.bytes()
	got := tp_read_n(mut c, want.len + 1)
	assert got.len == want.len + 1 && got[..want.len] == want, 'every pipelined request must be answered in order: got ${got.len} of ${want.len + 1} bytes'
	state := got[want.len]
	if enabled {
		assert state != `0`, 'set_ktls_rx_no_pad(true) must set TLS_RX_EXPECT_NO_PAD on the kTLS socket'
	} else {
		assert state != `1`, 'TLS_RX_EXPECT_NO_PAD must stay off unless the config opts in'
	}
}

// --- tests -------------------------------------------------------------------

fn test_tls_pipelined_in_one_record() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_pipelined_one_record(2)!
			// Answers past one TLS record (tls_batch_bytes): the batch is sent
			// mid-burst and the burst goes on.
			check_tls_pipelined_one_record(400)!
		}
	}
}

fn test_tls_pipelined_in_separate_records() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_pipelined_separate_records()!
		}
	}
}

fn test_tls_pipelined_partial_tail() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_pipelined_partial_tail()!
		}
	}
}

fn test_tls_pipelined_behind_parked_response() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_pipelined_behind_parked(true)!
			check_tls_pipelined_behind_parked(false)!
		}
	}
}

fn test_tls_pipelined_partial_fresh_deadline() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_pipelined_partial_fresh_deadline()!
		}
	}
}

fn test_tls_client_reset_mid_response() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_client_reset_mid_response()!
		}
	}
}

fn test_tls_ktls_rx_no_pad_is_opt_in() ! {
	$if linux {
		$if vanilla_tls ? {
			check_tls_ktls_rx_no_pad(false)!
			check_tls_ktls_rx_no_pad(true)!
		}
	}
}
