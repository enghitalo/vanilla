module main

// Global response decorators — `fn (next) fn` wrappers applied to every response.
// (Access logging lives in access_log.v — it has enough machinery to warrant its
// own file.)
import http_server.core

const security_headers = ('X-Content-Type-Options: nosniff\r\n' + 'X-Frame-Options: DENY\r\n' +
	"Content-Security-Policy: default-src 'self'\r\n").bytes()

// with_security_headers injects the hardening headers into every response, once.
fn with_security_headers(next Handler) Handler {
	return fn [next] (req_buffer []u8, mut out []u8, mut ctx core.Ctx) core.Step {
		start := out.len
		step := next(req_buffer, mut out, mut ctx)
		if step != .done {
			return step
		}
		injected := inject_headers(out[start..], security_headers)
		if injected.len == out.len - start {
			return .done
		}
		out.trim(start)
		out << injected
		return .done
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
	// cap form: uninitialized/noscan, no wasted zeroing — we overwrite every byte
	// anyway, and the exact capacity means the three appends never reallocate (§4).
	mut out := []u8{cap: resp.len + headers.len}
	out << resp[..end]
	out << headers
	out << resp[end..]
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
