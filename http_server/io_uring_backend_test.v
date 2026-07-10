module http_server

// End-to-end smoke test for the io_uring backend. It guards the rewrite that
// turned the backend from "single request per recv, pipelining broken" into the
// framed, pipelined, batched-send path — and in particular the bug where the
// ring was set up on the main thread but driven on a worker thread, which made
// every io_uring_submit_and_wait fail (the server answered nothing).
//
// io_uring is Linux-only, so the test is a no-op elsewhere.
import http_server.core

fn iou_dummy_handler(req []u8, mut res []u8, mut worker core.Worker) core.Step {
	if req.bytestr().contains('/notfound') {
		res << 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found'.bytes()
		return .done
	}
	res << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK'.bytes()
	return .done
}

// Guards the multishot-accept gate: the previous code keyed off a non-existent
// params.features bit (1 << 19), which is never set, so multishot was silently
// disabled on every kernel. Detection now keys off the kernel release.
fn test_iou_release_supports_multishot() {
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

fn test_io_uring_end_to_end() ! {
	$if !linux {
		eprintln('[test] io_uring backend is Linux-only; skipping')
		return
	}
	$if linux {
		request1 := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
		request2 := 'GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
		requests := [request1, request2]

		mut server := new_server(ServerConfig{
			port:            8087
			io_multiplexing: .io_uring
			handler:         iou_dummy_handler
		})!

		responses := server.test(requests) or {
			eprintln('[test] io_uring server.test failed: ${err}')
			return err
		}
		assert responses.len == 2
		assert responses[0].bytestr().contains('200 OK')
		assert responses[1].bytestr().contains('404 Not Found')
		println('[test] test_io_uring_end_to_end passed!')
	}
}
