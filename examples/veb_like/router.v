module main

import http_server.http1_1.request_parser { Slice }

fn router(req_buffer []u8, client_conn_fd int, app App) ![]u8 {
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
