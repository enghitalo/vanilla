module request

import http1_1.request_parser

#include <errno.h>

fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int

// read_request reads one complete HTTP/1.1 message from the socket.
//
// Unlike the previous version (which broke on the first short read and so
// truncated any body that didn't arrive in the first segment), this loops
// recv() and asks the PURE framer `frame_request_length` whether a whole
// message is present yet — honoring Content-Length and Transfer-Encoding:
// chunked. It drains until the message is framed or the socket reports EAGAIN.
//
// LIMITATIONS (tracked in CHECKLIST.md #19, issue #154):
//   - No per-fd buffer across readiness events: if a request is fragmented
//     across network round-trips (EAGAIN mid-message), this returns an error
//     instead of resuming on the next read event. Fine for requests that arrive
//     within one readiness burst (the common case, incl. keep-alive and small
//     bodies).
//   - Pipelining: bytes beyond the first message are dropped (framer tells us
//     where the first message ends; we trim to it).
// max_header_bytes / max_body_bytes / max_request_bytes: 0 = unlimited. The
// caller resolves its configured limits (and any default) before the call;
// max_request_bytes is the ceiling on the buffered request (headers+body), the
// backstop that keeps a hostile peer from growing the buffer without bound.
// Over-limit / malformed errors carry an HTTP status in `.code()` (413/431/400);
// connection-level errors carry no code (caller closes quietly).
pub fn read_request(client_fd int, max_header_bytes int, max_body_bytes int, max_request_bytes int) ![]u8 {
	// recv straight into the buffer's spare capacity — no scratch buffer, no
	// double copy.
	//
	// PERF: `[]u8{len: 0, cap: N}` lowers to `__new_array_with_default_noscan`,
	// i.e. GC_MALLOC_ATOMIC — uninitialized (NOT zeroed) and not GC-scanned. So
	// the cost of a bigger cap isn't zeroing; it's GC *allocation pressure*:
	// allocating N bytes per request at ~400k req/s churns the heap and triggers
	// more collections. A controlled A/B measured cap:2048 at ~11% below tiny's
	// throughput vs ~1% at cap:256 — so keep the per-request allocation small.
	// (Note: `grow_cap` re-allocates via the SCAN variant, so requests that
	// outgrow `cap` lose the noscan property — fine, they're off the hot path.)
	// The zero-allocation fix is a reusable per-connection read buffer, as
	// server/backend_poll has (CHECKLIST.md #19, issue #154).
	mut buf := []u8{len: 0, cap: 256}

	for {
		if buf.len == buf.cap {
			unsafe { buf.grow_cap(buf.cap) } // double capacity on demand
		}
		spare := buf.cap - buf.len
		bytes_read := C.recv(client_fd, unsafe { &u8(buf.data) + buf.len }, usize(spare), 0)
		if bytes_read < 0 {
			if C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK {
				if buf.len == 0 {
					return error('no data available')
				}
				return error('incomplete request (would block mid-message)')
			}
			return error('recv failed')
		}
		if bytes_read == 0 {
			if buf.len == 0 {
				return error('client closed connection')
			}
			return error('connection closed mid-request')
		}
		unsafe {
			buf.len += bytes_read
		}
		// Configured body limit (if any) is enforced in the framer from
		// Content-Length before buffering; this is the absolute backstop.
		if max_request_bytes > 0 && buf.len > max_request_bytes {
			return error_with_code('request exceeds ${max_request_bytes} bytes', 413)
		}

		// Propagate the framer's error verbatim so its status code (413/431/400)
		// reaches the caller.
		total := request_parser.frame_request_length_lim(buf, max_header_bytes, max_body_bytes)!
		if total >= 0 {
			// Complete. Drop any trailing (pipelined) bytes beyond this message.
			if buf.len > total {
				buf.trim(total)
			}
			return buf
		}
		// total == -1: message not complete yet; read more.
	}

	return error('unreachable')
}
