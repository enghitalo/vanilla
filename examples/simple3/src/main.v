module main

import http_server
import http_server.core
import http_server.http1_1.response
import http_server.http1_1.request_parser
import pool
import db.sqlite
import time

struct App {
pub mut:
	db_pool ?pool.ConnectionPool
}

fn (app App) handle_request(req_buffer []u8, mut out []u8, mut worker core.Worker) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }

	if method == 'GET' {
		if path == '/' {
			out << app.home_controller(req) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		} else if path.starts_with('/user/') {
			out << app.get_user_controller(req) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		}
	} else if method == 'POST' {
		if path == '/user' {
			out << app.create_user_controller(req) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		}
	}

	out << response.tiny_bad_request_response
	return .done
}

fn main() {
	pool_factory := fn () !&pool.ConnectionPoolable {
		mut db := sqlite.connect('simple.db')!
		return &db
	}

	db_pool := pool.new_connection_pool(pool_factory, pool.ConnectionPoolConfig{
		max_conns:      5
		min_idle_conns: 1
		max_lifetime:   30 * time.minute
		idle_timeout:   5 * time.minute
		get_timeout:    2 * time.second
	}) or { panic('Failed to create SQLite pool: ' + err.msg()) }

	app := App{
		db_pool: *db_pool
	}

	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		handler:         fn [app] (req_buffer []u8, mut out []u8, mut worker core.Worker) core.Step {
			return app.handle_request(req_buffer, mut out, mut worker)
		}
		io_multiplexing: unsafe { http_server.IOBackend(0) }
	})!

	server.run()
}
