// Behavioural end-to-end tests for the connection state machine, run against
// EVERY backend: HTTP/1.1 pipelining, request framing across TCP segments,
// max_connections, read timeout, connection reaping (a silent connect, an idle
// keep-alive peer, the idle opt-out, max_connections slots freed by reaping),
// large-body drain, half-close, Expect: 100-continue, and graceful shutdown. Migrated from
// http_server/backend_behaviors_test.v onto vtest (docs/VTEST.md): scripts are
// data, drive()/start() own the whole lifecycle, ports are always ephemeral,
// and the only clocks are the server's own Limits — the stopwatches below
// MEASURE server-clock events after they completed; they are never read
// deadlines.
//
// The checks are backend-agnostic (the server enforces the same behaviour on
// every backend), so each behaviour is written ONCE as a check_*(backend)
// helper and invoked per backend: epoll and io_uring under $if linux (those
// enum values exist only there; io_uring additionally self-skips at runtime
// where io_uring_setup is sandboxed, e.g. GitHub's hosted runners), iocp under
// $if windows. On other platforms every test is a no-op.
//
// Standalone on purpose: vtest imports server, so this file lives outside
// that module (no import cycle) and uses only public API.
import os
import strconv
import sync.stdatomic
import time
import server
import core
import http1_1.request_parser
import http1_1.response
import socket
import transport
import vtest

#include <signal.h>

struct C.linger {
	l_onoff  int
	l_linger int
}

fn C.signal(sig int, handler voidptr) voidptr

const bb_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
// A request head that stops mid-header: the tail of a split write, and the
// stalled-client probe (it never completes on its own).
const bb_partial_head = 'GET / HTTP/1.1\r\nHo'.bytes()
const bb_split_tail = 'st: x\r\n\r\n'.bytes()

const bb_ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()

const bb_expect_head = 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n'.bytes()
const bb_expect_body = 'hello'.bytes()

const bb_upload_body_len = 2 * 1024 * 1024 // 2 MiB > 1 MiB threshold ⇒ drain path
const bb_upload_chunk_len = 64 * 1024
const bb_upload_resp_head = 'HTTP/1.1 200 OK\r\nContent-Length: '.bytes()
const bb_upload_resp_sep = '\r\nConnection: keep-alive\r\n\r\n'.bytes()

fn bb_ok_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	res << bb_ok_response
	return .done
}

// bb_wi appends n's decimal digits into `out` — itoa into a stack scratch,
// then push_many. No allocation, no `.str()` (docs/BEST_PRACTICES.md).
fn bb_wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// bb_upload_handler answers a /upload by the DECLARED Content-Length only — it
// never touches the body. This is the shape the large-body streaming path
// requires (the head alone is passed; the body is drained + discarded),
// mirroring the HttpArena vanilla /upload handler. The echoed body is the
// decimal digits of the declared length, framed without `${}`/`+`.
fn bb_upload_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	hr := request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	cl := i64(hr.content_length())
	// Digit count of cl = Content-Length of the echo.
	mut digits := 1
	mut v := cl
	for v >= 10 {
		v /= 10
		digits++
	}
	res << bb_upload_resp_head
	bb_wi(mut res, i64(digits))
	res << bb_upload_resp_sep
	bb_wi(mut res, cl)
	return .done
}

// --- client-side payload builders (test data, not request-serving code) ----

fn bb_pipeline(n int) []u8 {
	mut out := []u8{cap: bb_req.len * n}
	for _ in 0 .. n {
		out << bb_req
	}
	return out
}

fn bb_concat(a []u8, b []u8) []u8 {
	mut out := []u8{cap: a.len + b.len}
	out << a
	out << b
	return out
}

// --- backend-agnostic behaviour checks ------------------------------------
// Every assert of a scenario lives in the same fn as that scenario's defer
// (a failed assert longjmps and runs only same-frame defers — VTEST.md rule 1).

// check_pipelining_and_framing: two concurrent connections.
//   conn 0 — 8 pipelined requests in ONE write → 8 framed responses, in order.
//   conn 1 — framing across TCP segments: round 1 sends a full request PLUS a
//     partial next one; its `want: 1` is the barrier — the response to request
//     1 proves the server already consumed the segment carrying the partial
//     head, so round 2's tail bytes arrive to a connection that must resume a
//     buffered partial request (the old file forced this split with a sleep;
//     the pipelined barrier does it with completion, no clock).
fn check_pipelining_and_framing(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_pipeline(8)
					want: 8
				},
			]
		},
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_concat(bb_req, bb_partial_head)
					want: 1
				},
				vtest.Round{
					send: bb_split_tail
					want: 1
				},
			]
		},
	])!
	pipe := out.conns[0]
	assert pipe.connect_err == '', pipe.connect_err
	assert pipe.frames.len == 8, '${backend}: pipelining expected 8 responses, got ${pipe.frames.len}'
	for f in pipe.frames {
		assert f.bytestr().starts_with('HTTP/1.1 200')
	}
	split := out.conns[1]
	assert split.connect_err == '', split.connect_err
	assert split.frames.len == 2, '${backend}: split request expected 2 responses, got ${split.frames.len}'
	assert split.frames[1].bytestr().starts_with('HTTP/1.1 200'), '${backend}: request split across two writes not answered'
	assert out.inflight_after == 0
}

// check_max_connections: 4 served keep-alive connections are HELD OPEN (fire()
// keeps them in the reactor until stop()), then a 5th connection — over
// max_connections=4 — must be refused at accept (close with no response). The
// two fire() groups are the cross-connection ordering: the first returns only
// after all 4 responses arrived, so the count is exactly 4 when the 5th lands.
fn check_max_connections(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
		limits:          server.Limits{
			max_connections: 4
		}
	})!
	defer {
		h.stop()
	}
	held := h.fire(vtest.repeat(4, vtest.Script{
		rounds: [
			vtest.Round{
				send: bb_req
			},
		]
	}))!
	for i, c in held.conns {
		assert c.connect_err == '', '${backend}: conn ${i}: ${c.connect_err}'
		assert c.frames.len == 1, '${backend}: connection ${i} should be served, got ${c.frames.len}'
		assert c.frames[0].bytestr().starts_with('HTTP/1.1 200')
	}
	fifth := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_req
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c5 := fifth.conns[0]
	assert c5.eof, '${backend}: connection over max_connections=4 must be closed'
	assert c5.frames.len == 0, '${backend}: connection over max_connections=4 must be refused, got ${c5.frames.len} responses'
}

// check_read_timeout: a partial request that never completes must be ENDED by
// the server's own read_timeout reaper (408-then-close on epoll, bare EOF on
// io_uring) — never served a 200. then_eof means completion can ONLY come from
// the server's clock; the stopwatch MEASURES how long that took after the
// fact (the old file's <1500ms promptness assert), it is not a deadline.
fn check_read_timeout(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
		limits:          server.Limits{
			read_timeout_ms: 400
		}
	})!
	defer {
		h.stop()
	}
	sw := time.new_stopwatch()
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_partial_head
					want: 0
				},
			]
			then_eof: true
		},
	])!
	elapsed := sw.elapsed().milliseconds()
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: server read_timeout must end a stalled connection'
	assert !c.unmet
	assert !c.raw.bytestr().contains('200 OK'), '${backend}: stalled partial request must not be served a 200, got: ${c.raw.bytestr()}'
	assert elapsed < 1500, '${backend}: server should end the stalled request promptly (read_timeout_ms=400), took ${elapsed}ms'
}

