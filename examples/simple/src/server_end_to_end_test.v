module main

import http_server
import response

fn test_server_end_to_end() ! {
	// Prepare requests
	request1 := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request2 := 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request3 := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	request4 := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	requests := [request1, request2, request3, request4]

	mut server := http_server.new_server(http_server.ServerConfig{
		port: 8082
		request_handler: handle_request
		io_multiplexing: .epoll
	})
	responses := server.test(requests) or {
		panic('[test] server.test failed: ${err}')
	}
	assert responses.len == 4
	assert responses[0] == http_ok_response
	assert responses[1] == 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'.bytes()
	assert responses[2] == http_created_response
	assert responses[3] == response.tiny_bad_request_response
	println('[test] test_server_end_to_end passed!')
}
