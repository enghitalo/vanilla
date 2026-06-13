module http_server

// End-to-end smoke test for the io_uring backend. It guards the rewrite that
// turned the backend from "single request per recv, pipelining broken" into the
// framed, pipelined, batched-send path — and in particular the bug where the
// ring was set up on the main thread but driven on a worker thread, which made
// every io_uring_submit_and_wait fail (the server answered nothing).
//
// io_uring is Linux-only, so the test is a no-op elsewhere.

fn iou_dummy_handler(req []u8, _ int, mut out []u8) ! {
	if req.bytestr().contains('/notfound') {
		out << 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found'.bytes()
		return
	}
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK'.bytes()
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
			request_handler: iou_dummy_handler
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