// silent_script is a connection that never sends a byte and requires the
// SERVER to close it: it can only complete through the server's own clock.
const silent_script = vtest.Script{
	rounds:   [
		vtest.Round{
			send: []u8{}
			want: 0
		},
	]
	then_eof: true
}

// check_silent_conn_timeout: a connection that NEVER sends a byte (a raw TCP
// connect; a client stuck before its TLS ClientHello is the same shape) must
// be reaped by the deadline armed at accept — otherwise it holds a
// max_connections slot forever. Run with read_timeout_ms (the first request's
// budget starts at accept) and with only idle_timeout_ms (a connection that
// has sent nothing is idle). A peer that never spoke gets no 408.
fn check_silent_conn_timeout(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
		limits:          limits
	})!
	defer {
		h.stop()
	}
	sw := time.new_stopwatch()
	out := h.fire([silent_script])!
	elapsed := sw.elapsed().milliseconds()
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: a silent connection must be closed by the accept-time deadline'
	assert c.raw.len == 0, '${backend}: a peer that never spoke must be closed without a response, got: ${c.raw.bytestr()}'
	assert elapsed < 1500, '${backend}: silent connection should be reaped promptly (400ms budget), took ${elapsed}ms'
}

// check_idle_keepalive_timeout: after a response, a keep-alive connection
// whose peer goes quiet (a phone that switched networks sends no FIN) must be
// closed SILENTLY (no 408) once the idle deadline passes. Run with only
// read_timeout_ms (idle inherits it) and with only idle_timeout_ms.
fn check_idle_keepalive_timeout(backend server.IOBackend, limits server.Limits) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
		limits:          limits
	})!
	defer {
		h.stop()
	}
	sw := time.new_stopwatch()
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_req
					want: 1
				},
				vtest.Round{
					send: []u8{}
					want: 0
				},
			]
			then_eof: true
		},
	])!
	elapsed := sw.elapsed().milliseconds()
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1, '${backend}: the request before going idle must be served, got ${c.frames.len}'
	assert c.eof, '${backend}: an idle keep-alive connection must be closed by the idle deadline'
	assert !c.raw.bytestr().contains('408'), '${backend}: idle close must be silent (no 408), got: ${c.raw.bytestr()}'
	assert elapsed < 1500, '${backend}: idle connection should be reaped promptly (400ms budget), took ${elapsed}ms'
}

// check_idle_opt_out: idle_timeout_ms < 0 disables idle reaping even with a
// read timeout set (a handler that hands the fd to another thread to stream
// needs this). The witness is the server's own clock: connection B is silent,
// so it is reaped by its accept-time read deadline, which fires at least
// read_timeout_ms after A went idle — A must still serve a second request.
// One worker, so A's deadline (if one were wrongly armed) is due no later
// than B's in the same sweep.
fn check_idle_opt_out(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_ok_handler
		limits:          server.Limits{
			read_timeout_ms: 400
			idle_timeout_ms: -1
		}
	})!
	defer {
		h.stop()
	}
	a := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_req
					want: 1
				},
			]
		},
	])!
	assert a.conns[0].frames.len == 1
	b := h.fire([silent_script])!
	assert b.conns[0].eof, '${backend}: the silent witness must still be reaped by read_timeout_ms'
	again := h.send(a.group, bb_req, vtest.frames(2))!
	c := again.conns[0]
	assert !c.eof, '${backend}: idle_timeout_ms: -1 must keep an idle keep-alive connection open'
	assert c.frames.len == 2, '${backend}: the idle connection must serve its next request, got ${c.frames.len}'
}

// bb_big_len is a response body a fresh loopback connection cannot absorb in
// one send while the client reads it: a non-blocking send takes at most the
// send buffer (tcp_wmem max, 4 MiB by default) plus the new connection's
// receive window (tcp_rmem default, 128 KiB) — so the server's synchronous
// send hits EAGAIN and the response is finished by the writable drain
// (EPOLLOUT / POLLOUT). It stays under the backends' 8 MiB pending-write cap
// (sm_max_pending_write / pl_max_pending_write), which would close the
// connection instead.
const bb_big_len = 7 * 1024 * 1024

// bb_big_handler answers with a bb_big_len body, built into the server-owned
// buffer (a test-only allocation; the size is what matters here).
fn bb_big_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	res << bb_upload_resp_head
	bb_wi(mut res, bb_big_len)
	res << bb_upload_resp_sep
	old := res.len
	unsafe {
		res.grow_len(bb_big_len)
		vmemset(&res[old], `x`, bb_big_len)
	}
	return .done
}

// check_idle_after_parked_write: a response too big to send synchronously
// completes on the writable-drain path, and the connection is back at rest
// only then — the idle deadline must be armed THERE too, or a keep-alive peer
// that vanishes after a large download holds its slot forever.
fn check_idle_after_parked_write(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_big_handler
		limits:          server.Limits{
			read_timeout_ms: 400
		}
	})!
	defer {
		h.stop()
	}
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_req
					want: 1
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: the large response must arrive complete'
	assert c.frames.len == 1
	assert c.frames[0].len > bb_big_len
	assert c.eof, '${backend}: after a drained large response the idle deadline must close the connection'
	assert c.raw.len == c.frames[0].len, '${backend}: idle close must be silent (no 408)'
}

// check_reaped_slots_free_max_connections: the production lockout. Silent
// connections fill max_connections; once their deadlines reap them, a new
// connection must be SERVED, not refused at accept. One worker: io_uring
// releases a reaped slot only when that ring drains the recv completion, so
// with several rings another ring's accept could still see the old count.
fn check_reaped_slots_free_max_connections(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_ok_handler
		limits:          server.Limits{
			max_connections: 2
			read_timeout_ms: 300
		}
	})!
	defer {
		h.stop()
	}
	silent := h.fire(vtest.repeat(2, silent_script))!
	for i, c in silent.conns {
		assert c.eof, '${backend}: silent conn ${i} must be reaped'
	}
	next := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_req
				},
			]
		},
	])!
	c := next.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1, '${backend}: reaped connections must free their max_connections slots'
	assert c.frames[0].bytestr().starts_with('HTTP/1.1 200')
}

// check_first_byte_clears_idle: the first byte of the next request ends the
// idle wait (contract rule 3). A is served, then sends a partial head: from
// then on only the 3 s read budget may apply. Witness W is served and then
// idle-reaped 300 ms later — by then A has sat still longer than its idle
// budget too, and (one worker) a wrongly surviving idle deadline on A would
// have been due in the same sweep. A must still complete its request and
// serve one more.
fn check_first_byte_clears_idle(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_ok_handler
		limits:          server.Limits{
			read_timeout_ms: 3000
			idle_timeout_ms: 300
		}
	})!
	defer {
		h.stop()
	}
	a := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_req
					want: 1
				},
				vtest.Round{
					send: bb_partial_head
					want: 0
				},
			]
		},
	])!
	assert a.conns[0].frames.len == 1
	w := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_req
					want: 1
				},
			]
			then_eof: true
		},
	])!
	assert w.conns[0].eof, '${backend}: the idle witness must be reaped by idle_timeout_ms'
	done := h.send(a.group, bb_split_tail, vtest.frames(2))!
	assert !done.conns[0].eof, '${backend}: the first byte must clear the idle deadline — A was reaped mid-request'
	assert done.conns[0].frames.len == 2
	more := h.send(a.group, bb_req, vtest.frames(3))!
	assert more.conns[0].frames.len == 3, '${backend}: keep-alive after the completed request broke'
}

