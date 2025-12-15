module http_server

import os

fn dummy_handler(req []u8, _ int) ![]u8 {
	if req.bytestr().contains('/notfound') {
		return 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found'.bytes()
	}
	return 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK'.bytes()
}

fn test_server_end_to_end() ! {
	println('[test] Using in-memory request buffers...')
	request1 := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request2 := 'GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	requests := [request1, request2]

	println('[test] Creating server...')
	mut server := new_server(ServerConfig{
		port:            8081
		io_multiplexing: .epoll
		request_handler: dummy_handler
	})
	println('[test] Running server.test...')
	responses := server.test(requests) or {
		eprintln('[test] server.test failed: ${err}')
		return err
	}
	println('[test] Got ${responses.len} responses')
	assert responses.len == 2
	println('[test] Response 1: ' + responses[0].bytestr())
	println('[test] Response 2: ' + responses[1].bytestr())
	assert responses[0].bytestr().contains('200 OK')
	assert responses[1].bytestr().contains('404 Not Found')
	println('[test] test_server_end_to_end passed!')
}
