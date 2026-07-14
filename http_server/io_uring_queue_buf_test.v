module http_server

import time
import sync.stdatomic
import http_server.testkit
import http_server.core

// Coverage for the io_uring queue_buf borrowed-send path: a handler hands a
// preloaded, immutable buffer to the worker (via core.queue_buf) to be sent
// DIRECTLY instead of being copied through the per-connection write buffer.
//
// In its OWN test file (= own test binary): the backend runs one io_uring server
// per process, so this must not share a binary with another io_uring server test.
// Driven over a real client socket via http_server.testkit (replacing the old
// server.test() helper). Compile-time `$if linux` (the .io_uring enum value is
// Linux-only) + runtime iou_backend_available() self-skip on sandboxed runners.
// The client runs inside after_server_start (spawned so the accept loop can start),
// its bytes published to the main thread via the atomic `done` barrier.

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

fn iou_qb_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !core.queue_buf(qb_resp.data, qb_resp.len) {
		res << qb_resp // fallback when the backend can't borrow-send
	}
	return .done
}

// QbHarness carries the client thread's accumulated bytes to the main thread;
// `done` is the atomic happens-before barrier that publishes `th`.
struct QbHarness {
mut:
	th   thread []u8
	done u64
}

fn (mut h QbHarness) await() []u8 {
	for stdatomic.load_u64(&h.done) == 0 {
		time.sleep(time.millisecond)
	}
	return h.th.wait()
}

// qb_cli sends two /static requests in ONE write on a keep-alive connection (both
// answered from the borrowed buffer, each body > write_buf_cap so the partial-send
// loop runs) and returns ALL bytes read. Header is 106 bytes; body 70000 ⇒ one
// response = 70106, two = 140212. read_full's generous deadline is fine — the
// io_uring partial-send loop guarantees eventual full delivery. The byte-exact
// verification happens on the main thread (below).
fn qb_cli(port int) []u8 {
	req := 'GET /static/x HTTP/1.1\r\nHost: localhost\r\n\r\n'
	mut c := testkit.dial(port) or { return 'dial: ${err}'.bytes() }
	c.write(req.repeat(2).bytes()) or { return 'write: ${err}'.bytes() }
	acc := testkit.read_full(mut c, 140212, 5000)
	c.close() or {}
	return acc
}

fn test_io_uring_queue_buf_borrowed_send() ! {
	$if !linux {
		eprintln('[test] io_uring queue_buf test is Linux-only; skipping')
		return
	}
	$if linux {
		if !iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		mut h := &QbHarness{}
		mut server := new_server(ServerConfig{
			port:               8154
			io_multiplexing:    .io_uring
			handler:            iou_qb_handler
			after_server_start: fn [mut h] () {
				h.th = spawn qb_cli(8154)
				stdatomic.store_u64(&h.done, 1)
			}
		})!
		spawn fn [mut server] () {
			server.run()
		}()
		acc := h.await()
		server.shutdown(500)

		assert testkit.count_marker(acc, 'HTTP/1.1 200') == 2, 'expected 2 borrowed-send responses, got ${testkit.count_marker(acc,
			'HTTP/1.1 200')}'

		assert acc.len >= 140212, 'short read: got ${acc.len} of 140212 bytes'

		s := acc.bytestr()
		mut off := 0
		for n in 0 .. 2 {
			he := s.index_after('\r\n\r\n', off) or {
				assert false, 'response ${n}: no header terminator'
				return
			}
			body_start := he + 4
			assert body_start + 70000 <= acc.len, 'response ${n}: body truncated'
			mut good := true
			for i in 0 .. 70000 {
				if acc[body_start + i] != u8(i & 0xff) {
					good = false
					break
				}
			}
			assert good, 'response ${n}: borrowed-send body bytes corrupted'
			off = body_start + 70000
		}
		println('[test] test_io_uring_queue_buf_borrowed_send passed!')
	}
}