// check_keepalive_under_timeouts: with read and idle deadlines armed (5 s,
// far longer than the test), keep-alive must keep working: a request split
// across two writes and a pipelined pair are served. That the first byte
// really clears the idle deadline is check_first_byte_clears_idle's job.
fn check_keepalive_under_timeouts(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
		limits:          server.Limits{
			read_timeout_ms: 5000
			idle_timeout_ms: 5000
		}
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_req
					want: 1
				},
				vtest.Round{
					send: bb_partial_head
					want: 0
				},
				vtest.Round{
					send: bb_split_tail
					want: 1
				},
				vtest.Round{
					send: bb_req.repeat(2)
					want: 2
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: keep-alive broke under read/idle deadlines'
	assert c.frames.len == 4, '${backend}: expected 4 responses, got ${c.frames.len}'
	assert out.inflight_after == 0
	assert out.active_after == 0
}

// check_large_upload_drain drives bodies larger than the streaming threshold
// (sm_stream_body_above / iou_stream_body_above = 1 MiB) so they take the
// drain path: the head is answered and the body is consumed off the socket
// without ever being buffered. Guarded properties:
//   • EXACT drain + keep-alive — upload 1 is a second full upload on the SAME
//     connection; it frames only if the drain consumed EXACTLY upload 0's body
//     (no over-read into this request, no under-read leaving the connection
//     stuck) and keep-alive survived the drain.
//   • the head-only handler answers by the declared Content-Length (both
//     responses must echo it).
// Upload 0 is still fed in two rounds (head + one chunk, then the rest) so the
// server must resume the drain across reads. The old file's respond-BEFORE-
// drain silence probe ("no bytes for 500ms after the first chunk") is a
// negative timing assertion that needs a client-side clock — inexpressible
// under the vtest contract, deliberately dropped.
fn check_large_upload_drain(backend server.IOBackend) ! {
	head :=
		'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${bb_upload_body_len}\r\n\r\n'.bytes()
	first_chunk := []u8{len: bb_upload_chunk_len, init: u8(0x61)}
	rest := []u8{len: bb_upload_body_len - bb_upload_chunk_len, init: u8(0x61)}
	full_body := []u8{len: bb_upload_body_len, init: u8(0x61)}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_upload_handler
		limits:          server.Limits{
			max_request_bytes: 8 * 1024 * 1024 // headroom for the 2 MiB bodies
		}
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_concat(head, first_chunk)
					want: 0
				},
				vtest.Round{
					send: rest
					want: 1
				},
				vtest.Round{
					send: bb_concat(head, full_body)
					want: 1
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: connection ended before both uploads were answered'
	assert c.frames.len == 2, '${backend}: expected one response per upload, got ${c.frames.len}'
	echo := '\r\n\r\n${bb_upload_body_len}'
	f0 := c.frames[0].bytestr()
	assert f0.count('HTTP/1.1 200') == 1, '${backend}: upload 0 not answered after the body completed'
	assert f0.ends_with(echo), '${backend}: upload 0 must echo Content-Length ${bb_upload_body_len}, got: ${f0}'
	f1 := c.frames[1].bytestr()
	assert f1.count('HTTP/1.1 200') == 1, '${backend}: keep-alive after a drained upload broke (drain over-read or under-read?)'
	assert f1.ends_with(echo), '${backend}: upload 1 must echo Content-Length ${bb_upload_body_len}, got: ${f1}'
	assert out.inflight_after == 0
}

// check_streamed_body_over_max_body_bytes: regression for the streamed-path
// limit bypass. A body declared ABOVE max_body_bytes but large enough to take
// the streaming path (> the 1 MiB threshold) must be rejected from the head
// alone — 413 and close, exactly like the framed path — instead of reaching
// the handler. Before the fix the streamed gate only checked
// max_request_bytes, so such a body bypassed max_body_bytes entirely and was
// answered 200. The 413 bytes themselves are asserted only when they arrived:
// the server closes with the body unread, so the kernel may RST and discard
// the response in flight — the hard contract is "no 200, connection ended".
fn check_streamed_body_over_max_body_bytes(backend server.IOBackend) ! {
	head :=
		'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${bb_upload_body_len}\r\n\r\n'.bytes()
	first_chunk := []u8{len: bb_upload_chunk_len, init: u8(0x61)}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_upload_handler
		limits:          server.Limits{
			max_body_bytes:    64 * 1024 // far below the 2 MiB declared body
			max_request_bytes: 8 * 1024 * 1024
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_concat(head, first_chunk) // enough to trip the streaming decision, then stop
					want: 0
				},
			]
			then_eof: true // completion can only come from the server's 413+close
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, '${backend}: oversized streamed body must end in a server close'
	raw := c.raw.bytestr()
	assert !raw.contains('200'), '${backend}: a streamed body over max_body_bytes must never reach the handler, got: ${raw}'
	if c.raw.len > 0 {
		assert raw.starts_with('HTTP/1.1 413'), '${backend}: expected the 413 rejection, got: ${raw}'
	}
}

// check_half_close_after_request: a client that sends a complete request and
// then half-closes its WRITE side (shut_wr == shutdown(SHUT_WR)) must still
// receive the full response on the still-open read side (RFC 9112 §9.6).
// Regression test for issue #103, where the recv→0 (EOF) tore the connection
// down before the already-computed response was flushed.
fn check_half_close_after_request(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
	}, [
		vtest.Script{
			rounds:  [
				vtest.Round{
					send: bb_req
				},
			]
			shut_wr: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1, '${backend}: response must arrive after a half-close (SHUT_WR), got ${c.frames.len} — issue #103'
	assert c.frames[0].bytestr().starts_with('HTTP/1.1 200')
	assert out.inflight_after == 0
}

// check_expect_100_continue: a client that sends the head with
// `Expect: 100-continue` and holds the body must be prompted with an interim
// `100 Continue` (RFC 9110 §10.1.1); after it sends the body it gets the final
// response. Round 1's want:1 is satisfied by the interim 100 (a headers-only
// frame); round 2 sends the body only then, and its want:1 makes the
// cumulative target 2 frames — 100 first, final 200 second. Without the
// prompt the server would wait for a body the client is deliberately
// withholding, and this test would hang (the correct liveness signal).
fn check_expect_100_continue(backend server.IOBackend) ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_expect_head
					want: 1
				},
				vtest.Round{
					send: bb_expect_body
					want: 1
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 2, '${backend}: expected interim 100 + final 200, got ${c.frames.len} frames'
	assert c.frames[0].bytestr().starts_with('HTTP/1.1 100'), '${backend}: Expect: 100-continue must be answered with an interim 100'
	assert c.frames[1].bytestr().starts_with('HTTP/1.1 200'), '${backend}: final response must follow the body after 100 Continue'
	assert out.inflight_after == 0
}

// --- sendfile hand-off slot hygiene ------------------------------------------

// The file behind the region the bb_file_handler routes hand off: only the
// middle part (bb_file_off, bb_file_len) is queued, so a wrong offset shows.
const bb_file_data = 'skip-head|region handed off with core.queue_file|skip-tail'
const bb_file_off = 10 // 'skip-head|'.len
const bb_file_len = 38 // 'region handed off with core.queue_file'.len
// /short promises (and queues) more than the file holds past bb_file_off: 48
// bytes exist there, so its region always reads short.
const bb_short_len = 60
const bb_close_req = 'GET /close HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const bb_suspend_req = 'GET /suspend HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const bb_short_req = 'GET /short HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const bb_big_get_req = 'GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const bb_parkfile_req = 'GET /parkfile HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const bb_upgrade_req = 'GET /upgrade HTTP/1.1\r\nHost: x\r\nUpgrade: blob\r\nConnection: Upgrade\r\n\r\n'.bytes()
const bb_switching = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: blob\r\nConnection: Upgrade\r\n\r\n'.bytes()
// bb_conn_end ends every answer of bb_file_conn, with the region before it or
// not, so a client can wait for it either way.
const bb_conn_end = '|end'
const bb_close_sep = '\r\nConnection: close\r\n\r\n'.bytes()

