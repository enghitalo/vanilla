// End-to-end regression for issue #184: request framings that two hops can
// resolve differently are REJECTED by the core framer — one 400, then the
// server closes — on every backend, before the handler ever runs. Before the
// fix, `Transfer-Encoding: gzip` was framed as bodyless, so ONE POST got TWO
// responses (its body was served as a second request: a smuggle);
// differing Content-Lengths were framed by the last value while
// content_length() read the first; and whitespace before the colon hid the
// field, so its body was parsed as the next request.
//
// The checks are backend-agnostic, written once as check_ambiguous_framing
// and invoked per backend (same layout as backend_behaviors_test.v): epoll and
// io_uring on Linux (io_uring self-skips where io_uring_setup is sandboxed),
// poll under `-d vanilla_poll`, iocp on Windows.
import server
import core
import http1_1.request_parser
import http1_1.response
import vtest

const fa_ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
// The handler answers this when the length it reads disagrees with the bytes
// the framer handed it — the in-process half of the #184 disagreement.
const fa_mismatch_response = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 8\r\nConnection: close\r\n\r\nmismatch'.bytes()

const fa_chunked_body = '5\r\nhello\r\n0\r\n\r\n'
const fa_smuggled = 'GET /smuggled HTTP/1.1\r\nHost: localhost\r\n\r\n'

// Each must be answered with exactly one 400 and a close.
const fa_rejected = [
	// Non-chunked Transfer-Encoding, the body a pipelined request: the smuggle.
	'POST /te-gzip HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\n' + fa_smuggled,
	'POST /te-chunked-gzip HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, gzip\r\n\r\n' +
		fa_chunked_body + fa_smuggled,
	'POST /te-xchunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: xchunked\r\n\r\n' +
		fa_chunked_body,
	'POST /te-two-lines HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: gzip\r\n\r\n' +
		fa_chunked_body,
	'POST /te-http10 HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n' + fa_chunked_body,
	// Whitespace before the colon.
	'POST /te-space HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding : chunked\r\n\r\n' +
		fa_chunked_body,
	'POST /cl-tab HTTP/1.1\r\nHost: localhost\r\nContent-Length\t: 5\r\n\r\nhello',
	// Differing Content-Lengths, in both orders.
	'POST /cl-0-then-5 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 5\r\n\r\nhello',
	'POST /cl-5-then-0 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 0\r\n\r\nhello',
]

// Each stays a normal keep-alive request.
const fa_accepted = [
	'POST /te-gzip-chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip, chunked\r\n\r\n' +
		fa_chunked_body,
	'POST /te-chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n' +
		fa_chunked_body,
	'POST /cl-5-twice HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello',
]

// fa_handler is the usual example shape — decode, 400 + close on a decode
// error — and checks that content_length() matches the body the framer framed.
fn fa_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	r := request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	cl := r.content_length()
	if cl >= 0 && cl != r.body.len {
		res << fa_mismatch_response
		return .close
	}
	res << fa_ok_response
	return .done
}

fn check_ambiguous_framing(backend server.IOBackend) ! {
	mut scripts := []vtest.Script{}
	for req in fa_rejected {
		scripts << vtest.Script{
			rounds:   [
				vtest.Round{
					send: req.bytes()
				},
			]
			then_eof: true
		}
	}
	for req in fa_accepted {
		scripts << vtest.Script{
			rounds: [
				vtest.Round{
					send: req.bytes()
				},
			]
		}
	}
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: backend
		handler:         fa_handler
		// Bounds a regression instead of hanging it: a request the server
		// wrongly keeps open is closed by the idle/read sweep, and the
		// asserts below then see the extra or missing response.
		limits:          server.Limits{
			read_timeout_ms: 2000
			idle_timeout_ms: 2000
		}
	}, scripts)!
	for i, req in fa_rejected {
		c := out.conns[i]
		target := req.all_before(' HTTP/')
		assert c.connect_err == '', '${backend} ${target}: ${c.connect_err}'
		// Exactly the 400 and nothing else: neither this request nor the bytes
		// after its head (the smuggled GET) may reach the handler.
		assert c.raw == response.tiny_bad_request_response, '${backend} ${target}: want one 400, got ${c.frames.len} response(s): ${c.raw.bytestr()}'
		assert c.eof, '${backend} ${target}: the server must close after the 400'
	}
	for j, req in fa_accepted {
		c := out.conns[fa_rejected.len + j]
		target := req.all_before(' HTTP/')
		assert c.connect_err == '', '${backend} ${target}: ${c.connect_err}'
		assert c.frames.len == 1, '${backend} ${target}: want one response, got ${c.frames.len}: ${c.raw.bytestr()}'
		assert c.frames[0] == fa_ok_response, '${backend} ${target}: want 200, got ${c.frames[0].bytestr()}'
		assert !c.eof, '${backend} ${target}: a valid request keeps the connection alive'
	}
	assert out.inflight_after == 0
}

fn test_epoll_ambiguous_framing() ! {
	$if linux {
		check_ambiguous_framing(.epoll)!
	}
}

fn test_iouring_ambiguous_framing() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_ambiguous_framing(.io_uring)!
	}
}

fn test_poll_ambiguous_framing() ! {
	$if linux {
		$if vanilla_poll ? {
			check_ambiguous_framing(.poll)!
		}
	}
}

fn test_iocp_ambiguous_framing() ! {
	$if windows {
		check_ambiguous_framing(unsafe { server.IOBackend(0) })!
	}
}
