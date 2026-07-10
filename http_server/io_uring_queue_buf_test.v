module http_server

import http_server.core

// Coverage for the io_uring queue_buf borrowed-send path: a handler hands a
// preloaded, immutable buffer to the worker (via core.queue_buf) to be sent
// DIRECTLY instead of being copied through the per-connection write buffer.
//
// In its OWN test file (= own test binary): the backend runs one io_uring server
// per process, so this must not share a binary with another io_uring server test.

// Preloaded, process-lifetime response: header + 70 000-byte body (> write_buf_cap,
// so the borrowed send drives the partial-send loop). Body is i&0xff so every byte
// can be verified to have survived the direct send intact.
const qb_resp = qb_build_resp()

fn qb_build_resp() []u8 {
	mut b := []u8{}
	b << 'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 70000\r\nConnection: keep-alive\r\n\r\n'.bytes()
	for i in 0 .. 70000 {
		b << u8(i & 0xff)
	}
	return b
}

fn iou_qb_handler(req []u8, mut res []u8, mut worker core.Worker) core.Step {
	if !core.queue_buf(qb_resp.data, qb_resp.len) {
		res << qb_resp // fallback when the backend can't borrow-send
	}
	return .done
}

fn test_io_uring_queue_buf_borrowed_send() ! {
	$if !linux {
		eprintln('[test] io_uring queue_buf test is Linux-only; skipping')
		return
	}
	$if linux {
		req := 'GET /static/x HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
		mut server := new_server(ServerConfig{
			port:            8089
			io_multiplexing: .io_uring
			handler:         iou_qb_handler
		})!
		// Two requests on ONE keep-alive connection: both answered from the borrowed
		// buffer (response_buffer never holds the body), each body > write_buf_cap so
		// the partial-send loop runs. Verify every body byte to catch any truncation
		// or offset bug in the direct send.
		responses := server.test([req, req])!
		assert responses.len == 2
		for r in responses {
			s := r.bytestr()
			assert s.contains('200 OK')
			he := s.index('\r\n\r\n') or {
				assert false, 'no header terminator in borrowed-send response'
				0
			}
			body := r[he + 4..]
			assert body.len == 70000, 'borrowed-send body len ${body.len} != 70000'
			mut ok := true
			for i in 0 .. body.len {
				if body[i] != u8(i & 0xff) {
					ok = false
					break
				}
			}
			assert ok, 'borrowed-send body bytes corrupted'
		}
		println('[test] test_io_uring_queue_buf_borrowed_send passed!')
	}
}