// bb_target_is reports whether the request line's target is exactly `target`,
// whatever the method.
fn bb_target_is(req []u8, target string) bool {
	mut sp := 0
	for sp < req.len && req[sp] != ` ` {
		sp++
	}
	start := sp + 1
	if req.len < start + target.len + 1 {
		return false
	}
	for i in 0 .. target.len {
		if req[start + i] != target[i] {
			return false
		}
	}
	return req[start + target.len] == ` `
}

// bb_file_head appends a 200 head promising `length` body bytes.
fn bb_file_head(mut res []u8, length i64, sep []u8) {
	res << bb_upload_resp_head
	bb_wi(mut res, length)
	res << sep
}

// bb_queue_region hands [off, off+length) of file_fd off with core.queue_file
// and counts the accepted hand-off in `accepted`. Where queue_file refuses
// (tcc builds compile the slot inert) it appends the bytes itself.
// append_file_region is POSIX only; on Windows nothing runs these routes (the
// checks that use them are epoll's), they only have to compile.
fn bb_queue_region(mut res []u8, file_fd int, off i64, length i64, accepted &core.Counter) {
	if core.queue_file(file_fd, off, length) {
		stdatomic.add_i64(&accepted.n, 1)
	} else {
		$if !windows {
			core.append_file_region(mut res, file_fd, off, length)
		}
	}
}

// BbFileRef is bb_file_handler's file and counter, handed to its continuation
// as the watch payload.
struct BbFileRef {
	file_fd  int
	accepted &core.Counter
}

// bb_file_cont is /parkfile's continuation: headers, then the region handed
// off with bb_queue_region, .done.
fn bb_file_cont(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	ref := unsafe { &BbFileRef(watch_payload) }
	bb_file_head(mut out, bb_file_len, bb_upload_resp_sep)
	bb_queue_region(mut out, ref.file_fd, bb_file_off, bb_file_len, ref.accepted)
	return .done
}

// bb_file_conn is the ConnHandler /upgrade hands its connection to, with the
// BbFileRef as its takeover state: it answers every burst with the region,
// handed off with bb_queue_region, then bb_conn_end.
fn bb_file_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	ref := unsafe { &BbFileRef(takeover_state) }
	bb_queue_region(mut out, ref.file_fd, bb_file_off, bb_file_len, ref.accepted)
	core.append_str(mut out, bb_conn_end)
	return buf.len, core.Step.done
}

// bb_file_handler serves these routes over one borrowed file fd, counting
// every hand-off queue_file accepts in `accepted`:
//   /close    — headers, then the region handed off, .close
//   /suspend  — queues the whole file and returns .suspend with no watch armed
//               (a contract violation on purpose: the worker flushes the
//               nothing appended and closes)
//   /big      — headers, then the region handed off, .done (sent as the head
//               of a streamed large body, and as a plain GET)
//   /bigclose — queues the whole file and returns .close (sent as the head of
//               a streamed large body, where the worker answers 400 instead)
//   /short    — headers promising bb_short_len bytes, and that region handed
//               off, which the file cannot fill
//   /parkfile — parks on the client's own writability (the continuation runs
//               on the worker's next pass), and bb_file_cont answers as /big
//   /upgrade  — 101, and the connection goes to bb_file_conn
//   other     — bb_ok_response, .done, nothing queued
fn bb_file_handler(file_fd int, accepted &core.Counter) core.Handler {
	ref := &BbFileRef{
		file_fd:  file_fd
		accepted: accepted
	}
	return fn [file_fd, accepted, ref] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		if bb_target_is(req, '/parkfile') {
			event_loop.watch_fd(client_fd, .writable, bb_file_cont, voidptr(ref))
			return .suspend
		}
		if bb_target_is(req, '/upgrade') {
			if !core.queue_takeover(bb_file_conn, voidptr(ref)) {
				return .close // not takeover-capable: the check fails on the missing 101
			}
			res << bb_switching
			return .done
		}
		if bb_target_is(req, '/close') {
			bb_file_head(mut res, bb_file_len, bb_close_sep)
			bb_queue_region(mut res, file_fd, bb_file_off, bb_file_len, accepted)
			return .close
		}
		if bb_target_is(req, '/big') {
			bb_file_head(mut res, bb_file_len, bb_upload_resp_sep)
			bb_queue_region(mut res, file_fd, bb_file_off, bb_file_len, accepted)
			return .done
		}
		if bb_target_is(req, '/short') {
			bb_file_head(mut res, bb_short_len, bb_upload_resp_sep)
			bb_queue_region(mut res, file_fd, bb_file_off, bb_short_len, accepted)
			return .done
		}
		if bb_target_is(req, '/suspend') || bb_target_is(req, '/bigclose') {
			if core.queue_file(file_fd, 0, bb_file_data.len) {
				stdatomic.add_i64(&accepted.n, 1)
			}
			return if bb_target_is(req, '/suspend') { core.Step.suspend } else { core.Step.close }
		}
		res << bb_ok_response
		return .done
	}
}

// bb_two_ok is one keep-alive connection asking twice: both answers must be
// exactly bb_ok_response with nothing in between (checked on raw).
const bb_two_ok = vtest.Script{
	rounds: [
		vtest.Round{
			send: bb_req
		},
		vtest.Round{
			send: bb_req
		},
	]
}

// bb_file_fixture writes bb_file_data to a temp file and opens it.
fn bb_file_fixture(tag string) !(string, os.File) {
	path := os.join_path(os.temp_dir(), 'vanilla_bb_${tag}_${os.getpid()}.txt')
	os.write_file(path, bb_file_data)!
	f := os.open(path)!
	return path, f
}

// bb_assert_handoffs: every route that queued so far must have had its
// hand-off accepted, or the slot was never filled and the checks around it
// passed without testing anything. Under tcc the slot is inert by design.
fn bb_assert_handoffs(backend server.IOBackend, accepted &core.Counter, want i64) {
	$if !tinyc {
		got := stdatomic.load_i64(&accepted.n)
		assert got == want, '${backend}: ${want} core.queue_file hand-offs expected, the worker accepted ${got}'
	}
}

