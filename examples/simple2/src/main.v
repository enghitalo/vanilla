module main

// simple2 — two-file routing example: main.v routes, controllers.v responds.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - ROUTE BY OFFSETS: method and path are matched IN PLACE against literals
//     (`slice_eq`) — no per-request `.to_string()` heap copies, no
//     `starts_with` on an allocated string, no `buf[a..b]` slice-marking.
//   - VIEWS, NOT COPIES: the `/user/<id>` id is a zero-copy `vbytes` view into
//     the request buffer. The response is built synchronously inside this call,
//     so the view never outlives the buffer — never retain it past the handler.
//   - Controllers append STRAIGHT INTO the caller-owned `out` buffer; static
//     responses are consts appended with `out <<` (see controllers.v).
import server
import core
import http1.request_parser
import http1.response

// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` (V array slicing marks the source buffer
// on every call; see docs/V_PERF_TOOLBOX.md). In-bounds by construction: the
// parser guarantees the Slice sits inside buf.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if buf[s.start + i] != lit[i] {
			return false
		}
	}
	return true
}

@[direct_array_access]
fn handle_request(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	if slice_eq(req.buffer, req.method, 'GET') {
		if slice_eq(req.buffer, req.path, '/') {
			home_controller(mut out)
			return .done
		}
		if slice_eq(req.buffer, req.path, '/users') {
			get_users_controller(mut out)
			return .done
		}
		// `/user/<id>`: prefix compare in place by offsets. The `>` (not `>=`)
		// guard demands at least one id byte, so `GET /user/` (empty id) is a
		// 400 and the vbytes view below is never zero-length.
		prefix := '/user/'
		if req.path.len > prefix.len {
			mut i := 0
			for i < prefix.len && req.buffer[req.path.start + i] == prefix[i] {
				i++
			}
			if i == prefix.len {
				// Zero-copy view of the id bytes — borrows req.buffer and is
				// consumed by the controller before this call returns.
				id := unsafe { (&req.buffer[req.path.start + prefix.len]).vbytes(req.path.len - prefix.len) }
				get_user_controller(id, mut out)
				return .done
			}
		}
		out << response.tiny_bad_request_response
		return .done
	}
	if slice_eq(req.buffer, req.method, 'POST') {
		if slice_eq(req.buffer, req.path, '/user') {
			create_user_controller(mut out)
			return .done
		}
	}
	out << response.tiny_bad_request_response
	return .done
}

fn main() {
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: unsafe { server.IOBackend(0) }
		handler:         handle_request
	})!
	srv.run()
}
