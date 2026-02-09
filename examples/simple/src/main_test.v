module main

import http_server.http1_1.response

fn test_simple_without_init_the_server() {
	request1 := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request2 := 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request3 := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	request4 := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

	request2_response := 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'.bytes()

	assert handle_request(request1, -1)! == http_ok_response
	assert handle_request(request2, -1)! == request2_response
	assert handle_request(request3, -1)! == http_created_response
	assert handle_request(request4, -1)! == response.tiny_bad_request_response
}