// check_queue_file_cleared_after_close: the sendfile hand-off slot
// (core.queue_file) is thread-local, so the worker must drain it after EVERY
// handler step, not only .done. One worker, so every connection below shares
// that thread's slot, and each fire() completes before the next starts:
//   1. GET /close queues a region and returns .close: the response must still
//      carry that body (sendfile(2) after the head, before the close; this
//      small one fits the socket buffer), byte-exact, then EOF.
//   2. GET / twice on a fresh connection: exactly two bb_ok_response. A region
//      left queued by step 1 would be taken by the first .done and streamed
//      after its response.
//   3. GET /suspend queues a region and suspends with no watch: no bytes, EOF.
//   4. Step 2 again: the region step 3 queued must have been dropped.
fn check_queue_file_cleared_after_close(backend server.IOBackend) ! {
	path, mut f := bb_file_fixture('queue_file')!
	defer {
		f.close()
		os.rm(path) or {}
	}
	accepted := &core.Counter{}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_file_handler(f.fd, accepted)
	})!
	defer {
		h.stop()
	}
	mut want_close := []u8{}
	bb_file_head(mut want_close, bb_file_len, bb_close_sep)
	want_close << bb_file_data[bb_file_off..bb_file_off + bb_file_len].bytes()
	want_two_ok := bb_concat(bb_ok_response, bb_ok_response)

	closed := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_close_req
				},
			]
			then_eof: true
		},
	])!
	c := closed.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: the .close response lost the body its handler queued (got ${c.raw.len} bytes)'
	assert c.eof, '${backend}: .close must end the connection'
	assert c.raw == want_close, '${backend}: .close response not byte-exact: ${c.raw.bytestr()}'
	bb_assert_handoffs(backend, accepted, 1)

	after_close := h.fire([bb_two_ok])!
	a := after_close.conns[0]
	assert a.connect_err == '', a.connect_err
	assert a.raw == want_two_ok, '${backend}: a region queued by a .close step leaked into the next request: ${a.raw.bytestr()}'

	suspended := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_suspend_req
					want: 0
				},
			]
			then_eof: true
		},
	])!
	s := suspended.conns[0]
	assert s.connect_err == '', s.connect_err
	assert s.eof, '${backend}: .suspend with no watch armed must close'
	assert s.raw.len == 0, '${backend}: .suspend with no watch armed sent bytes: ${s.raw.bytestr()}'
	bb_assert_handoffs(backend, accepted, 2)

	after_suspend := h.fire([bb_two_ok])!
	b := after_suspend.conns[0]
	assert b.connect_err == '', b.connect_err
	assert b.raw == want_two_ok, '${backend}: a region queued by a .suspend step leaked into the next request: ${b.raw.bytestr()}'
}

// check_queue_file_streamed_head: the head of a body over the streaming
// threshold (1 MiB) is the worker's other handler call (start_body_drain),
// and must drain the slot too. One worker, as above:
//   1. POST /big with a 2 MiB body (head and first chunk, then the rest),
//      then GET / on the same connection: the upload's reply carries the
//      region it queued, then exactly bb_ok_response.
//   2. GET / twice on a fresh connection: exactly two bb_ok_response.
//   3. POST /bigclose queues a region and returns .close: the worker answers
//      400 and closes, without the region (the close may reset the
//      connection before the 400 lands, so only a prefix of it is required).
//   4. Step 2 again: the region step 3 queued must have been dropped.
fn check_queue_file_streamed_head(backend server.IOBackend) ! {
	path, mut f := bb_file_fixture('queue_file_streamed')!
	defer {
		f.close()
		os.rm(path) or {}
	}
	accepted := &core.Counter{}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_file_handler(f.fd, accepted)
	})!
	defer {
		h.stop()
	}
	first_chunk := []u8{len: bb_upload_chunk_len, init: u8(0x61)}
	rest := []u8{len: bb_upload_body_len - bb_upload_chunk_len, init: u8(0x61)}
	big_head := 'POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: ${bb_upload_body_len}\r\n\r\n'.bytes()
	bigclose_head :=
		'POST /bigclose HTTP/1.1\r\nHost: x\r\nContent-Length: ${bb_upload_body_len}\r\n\r\n'.bytes()
	mut want_big := []u8{}
	bb_file_head(mut want_big, bb_file_len, bb_upload_resp_sep)
	want_big << bb_file_data[bb_file_off..bb_file_off + bb_file_len].bytes()
	want_two_ok := bb_concat(bb_ok_response, bb_ok_response)
	want_big_then_ok := bb_concat(want_big, bb_ok_response)
	// Wait for a byte count, not frames: a reply that lost its body would
	// leave the frame count short forever (vtest has no client timeout), and a
	// region that went to the next response instead adds up to the same count.
	big_then_ok_len := want_big_then_ok.len

	big := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_concat(big_head, first_chunk)
					want: 0
				},
				vtest.Round{
					send: rest
					want: 0
				},
				vtest.Round{
					send:  bb_req
					until: fn [big_then_ok_len] (acc []u8) bool {
						return acc.len >= big_then_ok_len
					}
				},
			]
		},
	])!
	u := big.conns[0]
	assert u.connect_err == '', u.connect_err
	assert !u.unmet, '${backend}: the streamed upload or the request after it went unanswered'
	assert u.raw == want_big_then_ok, '${backend}: the streamed head lost the region it queued, or it landed after the next response: ${u.raw.bytestr()}'
	bb_assert_handoffs(backend, accepted, 1)

	after_big := h.fire([bb_two_ok])!
	a := after_big.conns[0]
	assert a.connect_err == '', a.connect_err
	assert a.raw == want_two_ok, '${backend}: a region queued by a streamed head leaked into the next connection: ${a.raw.bytestr()}'

	rejected := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: bb_concat(bigclose_head, first_chunk)
					want: 0
				},
			]
			then_eof: true
		},
	])!
	r := rejected.conns[0]
	assert r.connect_err == '', r.connect_err
	assert r.eof, '${backend}: a streamed head that returns .close must end the connection'
	assert response.tiny_bad_request_response.bytestr().starts_with(r.raw.bytestr()), '${backend}: a rejected streamed head must answer only 400, got: ${r.raw.bytestr()}'
	bb_assert_handoffs(backend, accepted, 2)

	after_rejected := h.fire([bb_two_ok])!
	b := after_rejected.conns[0]
	assert b.connect_err == '', b.connect_err
	assert b.raw == want_two_ok, '${backend}: a region queued by a rejected streamed head leaked into the next connection: ${b.raw.bytestr()}'
}

// check_queue_file_before_streamed_head: a region queued by a pipelined
// request is still waiting to be sent when the next request of the same burst
// is a body over the streaming threshold (1 MiB), answered from its head
// (start_body_drain). GET /big, then the upload's head and first chunk, go out
// in one write: the worker answers GET /big and fills its read buffer with
// that upload before it reaches EAGAIN and flushes. The region must go out
// before the upload's reply, not be streamed after it. Then the rest of the
// body and GET / on the same connection: GET /big's response with its region,
// then bb_ok_response twice (the upload, GET /), in that order.
fn check_queue_file_before_streamed_head(backend server.IOBackend) ! {
	path, mut f := bb_file_fixture('queue_file_before_streamed')!
	defer {
		f.close()
		os.rm(path) or {}
	}
	accepted := &core.Counter{}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_file_handler(f.fd, accepted)
	})!
	defer {
		h.stop()
	}
	upload_head :=
		'POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ${bb_upload_body_len}\r\n\r\n'.bytes()
	first_chunk := []u8{len: bb_upload_chunk_len, init: u8(0x61)}
	rest := []u8{len: bb_upload_body_len - bb_upload_chunk_len, init: u8(0x61)}
	mut want := []u8{}
	bb_file_head(mut want, bb_file_len, bb_upload_resp_sep)
	want << bb_file_data[bb_file_off..bb_file_off + bb_file_len].bytes()
	want << bb_ok_response
	want << bb_ok_response
	// A byte count, as in check_queue_file_streamed_head: the region sent
	// after the upload's reply adds up to the same count.
	want_len := want.len

	out := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_concat(bb_big_get_req, bb_concat(upload_head, first_chunk))
					want: 0
				},
				vtest.Round{
					send:  bb_concat(rest, bb_req)
					until: fn [want_len] (acc []u8) bool {
						return acc.len >= want_len
					}
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: the pipelined requests around the streamed upload went unanswered'
	assert c.raw == want, '${backend}: a region queued before a streamed upload must go out before the upload reply: ${c.raw.bytestr()}'
	bb_assert_handoffs(backend, accepted, 1)
}

