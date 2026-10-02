// End-to-end coverage for issue #185: a chunked request with a trailer section
// is answered with the DEFAULT Limits (no read timeout, so the old framer, which
// never framed past a trailer, left it unanswered forever), and a malformed
// chunk-size line is a 400 + close, never framed as the last chunk. Each check
// pipelines a second request behind the first in the same write, so it also
// proves the framer ends the message at the right byte: no desync.
//
// The client is transport.dial_tcp + testkit's deadline-bounded fd_* loops, so
// a server that never answers fails the assert instead of hanging the test.
// Linux-only invocations: the .epoll/.io_uring enum values exist only there
// (io_uring self-skips where io_uring_setup is sandboxed).
import server
import core
import http1_1.request_parser
import http1_1.response
import testkit
import transport
import vtest

const ct_deadline_ms = 3000

const ct_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
const ct_ok_last = 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\nlast'.bytes()

// The pipelined follow-up request; its distinct body marks the end of the run.
const ct_last = 'GET /last HTTP/1.1\r\nHost: localhost\r\n\r\n'

const ct_head = 'POST /a HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n'

// ct_handler answers every parseable request 200; /last gets a distinct body.
fn ct_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	r := request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	if r.path.len == 5 && req[r.path.start + 1] == `l` {
		res << ct_ok_last
	} else {
		res << ct_ok
	}
	return .done
}

// ct_roundtrip writes `raw` in one write on a fresh connection and returns all
// bytes read until `last` appears, the server closes, or the deadline passes.
fn ct_roundtrip(port int, raw string) !string {
	fd := transport.dial_tcp('127.0.0.1', port)!
	defer {
		transport.close_fd(fd)
	}
	if !testkit.fd_write_all(fd, raw.bytes(), ct_deadline_ms) {
		return error('write did not complete')
	}
	return testkit.fd_read_until(fd, 'last', ct_deadline_ms)
}

fn check_chunked_trailer(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         ct_handler
	})!
	defer {
		h.stop()
	}
	// Control: no trailer.
	plain := ct_roundtrip(h.port(), ct_head + '5\r\nhello\r\n0\r\n\r\n' + ct_last)!
	assert plain.count('HTTP/1.1 200 OK') == 2, '${backend}: no-trailer control: ${plain}'
	// One trailer field, then several (RFC 9112 §7.1.2).
	one := ct_roundtrip(h.port(), ct_head + '5\r\nhello\r\n0\r\nX-Checksum: abc\r\n\r\n' + ct_last)!
	assert one.count('HTTP/1.1 200 OK') == 2, '${backend}: trailer request not answered: "${one}"'
	assert one.ends_with('last'), '${backend}: pipelined request after the trailer: "${one}"'
	several := ct_roundtrip(h.port(), ct_head +
		'5;ext=1\r\nhello\r\n0\r\nX-A: 1\r\nX-B: 2\r\nX-C: 3\r\n\r\n' + ct_last)!
	assert several.count('HTTP/1.1 200 OK') == 2, '${backend}: several trailers: "${several}"'
}

fn check_chunked_bad_size_line(backend server.IOBackend) ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: backend
		handler:         ct_handler
	})!
	defer {
		h.stop()
	}
	// The old framer took the empty / extension-only size line as the last
	// chunk and served the pipelined request behind it.
	for body in ['\r\n\r\n', ';ext\r\n\r\n', '5\nhello\r\n0\r\n\r\n', '5\rZZ\nhello\r\n0\r\n\r\n'] {
		got := ct_roundtrip(h.port(), ct_head + body + ct_last)!
		assert got.starts_with('HTTP/1.1 400'), '${backend}: ${body.bytes()} must be a 400, got "${got}"'
		assert !got.contains('last'), '${backend}: ${body.bytes()} must close, not serve the next request'
	}
}

fn test_epoll_chunked_trailer() ! {
	$if linux {
		check_chunked_trailer(.epoll)!
	}
}

fn test_epoll_chunked_bad_size_line() ! {
	$if linux {
		check_chunked_bad_size_line(.epoll)!
	}
}

fn test_iouring_chunked_trailer() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_chunked_trailer(.io_uring)!
	}
}

fn test_iouring_chunked_bad_size_line() ! {
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		check_chunked_bad_size_line(.io_uring)!
	}
}
