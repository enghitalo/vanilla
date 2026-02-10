import http_server
import http_server.http1_1.request_parser { Slice }
import strings

struct App {
}

@['GET /users']
fn (app App) list_users(_ request_parser.HttpRequest, params map[string]Slice) []u8 {
	return 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Type: application/json\r\n\r\n'.bytes()
}

@['POST /users']
fn (app App) create_user(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	return 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{"id": 1}'.bytes()
}

@['GET /users/:id/get']
fn (app App) get_user(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	id_slice := unsafe { params[':id'] }
	format_slice := req.get_query('format=')
	pretty_slice := req.get_query('pretty=')

	id_str := id_slice.to_string(req.buffer)
	format_str := format_slice.to_string(req.buffer)
	pretty_str := pretty_slice.to_string(req.buffer)

	json_content := '{"id": "' + id_str + '", "format": "' + format_str + '", "pretty": "' +
		pretty_str + '"}'

	mut content_sb := strings.new_builder(json_content.len)

	content_sb.write_string('HTTP/1.1 200 OK\r\n')
	content_sb.write_string('Content-Type: application/json\r\n')
	content_sb.write_string('Content-Length: ')
	content_sb.write_string(json_content.len.str())
	content_sb.write_string('\r\n\r\n')
	content_sb.write_string(json_content)

	return content_sb
}

@['GET /users/:id/posts/:post_id']
fn (app App) get_user_post(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	id_slice := unsafe { params[':id'] }
	post_id_slice := unsafe { params[':post_id'] }
	id_str := id_slice.to_string(req.buffer)
	post_id_str := post_id_slice.to_string(req.buffer)
	// content := 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"id": "${id_str}", "post_id": "${post_id_str}"}'.bytes()

	mut content_sb := strings.new_builder(100)

	content_sb.write_string('HTTP/1.1 200 OK\r\n')
	content_sb.write_string('Content-Type: application/json\r\n')
	json_content := '{"id": "' + id_str + '", "post_id": "' + post_id_str + '"}'
	content_sb.write_string('Content-Length: ')
	content_sb.write_string(json_content.len.str())
	content_sb.write_string('\r\n\r\n')
	content_sb.write_string(json_content)
	return content_sb
}

fn main() {
	app := App{}
	mut server := http_server.new_server(http_server.ServerConfig{
		request_handler: fn [app] (req_buffer []u8, client_conn_fd int) ![]u8 {
			return handle_request(req_buffer, client_conn_fd, app)
		}
	})!

	server.run()
}

fn handle_request(req_buffer []u8, client_conn_fd int, app App) ![]u8 {
	parsed_http1_1_request := request_parser.decode_http_request(req_buffer) or { panic(err) }
	mut params := map[string]Slice{}

	$for method in App.methods {
		for attr in method.attrs {
			// Check if slash counts match (quick rejection)
			count_slashes_in_attr := count_char(attr.str, attr.len, `/`)
			count_slashes_in_path := count_char(&parsed_http1_1_request.buffer[parsed_http1_1_request.path.start],
				parsed_http1_1_request.path.len, `/`)
			if count_slashes_in_attr != count_slashes_in_path {
				continue
			}

			// Try static route first
			if try_static_route(parsed_http1_1_request, attr, attr.len) {
				return app.$method(parsed_http1_1_request, params)
			}

			// Try dynamic route
			if try_dynamic_route(parsed_http1_1_request, attr, attr.len, mut params) {
				return app.$method(parsed_http1_1_request, params)
			}
		}
	}
	return 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n'.bytes()
}
