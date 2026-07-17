module main

import core
import http1_1.response

fn test_simple_without_init_the_server() {
	request1 := 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request2 := 'GET /user/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	request3 := 'POST /user HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n'.bytes()
	request4 := 'INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

	request2_response :=
		'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n123'.bytes()

	assert serve(request1) == http_ok_response
	assert serve(request2) == request2_response
	assert serve(request3) == http_created_response
	assert serve(request4) == response.tiny_bad_request_response
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	handle_request(req, mut out, -1, unsafe { nil }, mut event_loop)
	return out
}
