// Behavioural end-to-end tests for the connection state machine, run against
// EVERY backend: HTTP/1.1 pipelining, request framing across TCP segments,
// max_connections, read timeout, large-body drain, half-close, Expect:
// 100-continue, and graceful shutdown. Migrated from
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
import strconv
import time
import server
import core
import http1_1.request_parser
import http1_1.response
import vtest

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