// check_queue_file_refused_in_continuation: nothing takes the slot after a
// watch continuation, so a region one queued would be taken by the next .done
// on that worker, whatever the connection, and streamed after that response.
// queue_file must refuse it there, and the continuation writes the bytes
// itself. GET /parkfile and GET / go out in one write: the parked response
// must carry its region, then exactly bb_ok_response follows. A region left
// queued would give headers, bb_ok_response, then the region: the same byte
// count, so the round ends either way.
fn check_queue_file_refused_in_continuation(backend server.IOBackend) ! {
	path, mut f := bb_file_fixture('queue_file_continuation')!
	defer {
		f.close()
		os.rm(path) or {}
	}
	accepted := &core.Counter{}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_file_handler(f.fd, accepted)
	})!
	defer {
		h.stop()
	}
	mut want := []u8{}
	bb_file_head(mut want, bb_file_len, bb_upload_resp_sep)
	want << bb_file_data[bb_file_off..bb_file_off + bb_file_len].bytes()
	want << bb_ok_response
	want_len := want.len

	out := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  bb_concat(bb_parkfile_req, bb_req)
					until: fn [want_len] (acc []u8) bool {
						return acc.len >= want_len
					}
				},
			]
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert !c.unmet, '${backend}: the parked request or the one pipelined behind it went unanswered'
	assert c.raw == want, '${backend}: a region queued by a continuation went out after the next response: ${c.raw.bytestr()}'
	// Refused whatever the compiler (under tcc the slot is inert anyway).
	got := stdatomic.load_i64(&accepted.n)
	assert got == 0, '${backend}: queue_file accepted ${got} hand-off(s) from a continuation'
}

// check_queue_file_refused_in_conn_handler: nothing takes the slot after a
// ConnHandler either, so a region one queued would go out after the next
// response on that worker, to another client. One worker, so both
// connections below share its slot:
//   1. GET /upgrade hands the connection to bb_file_conn, then a byte gets
//      the region and bb_conn_end: queue_file must refuse the region, so
//      the ConnHandler writes it itself.
//   2. Once step 1 has its answer, GET / twice on a fresh connection:
//      exactly two bb_ok_response. A region left queued by step 1 would
//      follow the first.
fn check_queue_file_refused_in_conn_handler(backend server.IOBackend) ! {
	path, mut f := bb_file_fixture('queue_file_conn_handler')!
	defer {
		f.close()
		os.rm(path) or {}
	}
	accepted := &core.Counter{}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_file_handler(f.fd, accepted)
	})!
	defer {
		h.stop()
	}
	mut want_upgraded := []u8{}
	want_upgraded << bb_switching
	want_upgraded << bb_file_data[bb_file_off..bb_file_off + bb_file_len].bytes()
	want_upgraded << bb_conn_end.bytes()

	upgraded := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  bb_upgrade_req
					until: vtest.count('101 Switching Protocols', 1)
				},
				vtest.Round{
					send:  'x'.bytes()
					until: vtest.count(bb_conn_end, 1)
				},
			]
		},
	])!
	after := h.fire([bb_two_ok])!
	u := upgraded.conns[0]
	a := after.conns[0]
	assert u.connect_err == '', u.connect_err
	assert !u.unmet, '${backend}: the upgrade or the ConnHandler went unanswered: ${u.raw.bytestr()}'
	assert a.connect_err == '', a.connect_err
	assert a.raw == bb_concat(bb_ok_response, bb_ok_response), '${backend}: a region queued by a ConnHandler went out after the response to another connection: ${a.raw.bytestr()}'
	got := stdatomic.load_i64(&accepted.n)
	assert got == 0, '${backend}: queue_file accepted ${got} hand-off(s) from a ConnHandler'
	assert u.raw == want_upgraded, '${backend}: the ConnHandler must write its region itself: ${u.raw.bytestr()}'
}

// check_queue_file_short_read: a queued region the file cannot fill (it
// shrank after the handler sized it) leaves its response short of the
// Content-Length already sent. The worker must close rather than let the next
// response be read as the rest of that body. GET /short and GET / go out in
// one write, so the worker reads the region in with pread to keep the second
// response in order (or, if they arrive apart, sendfile hits EOF): either way
// the client gets the head and the 48 bytes that exist, then EOF, and never
// the second response.
fn check_queue_file_short_read(backend server.IOBackend) ! {
	path, mut f := bb_file_fixture('queue_file_short')!
	defer {
		f.close()
		os.rm(path) or {}
	}
	accepted := &core.Counter{}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_file_handler(f.fd, accepted)
	})!
	defer {
		h.stop()
	}
	mut want_short := []u8{}
	bb_file_head(mut want_short, bb_short_len, bb_upload_resp_sep)
	want_short << bb_file_data[bb_file_off..].bytes()

	// Read until more than that arrives, or EOF: the fixed worker closes (so
	// the round ends unmet, by design), a worker that keeps the connection
	// sends the second response and ends the round instead of hanging it.
	short_len := want_short.len
	short := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  bb_concat(bb_short_req, bb_req)
					until: fn [short_len] (acc []u8) bool {
						return acc.len > short_len
					}
				},
			]
		},
	])!
	s := short.conns[0]
	assert s.connect_err == '', s.connect_err
	assert s.eof, '${backend}: a short file region must end the connection, got: ${s.raw.bytestr()}'
	assert s.raw == want_short, '${backend}: a short file region must end its response, not run into the next one: ${s.raw.bytestr()}'
	bb_assert_handoffs(backend, accepted, 1)

	after := h.fire([bb_two_ok])!
	a := after.conns[0]
	assert a.connect_err == '', a.connect_err
	assert a.raw == bb_concat(bb_ok_response, bb_ok_response), '${backend}: ${a.raw.bytestr()}'
}

const bb_huge_req = 'GET /huge HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
// The region GET /huge hands off: far more than the socket buffers can absorb
// (the tcp_wmem and tcp_rmem maxima are 4 and 6 MiB by default), so the worker
// is still sending it when the client resets. A sparse file: no disk.
const bb_huge_len = 64 * 1024 * 1024
// How much of the answer a resetting client reads first: past the head, so
// the reset lands while the worker streams the file with sendfile(2).
const bb_reset_after = 1024 * 1024
const bb_reset_clients = 32

// bb_huge_handler answers GET /huge with a head promising `length` bytes and
// [0, length) of file_fd handed off with bb_queue_region; anything else with
// bb_ok_response.
fn bb_huge_handler(file_fd int, length i64, accepted &core.Counter) core.Handler {
	return fn [file_fd, length, accepted] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		if bb_target_is(req, '/huge') {
			bb_file_head(mut res, length, bb_upload_resp_sep)
			bb_queue_region(mut res, file_fd, 0, length, accepted)
			return .done
		}
		res << bb_ok_response
		return .done
	}
}

// bb_reset_mid_body sends GET /huge on a new connection, reads bb_reset_after
// bytes of the answer, then resets the connection: SO_LINGER {1, 0} makes
// close() send a RST instead of a FIN. Returns an error if the server ends the
// connection first.
fn bb_reset_mid_body(port int) ! {
	fd := transport.dial_tcp('127.0.0.1', port)!
	socket.set_blocking(fd, true)
	if C.send(fd, bb_huge_req.data, usize(bb_huge_req.len), 0) != bb_huge_req.len {
		transport.close_fd(fd)
		return error('could not send GET /huge')
	}
	mut buf := []u8{len: 64 * 1024}
	mut got := 0
	for got < bb_reset_after {
		n := C.recv(fd, buf.data, usize(buf.len), 0)
		if n <= 0 {
			transport.close_fd(fd)
			return error('the server ended GET /huge after ${got} bytes')
		}
		got += n
	}
	linger := C.linger{
		l_onoff:  1
		l_linger: 0
	}
	C.setsockopt(fd, C.SOL_SOCKET, C.SO_LINGER, &linger, sizeof(linger))
	transport.close_fd(fd)
}

