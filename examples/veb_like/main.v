module main

import http_server
import http_server.http1_1.request_parser { Slice }

struct App {
}

fn text_response(body string) []u8 {
	return ('HTTP/1.1 200 OK\r\nContent-Length: ' + body.len.str() +
		'\r\nContent-Type: text/plain\r\n\r\n' + body).bytes()
}

@['GET /users']
fn (app App) list_users(_ request_parser.HttpRequest, params map[string]Slice) []u8 {
	return text_response('')
}

@['POST /users']
fn (app App) create_user(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	return 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{"id": 1}'.bytes()
}

@['GET /users/:id/get']
fn (app App) get_user(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	id := unsafe { params[':id'] }.to_string(req.buffer)
	format := req.get_query('format').to_string(req.buffer)
	pretty := req.get_query('pretty').to_string(req.buffer)

	json_content := '{"id": "' + id + '", "format": "' + format + '", "pretty": "' + pretty + '"}'

	return text_response(json_content)
}

@['GET /users/:id/posts/:post_id']
fn (app App) get_user_post(req request_parser.HttpRequest, params map[string]Slice) []u8 {
	id := unsafe { params[':id'] }.to_string(req.buffer)
	post_id := unsafe { params[':post_id'] }.to_string(req.buffer)

	json_content := '{"id": "' + id + '", "post_id": "' + post_id + '"}'
	return text_response(json_content)
}

fn main() {
	app := App{}
	mut server := http_server.new_server(http_server.ServerConfig{
		request_handler: fn [app] (req_buffer []u8, client_conn_fd int) ![]u8 {
			return router(req_buffer, client_conn_fd, app)
		}
	})!

	server.run()
}
