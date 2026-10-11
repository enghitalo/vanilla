module main

// Global response decorators — `fn (next) fn` wrappers applied to every response.
// (Access logging lives in access_log.v — it has enough machinery to warrant its
// own file.)
import core

const security_headers = ('X-Content-Type-Options: nosniff\r\n' + 'X-Frame-Options: DENY\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n").bytes()

// with_security_headers injects the hardening headers into every response, once.
// Every input reaches `next` unchanged: the wrapped handler may key on its
// connection (client_fd) or dereference its make_state value (worker_state).
fn with_security_headers(next Handler) Handler {
	return fn [next] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		start := out.len
		step := next(req_buffer, mut out, client_fd, worker_state, mut event_loop)
		if step != .done {
			return step
		}
		insert_after_status_line(mut out, start, security_headers)
		return .done
	}
}

// insert_after_status_line splices `headers` into the response that begins at
// out[start], right after its status line (the first CRLF), in place: append
// to make room, shift the tail right, copy the headers into the gap. No
// allocation once `out` (the connection's reused write buffer) has grown to
// its high-water mark. A response without a CRLF is left untouched.
//
// It never slices `out`: `out[start..]` would mark the buffer as shared, and
// the worker's `out.clear()` would then drop it instead of reusing it.
@[direct_array_access]
fn insert_after_status_line(mut out []u8, start int, headers []u8) {
	if headers.len == 0 {
		return
	}
	mut end := -1
	for i in start .. out.len - 1 {
		if out[i] == `\r` && out[i + 1] == `\n` {
			end = i + 2
			break
		}
	}
	if end < 0 {
		return
	}
	tail := out.len - end
	out << headers // grows `out` by headers.len; those bytes are rewritten below
	unsafe {
		p := &u8(out.data)
		vmemmove(p + end + headers.len, p + end, tail)
		vmemcpy(p + end, headers.data, headers.len)
	}
}