// check_queue_file_peer_reset: a client that resets the connection while the
// worker streams a queued file must not take the server down. sendfile(2) has
// no MSG_NOSIGNAL: when one call sends part of a chunk and then meets the
// reset, it returns the part and the next call fails with EPIPE, which raised
// SIGPIPE, whose default action ends the whole process (exit 141): here, this
// test binary. That depends on where the reset lands, so bb_reset_clients
// clients each read part of a region larger than the socket buffers, then
// reset while the worker is still sending it. One worker, so the resets are
// handled before the next connection, which must then get exactly two
// bb_ok_response. SIGPIPE goes back to its default action before the server
// starts, so that only the server can ignore it, not a disposition inherited
// from the test runner (an ignored signal stays ignored across exec) or left
// by an earlier test.
fn check_queue_file_peer_reset(backend server.IOBackend) ! {
	path := os.join_path(os.temp_dir(), 'vanilla_bb_queue_file_reset_${os.getpid()}.bin')
	os.write_file(path, '')!
	os.truncate(path, u64(bb_huge_len))!
	mut f := os.open(path)!
	defer {
		f.close()
		os.rm(path) or {}
	}
	accepted := &core.Counter{}
	$if !windows {
		C.signal(C.SIGPIPE, C.SIG_DFL)
	}
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		workers:         1
		handler:         bb_huge_handler(f.fd, bb_huge_len, accepted)
	})!
	defer {
		h.stop()
	}
	for _ in 0 .. bb_reset_clients {
		bb_reset_mid_body(h.port())!
	}
	bb_assert_handoffs(backend, accepted, bb_reset_clients)

	after := h.fire([bb_two_ok])!
	a := after.conns[0]
	assert a.connect_err == '', a.connect_err
	assert a.raw == bb_concat(bb_ok_response, bb_ok_response), '${backend}: the server must survive clients that reset mid-file: ${a.raw.bytestr()}'
}

// check_graceful_shutdown (hybrid — lifecycle owned by the test, VTEST.md):
// serve one request, then call server_ref().shutdown(2000) from the test thread. The
// stopwatch MEASURES the idle drain's promptness after it returned (the old
// file's <1000ms assert) — shutdown's precise drain returns the moment the
// in-flight counters hit zero, not after the grace. Every listener is then
// stopped, so 10 fresh connects must all be refused (connect error, or an
// immediate close with no response). The deferred stop() calls shutdown again;
// both are idempotent.
fn check_graceful_shutdown(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         bb_ok_handler
	})!
	defer {
		h.stop()
	}
	first := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: bb_req
				},
			]
		},
	])!
	assert first.conns[0].connect_err == '', first.conns[0].connect_err
	assert first.conns[0].frames.len == 1, '${backend}: server should serve before shutdown'
	assert first.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200')

	sw := time.new_stopwatch()
	h.server_ref().shutdown(2000)
	elapsed := sw.elapsed().milliseconds()
	assert elapsed < 1000, '${backend}: idle shutdown should be prompt, took ${elapsed}ms'

	probes := h.fire(vtest.repeat(10, vtest.Script{
		rounds:   [
			vtest.Round{
				send: bb_req
				want: 0
			},
		]
		then_eof: true
	}))!
	for i, c in probes.conns {
		refused := c.connect_err != '' || (c.eof && c.frames.len == 0)
		assert refused, '${backend}: post-shutdown connect ${i} must be refused, got ${c.frames.len} responses'
	}
}

// --- io_uring ---------------------------------------------------------------
//
// Each io_uring test compiles only on Linux ($if linux — the .io_uring enum
// value is Linux-only) AND self-skips at runtime when io_uring_setup is
// blocked (true of GitHub's hosted runners under seccomp). io_uring allows one
// live ring per process: tests run sequentially and every check fully stops
// its server before returning (drive() does; the start() checks defer stop()).

fn test_iouring_large_upload_drain() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_large_upload_drain(.io_uring)!
	}
}

fn test_iouring_streamed_body_over_max_body_bytes() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_streamed_body_over_max_body_bytes(.io_uring)!
	}
}

fn test_iouring_pipelining_and_framing() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_pipelining_and_framing(.io_uring)!
	}
}

fn test_iouring_max_connections() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_max_connections(.io_uring)!
	}
}

fn test_iouring_read_timeout() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_read_timeout(.io_uring)!
	}
}

fn test_iouring_silent_conn_timeout() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_silent_conn_timeout(.io_uring, server.Limits{
			read_timeout_ms: 400
		})!
		check_silent_conn_timeout(.io_uring, server.Limits{
			idle_timeout_ms: 400
		})!
	}
}

fn test_iouring_idle_keepalive_timeout() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_idle_keepalive_timeout(.io_uring, server.Limits{
			read_timeout_ms: 400
		})!
		check_idle_keepalive_timeout(.io_uring, server.Limits{
			idle_timeout_ms: 400
		})!
	}
}

fn test_iouring_idle_opt_out() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_idle_opt_out(.io_uring)!
	}
}

fn test_iouring_reaped_slots_free_max_connections() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_reaped_slots_free_max_connections(.io_uring)!
	}
}

fn test_iouring_keepalive_under_timeouts() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_keepalive_under_timeouts(.io_uring)!
	}
}

fn test_iouring_first_byte_clears_idle() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_first_byte_clears_idle(.io_uring)!
	}
}

fn test_iouring_graceful_shutdown() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_graceful_shutdown(.io_uring)!
	}
}

fn test_iouring_half_close_after_request() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_half_close_after_request(.io_uring)!
	}
}

// --- iocp (Windows) ---------------------------------------------------------
// The same backend-agnostic checks, against the Windows IOCP backend. On
// Windows `IOBackend` has the single member `iocp` (= 0), so the casts keep
// this file compiling on every OS. (check_expect_100_continue is NOT invoked
// here: the interim-100 prompt is implemented on epoll only so far.)

