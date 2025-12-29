import http_server
import http_server.http1_1.request_parser { Slice }
import time
import benchmark

struct UserController {
}

@['GET /users']
fn (controller UserController) list_users(_ request_parser.HttpRequest, params map[string]Slice) []u8 {
	return 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Type: application/jso\r\n\r\n'.bytes()
}

@['POST /users']
fn (controller UserController) create_user(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	return 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n\r\n{"id": 1}'.bytes()
}

@['GET /users/:id/get']
fn (controller UserController) get_user(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	id_slice := unsafe { params[':id'] }
	format_slice := req.get_query('format=')
	pretty_slice := req.get_query('pretty=')
	content := 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"id": "${id_slice}", "format": "${format_slice}", "pretty": "${pretty_slice}"}'.bytes()
	return content
}

@['GET /users/:id/posts/:post_id']
fn (controller UserController) get_user_post(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	// id_str := unsafe { string(id.start).substr(0, id.len) }
	id_slice := unsafe { params[':id'] }
	// post_id_str := unsafe { string(post_id.start).substr(0, post_id.len) }
	post_id_slice := unsafe { params[':post_id'] }
	content := 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"id": ${id_slice}, "post_id": ${post_id_slice}}'.bytes()
	return content
}

fn main() {
	// Production test requests
	// http_requests := [
	// 	'GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
	// 	'POST /users HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
	// 	'GET /users/123/get HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
	// 	'GET /users/321/get HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
	// 	'GET /users/456/get?format=json&pretty=true HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
	// 	'GET /users/789/posts/42 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes(),
	// ]!
	user_controller := UserController{}
	// for req_bytes in http_requests {
	// 	parsed_http1_1_request := request_parser.decode_http_request(req_bytes) or { panic(err) }
	// 	params := map[string]Slice{}
	// 	$for method in UserController.methods {
	// 		for attr in method.attrs {
	// 			// Static route
	// 			if attr.len == parsed_http1_1_request.method.len + 1 +
	// 				parsed_http1_1_request.path.len {
	// 				if unsafe {
	// 					C.memcmp(attr.str, &parsed_http1_1_request.buffer[0], attr.len)
	// 				} == 0 {
	// 					println(user_controller.$method(parsed_http1_1_request, params).bytestr())
	// 					println('Static controller: ${method.name}, Attribute: ${attr}')
	// 					break
	// 				}
	// 			} else {
	// 				// Dynamic route
	// 			}
	// 			continue
	// 		}
	// 	}
	// }
	mut server := http_server.new_server(http_server.ServerConfig{
		request_handler: fn [user_controller] (req_buffer []u8, client_conn_fd int) ![]u8 {
			return handle_request(req_buffer, client_conn_fd, user_controller)
		}
	})!

	server.run()
}

fn handle_request(req_buffer []u8, client_conn_fd int, user_controller UserController) ![]u8 {
	parsed_http1_1_request := request_parser.decode_http_request(req_buffer) or { panic(err) }
	mut params := map[string]Slice{}
	$for method in UserController.methods {
		for attr in method.attrs {
			count_slashes_in_attr := count_char(attr.str, attr.len, `/`)
			count_slashes_in_path := count_char(&parsed_http1_1_request.buffer[parsed_http1_1_request.path.start],
				parsed_http1_1_request.path.len, `/`)
			if count_slashes_in_attr != count_slashes_in_path {
				continue
			}
			// Static route
			if attr.len == parsed_http1_1_request.method.len + 1 + parsed_http1_1_request.path.len {
				if unsafe {
					C.memcmp(attr.str, &parsed_http1_1_request.buffer[0], attr.len)
				} == 0 {
					return user_controller.$method(parsed_http1_1_request, params)
				}
			}
			// Dynamic route
			mut colon_pos := find_byte(attr.str, attr.len, `:`) or {
				continue
			}
			if unsafe {
				C.memcmp(attr.str, &parsed_http1_1_request.buffer[0], colon_pos)
			} != 0 {
				continue
			}
			mut remaining_colons := count_char(attr.str + colon_pos, attr.len - colon_pos, `:`)
			// TODO
			continue
		}
	}
	return 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n'.bytes()
}

@[inline]
pub fn count_char(buf &u8, len int, c u8) int {
	mut count := 0
	$if gcc {
		unsafe {
			for i in 0 .. len {
				count += if buf[i] == c { 1 } else { 0 }
			}
		}
		return count
	} $else {
		unsafe {
			mut p := buf
			end := buf + len

			for {
				p = C.memchr(p, c, end - p)
				if isnil(p) {
					break
				}
				count++
				p++ // move past the found '/'
			}
		}
	}

	return count
}

@[inline]
fn find_byte(buf &u8, len int, c u8) !int {
	unsafe {
		p := C.memchr(buf, c, len)
		if p == nil {
			return error('byte not found')
		}
		return int(&u8(p) - buf)
	}
}
