module main

// Global response decorators — `fn (next) fn` wrappers applied to every response.
// (Access logging lives in access_log.v — it has enough machinery to warrant its
// own file.)

const security_headers = ('X-Content-Type-Options: nosniff\r\n' + 'X-Frame-Options: DENY\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n").bytes()

// with_security_headers injects the hardening headers into every response, once.
fn with_security_headers(next Handler) Handler {
	return fn [next] (req_buffer []u8, fd int) ![]u8 {
		resp := next(req_buffer, fd)!
		return inject_headers(resp, security_headers)
	}
}

// inject_headers inserts `headers` (raw "Name: value\r\n…" bytes) right after the
// status line of an HTTP/1.1 response, in a SINGLE allocation. No string
// round-trip — the naive bytestr()+concat+bytes() does three allocs/response.
fn inject_headers(resp []u8, headers []u8) []u8 {
	end := status_line_end(resp)
	if end < 0 || headers.len == 0 {
		return resp
	}
	mut out := []u8{len: resp.len + headers.len}
	copy(mut out[..end], resp[..end])
	copy(mut out[end..end + headers.len], headers)
	copy(mut out[end + headers.len..], resp[end..])
	return out
}

// status_line_end returns the offset just past the first CRLF (the end of the
// status line), or -1 if there is none.
@[inline]
fn status_line_end(b []u8) int {
	for i in 0 .. b.len - 1 {
		if b[i] == `\r` && b[i + 1] == `\n` {
			return i + 2
		}
	}
	return -1
}