fn test_iocp_large_upload_drain() ! {
	$if windows {
		check_large_upload_drain(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_streamed_body_over_max_body_bytes() ! {
	$if windows {
		check_streamed_body_over_max_body_bytes(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_pipelining_and_framing() ! {
	$if windows {
		check_pipelining_and_framing(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_max_connections() ! {
	$if windows {
		check_max_connections(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_read_timeout() ! {
	$if windows {
		check_read_timeout(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_silent_conn_timeout() ! {
	$if windows {
		check_silent_conn_timeout(unsafe { server.IOBackend(0) }, server.Limits{
			read_timeout_ms: 400
		})!
		check_silent_conn_timeout(unsafe { server.IOBackend(0) }, server.Limits{
			idle_timeout_ms: 400
		})!
	}
}

fn test_iocp_idle_keepalive_timeout() ! {
	$if windows {
		check_idle_keepalive_timeout(unsafe { server.IOBackend(0) }, server.Limits{
			read_timeout_ms: 400
		})!
		check_idle_keepalive_timeout(unsafe { server.IOBackend(0) }, server.Limits{
			idle_timeout_ms: 400
		})!
	}
}

fn test_iocp_idle_opt_out() ! {
	$if windows {
		check_idle_opt_out(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_reaped_slots_free_max_connections() ! {
	$if windows {
		check_reaped_slots_free_max_connections(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_keepalive_under_timeouts() ! {
	$if windows {
		check_keepalive_under_timeouts(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_first_byte_clears_idle() ! {
	$if windows {
		check_first_byte_clears_idle(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_graceful_shutdown() ! {
	$if windows {
		check_graceful_shutdown(unsafe { server.IOBackend(0) })!
	}
}

fn test_iocp_half_close_after_request() ! {
	$if windows {
		check_half_close_after_request(unsafe { server.IOBackend(0) })!
	}
}

// --- epoll (default backend) ------------------------------------------------

fn test_epoll_large_upload_drain() ! {
	$if linux {
		check_large_upload_drain(.epoll)!
	}
}

fn test_epoll_streamed_body_over_max_body_bytes() ! {
	$if linux {
		check_streamed_body_over_max_body_bytes(.epoll)!
	}
}

fn test_epoll_pipelining_and_framing() ! {
	$if linux {
		check_pipelining_and_framing(.epoll)!
	}
}

fn test_epoll_max_connections() ! {
	$if linux {
		check_max_connections(.epoll)!
	}
}

fn test_epoll_read_timeout() ! {
	$if linux {
		check_read_timeout(.epoll)!
	}
}

fn test_epoll_silent_conn_timeout() ! {
	$if linux {
		check_silent_conn_timeout(.epoll, server.Limits{
			read_timeout_ms: 400
		})!
		check_silent_conn_timeout(.epoll, server.Limits{
			idle_timeout_ms: 400
		})!
	}
}

fn test_epoll_idle_keepalive_timeout() ! {
	$if linux {
		check_idle_keepalive_timeout(.epoll, server.Limits{
			read_timeout_ms: 400
		})!
		check_idle_keepalive_timeout(.epoll, server.Limits{
			idle_timeout_ms: 400
		})!
	}
}

fn test_epoll_idle_opt_out() ! {
	$if linux {
		check_idle_opt_out(.epoll)!
	}
}

fn test_epoll_reaped_slots_free_max_connections() ! {
	$if linux {
		check_reaped_slots_free_max_connections(.epoll)!
	}
}

fn test_epoll_keepalive_under_timeouts() ! {
	$if linux {
		check_keepalive_under_timeouts(.epoll)!
	}
}

fn test_epoll_first_byte_clears_idle() ! {
	$if linux {
		check_first_byte_clears_idle(.epoll)!
	}
}

fn test_epoll_idle_after_parked_write() ! {
	$if linux {
		check_idle_after_parked_write(.epoll)!
	}
}

fn test_epoll_graceful_shutdown() ! {
	$if linux {
		check_graceful_shutdown(.epoll)!
	}
}

fn test_epoll_half_close_after_request() ! {
	$if linux {
		check_half_close_after_request(.epoll)!
	}
}

fn test_epoll_expect_100_continue() ! {
	$if linux {
		check_expect_100_continue(.epoll)!
	}
}

// The plain epoll worker is the backend that consumes core.queue_file.
fn test_epoll_queue_file_cleared_after_close() ! {
	$if linux {
		check_queue_file_cleared_after_close(.epoll)!
	}
}

fn test_epoll_queue_file_streamed_head() ! {
	$if linux {
		check_queue_file_streamed_head(.epoll)!
	}
}

fn test_epoll_queue_file_before_streamed_head() ! {
	$if linux {
		check_queue_file_before_streamed_head(.epoll)!
	}
}

fn test_epoll_queue_file_refused_in_continuation() ! {
	$if linux {
		check_queue_file_refused_in_continuation(.epoll)!
	}
}

// Takeover is inert under tcc (#173): run with gcc, as CI does.
fn test_epoll_queue_file_refused_in_conn_handler() ! {
	$if linux {
		$if tinyc {
			eprintln('[test] takeover is inert under tcc; skipping')
			return
		}
		check_queue_file_refused_in_conn_handler(.epoll)!
	}
}

// Under tcc queue_file is refused and the handler writes the short region
// itself, so nothing on the worker side is exercised (and the keep-alive
// connection would never close): only real compilers run it.
fn test_epoll_queue_file_short_read() ! {
	$if linux && !tinyc {
		check_queue_file_short_read(.epoll)!
	}
}

// Under tcc queue_file is refused and the handler copies the region through
// the write buffer (send with MSG_NOSIGNAL), so sendfile(2) never runs: only
// real compilers run it.
fn test_epoll_queue_file_peer_reset() ! {
	$if linux && !tinyc {
		check_queue_file_peer_reset(.epoll)!
	}
}

// --- poll backend (the pure-POSIX portability floor, issue #122 step 4) ---
// Compiled only under `-d vanilla_poll`, so the SAME behaviour suite
// exercises the RTOS reactor on Linux CI at zero cost to normal builds
// (without the flag these are empty no-ops).

fn test_poll_large_upload_drain() ! {
	$if linux {
		$if vanilla_poll ? {
			check_large_upload_drain(.poll)!
		}
	}
}

fn test_poll_streamed_body_over_max_body_bytes() ! {
	$if linux {
		$if vanilla_poll ? {
			check_streamed_body_over_max_body_bytes(.poll)!
		}
	}
}

fn test_poll_pipelining_and_framing() ! {
	$if linux {
		$if vanilla_poll ? {
			check_pipelining_and_framing(.poll)!
		}
	}
}

fn test_poll_max_connections() ! {
	$if linux {
		$if vanilla_poll ? {
			check_max_connections(.poll)!
		}
	}
}

fn test_poll_read_timeout() ! {
	$if linux {
		$if vanilla_poll ? {
			check_read_timeout(.poll)!
		}
	}
}

fn test_poll_silent_conn_timeout() ! {
	$if linux {
		$if vanilla_poll ? {
			check_silent_conn_timeout(.poll, server.Limits{
				read_timeout_ms: 400
			})!
			check_silent_conn_timeout(.poll, server.Limits{
				idle_timeout_ms: 400
			})!
		}
	}
}

fn test_poll_idle_keepalive_timeout() ! {
	$if linux {
		$if vanilla_poll ? {
			check_idle_keepalive_timeout(.poll, server.Limits{
				read_timeout_ms: 400
			})!
			check_idle_keepalive_timeout(.poll, server.Limits{
				idle_timeout_ms: 400
			})!
		}
	}
}

fn test_poll_idle_opt_out() ! {
	$if linux {
		$if vanilla_poll ? {
			check_idle_opt_out(.poll)!
		}
	}
}

fn test_poll_reaped_slots_free_max_connections() ! {
	$if linux {
		$if vanilla_poll ? {
			check_reaped_slots_free_max_connections(.poll)!
		}
	}
}

fn test_poll_keepalive_under_timeouts() ! {
	$if linux {
		$if vanilla_poll ? {
			check_keepalive_under_timeouts(.poll)!
		}
	}
}

fn test_poll_first_byte_clears_idle() ! {
	$if linux {
		$if vanilla_poll ? {
			check_first_byte_clears_idle(.poll)!
		}
	}
}

fn test_poll_idle_after_parked_write() ! {
	$if linux {
		$if vanilla_poll ? {
			check_idle_after_parked_write(.poll)!
		}
	}
}

fn test_poll_graceful_shutdown() ! {
	$if linux {
		$if vanilla_poll ? {
			check_graceful_shutdown(.poll)!
		}
	}
}

fn test_poll_half_close_after_request() ! {
	$if linux {
		$if vanilla_poll ? {
			check_half_close_after_request(.poll)!
		}
	}
}

fn test_poll_expect_100_continue() ! {
	$if linux {
		$if vanilla_poll ? {
			check_expect_100_continue(.poll)!
		}
	}
}
