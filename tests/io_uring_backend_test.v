// vtest build: linux
// End-to-end smoke tests for the io_uring backend, migrated from
// server/io_uring_backend_test.v onto vtest (docs/VTEST.md). They guard
// the rewrite that turned the backend from "single request per recv,
// pipelining broken" into the framed, pipelined, batched-send path — and in
// particular the bug where the ring was set up on the main thread but driven
// on a worker thread, which made every io_uring_submit_and_wait fail.
//
// io_uring is Linux-only AND requires the io_uring_setup syscall to be
// permitted by the sandbox. GitHub's hosted runners deny it under seccomp, so
// both tests SELF-SKIP via server.iou_backend_available() instead of
// aborting. The backend runs one live ring per process: drive() fully stops
// each server (shutdown drain included) before returning, so the sequential
// tests in this binary never overlap rings. The pure multishot-accept
// kernel-gate test (release-string parsing, no sockets) stays in
// server/io_uring_backend_test.v — it needs module-internal access.
import server
import core
import vtest

const get_root = 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
const get_missing = 'GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

const ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK'.bytes()
const notfound_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found'.bytes()

fn iou_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.bytestr().contains('/notfound') {
		res << notfound_response
		return .done
	}
	res << ok_response
	return .done
}

fn pipeline(req []u8, n int) []u8 {
	mut out := []u8{cap: req.len * n}
	for _ in 0 .. n {
		out << req
	}
	return out
}

// Routing + keep-alive: 200 then 404 on ONE connection. Rounds sequence within
// the connection, so the second request goes out only after the first response
// arrived. Compile-time `$if linux` (the .io_uring enum value exists only
// there) + runtime iou_backend_available() (skip when the syscall is
// sandboxed, e.g. on hosted CI runners).
fn test_io_uring_end_to_end() ! {
	$if !linux {
		eprintln('[test] io_uring backend is Linux-only; skipping')
		return
	}
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		out := vtest.drive(server.ServerConfig{
			io_multiplexing: .io_uring
			handler:         iou_handler
		}, [
			vtest.Script{
				rounds: [
					vtest.Round{
						send: get_root
					},
					vtest.Round{
						send: get_missing
					},
				]
			},
		])!
		assert out.conns[0].connect_err == '', out.conns[0].connect_err
		assert out.conns[0].frames.len == 2
		assert out.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200'), 'GET / not answered 200'
		assert out.conns[0].frames[1].bytestr().starts_with('HTTP/1.1 404'), 'GET /notfound not answered 404'
		assert out.inflight_after == 0
	}
}

// Pipelining: 4 requests in ONE write must yield 4 responses. Guards the
// io_uring batched-send / framed pipelining path (the exact regression the
// file header calls out). kqueue can't do this — hence it lives in the
// io_uring file only.
fn test_io_uring_pipelined() ! {
	$if !linux {
		eprintln('[test] io_uring backend is Linux-only; skipping')
		return
	}
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
			return
		}
		out := vtest.drive(server.ServerConfig{
			io_multiplexing: .io_uring
			handler:         iou_handler
		}, [
			vtest.Script{
				rounds: [vtest.Round{
					send: pipeline(get_root, 4)
					want: 4
				}]
			},
		])!
		assert out.conns[0].connect_err == '', out.conns[0].connect_err
		assert out.conns[0].frames.len == 4, 'pipelined 4 requests expected 4 responses, got ${out.conns[0].frames.len}'
		for f in out.conns[0].frames {
			assert f.bytestr().starts_with('HTTP/1.1 200')
		}
		assert out.inflight_after == 0
	}
}
