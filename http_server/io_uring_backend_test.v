module http_server

// End-to-end smoke test for the io_uring backend. It guards the rewrite that
// turned the backend from "single request per recv, pipelining broken" into the
// framed, pipelined, batched-send path — and in particular the bug where the
// ring was set up on the main thread but driven on a worker thread, which made
// every io_uring_submit_and_wait fail (the server answered nothing).
//
// io_uring is Linux-only AND requires the io_uring_setup syscall to be permitted
// by the sandbox. GitHub's hosted runners deny it under seccomp, so the two
// end-to-end tests here SELF-SKIP via iou_backend_available() instead of aborting.
// Driven over a real client socket via http_server.testkit (replacing the old
// server.test() helper). io_uring DOES pipeline (unlike kqueue), so a pipelined
// test is valid here and guards the batched-send fan-out the file header describes.
//
// The client runs inside after_server_start (see server_test.v for the pattern):
// the hook `spawn`s the client fn — so it returns and the accept loop starts —
// records the thread handle in an IouHarness, and flips the atomic `done` barrier
// that publishes it; the main thread spins on `done`, joins, and asserts.
import time
import sync.stdatomic
import http_server.testkit
import http_server.core

fn iou_dummy_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.bytestr().contains('/notfound') {
		res << 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found'.bytes()
		return .done
	}
	res << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK'.bytes()
	return .done
}

// IouHarness carries the client thread handle from the hook to the main thread;
// `done` is the atomic happens-before barrier that publishes `th`.
struct IouHarness {
mut:
	th   thread []u8
	done u64
}

fn (mut h IouHarness) await() []u8 {
	for stdatomic.load_u64(&h.done) == 0 {
		time.sleep(time.millisecond)
	}
	return h.th.wait()
}

// iou_cli_routing: 200 then 404 on ONE keep-alive connection. "ok" or a diagnostic.
fn iou_cli_routing(port int) []u8 {
	mut c := testkit.dial(port) or { return 'dial: ${err}'.bytes() }
	c.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		return 'write1: ${err}'.bytes()
	}
	if testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 2000) != 1 {
		return 'GET / not answered 200'.bytes()
	}
	c.write('GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {
		return 'write2: ${err}'.bytes()
	}
	if testkit.read_until_count(mut c, 'HTTP/1.1 404', 1, 2000) != 1 {
		return 'GET /notfound not answered 404'.bytes()
	}
	c.close() or {}
	return 'ok'.bytes()
}

// iou_cli_pipelined: 4 requests in ONE write → 4 responses. "ok" or a diagnostic.
fn iou_cli_pipelined(port int) []u8 {
	mut c := testkit.dial(port) or { return 'dial: ${err}'.bytes() }
	req := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'
	c.write(req.repeat(4).bytes()) or { return 'write: ${err}'.bytes() }
	got := testkit.read_until_count(mut c, 'HTTP/1.1 200', 4, 3000)
	c.close() or {}
	if got != 4 {
		return 'pipelined 4 requests expected 4 responses, got ${got}'.bytes()
	}
	return 'ok'.bytes()
}

// Guards the multishot-accept gate: the previous code keyed off a non-existent
// params.features bit (1 << 19), which is never set, so multishot was silently
// disabled on every kernel. Detection now keys off the kernel release.
fn test_iou_release_supports_multishot() {
	$if !linux {
		return
	}
	$if linux {
		// >= 5.19 → supported
		assert iou_release_supports_multishot('5.19.0-generic')
		assert iou_release_supports_multishot('6.8.0-41-generic')
		assert iou_release_supports_multishot('6.0.0')
		assert iou_release_supports_multishot('10.2.1-custom')
		// < 5.19 → single-shot fallback
		assert !iou_release_supports_multishot('5.18.0-generic')
		assert !iou_release_supports_multishot('5.4.0-200-generic')
		assert !iou_release_supports_multishot('4.19.255')
		// Malformed / unparseable → safe default (no multishot)
		assert !iou_release_supports_multishot('garbage')
		assert !iou_release_supports_multishot('6')
		assert !iou_release_supports_multishot('')
	}
}

// Routing + keep-alive: 200 then 404 on ONE connection, each response read fully
// before the next request is sent. Compile-time `$if linux` (the .io_uring enum
// value exists only there) + runtime iou_backend_available() (skip when the
// syscall is sandboxed, e.g. on hosted CI runners).
fn test_io_uring_end_to_end() ! {
	$if !linux {
		eprintln('[test] io_uring backend is Linux-only; skipping')
		return
	}
	$if linux {
		if !iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		mut h := &IouHarness{}
		mut server := new_server(ServerConfig{
			port:               8152
			io_multiplexing:    .io_uring
			handler:            iou_dummy_handler
			after_server_start: fn [mut h] () {
				h.th = spawn iou_cli_routing(8152)
				stdatomic.store_u64(&h.done, 1)
			}
		})!
		spawn fn [mut server] () {
			server.run()
		}()
		got := h.await()
		server.shutdown(500)
		assert got.bytestr() == 'ok', got.bytestr()
	}
}

// Pipelining: 4 requests in ONE write must yield 4 responses. Guards the io_uring
// batched-send / framed pipelining path (the exact regression the file header
// calls out). kqueue can't do this — hence it lives in the io_uring file only.
fn test_io_uring_pipelined() ! {
	$if !linux {
		eprintln('[test] io_uring backend is Linux-only; skipping')
		return
	}
	$if linux {
		if !iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		mut h := &IouHarness{}
		mut server := new_server(ServerConfig{
			port:               8153
			io_multiplexing:    .io_uring
			handler:            iou_dummy_handler
			after_server_start: fn [mut h] () {
				h.th = spawn iou_cli_pipelined(8153)
				stdatomic.store_u64(&h.done, 1)
			}
		})!
		spawn fn [mut server] () {
			server.run()
		}()
		got := h.await()
		server.shutdown(500)
		assert got.bytestr() == 'ok', got.bytestr()
	}
}
