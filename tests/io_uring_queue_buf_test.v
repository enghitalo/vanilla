// vtest build: linux
// Coverage for the io_uring queue_buf borrowed-send path: a handler hands a
// preloaded, immutable buffer to the worker (via core.queue_buf) to be sent
// DIRECTLY instead of being copied through the per-connection write buffer.
//
// In its OWN test file (= own test binary): the backend runs one io_uring
// server per process, so this must not share a binary with another io_uring
// server test. Migrated from http_server/io_uring_queue_buf_test.v onto vtest
// (docs/VTEST.md). Compile-time `$if linux` (the .io_uring enum value is
// Linux-only) + runtime server.iou_backend_available() self-skip on
// sandboxed runners.
import server
import core
import vtest

// Preloaded, process-lifetime response: header + 70 000-byte body (> write_buf_cap,
// so the borrowed send drives the partial-send loop). Body is i&0xff so every byte
// can be verified to have survived the direct send intact.
const qb_resp = qb_build_resp()

const qb_body_len = 70000

fn qb_build_resp() []u8 {
	mut b := []u8{}
	b << 'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 70000\r\nConnection: keep-alive\r\n\r\n'.bytes()
	for i in 0 .. qb_body_len {
		b << u8(i & 0xff)
	}
	return b
}

fn iou_qb_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !core.queue_buf(qb_resp.data, qb_resp.len) {
		res << qb_resp // fallback when the backend can't borrow-send
	}
	return .done
}

fn pipeline(req []u8, n int) []u8 {
	mut out := []u8{cap: req.len * n}
	for _ in 0 .. n {
		out << req
	}
	return out
}

// Two /static requests in ONE write on a keep-alive connection, both answered
// from the borrowed buffer, each body > write_buf_cap so the partial-send loop
// runs. vtest's frame counter completes the round when both Content-Length-
// framed responses arrived in full; the byte-exact verification then runs
// against ConnResult.frames.
fn test_io_uring_queue_buf_borrowed_send() ! {
	$if !linux {
		eprintln('[test] io_uring queue_buf test is Linux-only; skipping')
		return
	}
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		out := vtest.drive(server.ServerConfig{
			io_multiplexing: .io_uring
			handler:         iou_qb_handler
		}, [
			vtest.Script{
				rounds: [
					vtest.Round{
						send: pipeline('GET /static/x HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(), 2)
						want: 2
					},
				]
			},
		])!
		assert out.conns[0].connect_err == '', out.conns[0].connect_err
		assert out.conns[0].frames.len == 2, 'expected 2 borrowed-send responses, got ${out.conns[0].frames.len}'
		for n, f in out.conns[0].frames {
			s := f.bytestr()
			assert s.starts_with('HTTP/1.1 200'), 'response ${n}: not a 200'
			he := s.index('\r\n\r\n') or {
				assert false, 'response ${n}: no header terminator'
				return
			}
			body_start := he + 4
			assert f.len == body_start + qb_body_len, 'response ${n}: body truncated: got ${f.len - body_start} of ${qb_body_len} bytes'
			mut good := true
			for i in 0 .. qb_body_len {
				if f[body_start + i] != u8(i & 0xff) {
					good = false
					break
				}
			}
			assert good, 'response ${n}: borrowed-send body bytes corrupted'
		}
		assert out.inflight_after == 0
	}
}
