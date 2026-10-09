module main

import strings
import http1_1.request_parser

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

const http_created_response = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()

fn (controller App) home_controller(_ request_parser.HttpRequest) ![]u8 {
	return http_ok_response
}

fn (controller App) get_users_controller(_ request_parser.HttpRequest) ![]u8 {
	return http_ok_response
}

@[direct_array_access; manualfree]
fn (controller App) get_user_controller(req request_parser.HttpRequest) ![]u8 {
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }

	id := path[6..] // assuming path is like "/user/{id}"
	response_body := id

	mut sb := strings.new_builder(200)
	sb.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ')
	sb.write_string(response_body.len.str())
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	sb.write_string(response_body)

	defer {
		unsafe {
			response_body.free()
		}
	}
	return sb
}

fn (controller App) create_user_controller(_ request_parser.HttpRequest) ![]u8 {
	return http_created_response
}
