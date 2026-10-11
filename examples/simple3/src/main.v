module main

import server
import core
import http1_1.response
import http1_1.request_parser
import pool
import db.sqlite
import time

struct App {
pub mut:
	db_pool ?pool.ConnectionPool
}

// The answer to a method or path no route matches. The handler returns
// .done after it, so the connection stays open, as `Connection: keep-alive`
// says.
const http_not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

fn (app App) handle_request(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	// decode_into, not decode_http_request: a malformed request would box an
	// error() per request there.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		out << response.tiny_bad_request_response
		return .close
	}

	method := unsafe { tos(&req_buffer[req.method.start], req.method.len) }
	mut path := unsafe { tos(&req_buffer[req.path.start], req.path.len) }
	// The query is not part of the route: cut the view at the first '?'.
	q := path.index_u8(`?`)
	if q >= 0 {
		path = unsafe { tos(path.str, q) }
	}

	if method == 'GET' {
		if path == '/' {
			app.home_controller(req, mut out)
			return .done
		} else if path.len > 6 && path.starts_with('/user/') { // `/user/` alone has no id: 404
			id := unsafe { tos(path.str + 6, path.len - 6) } // view, no copy
			app.get_user_controller(id, mut out)
			return .done
		}
	} else if method == 'POST' {
		if path == '/user' {
			app.create_user_controller(req, mut out)
			return .done
		}
	}

	core.append_str(mut out, http_not_found_response)
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

	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		handler:         fn [app] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return app.handle_request(req_buffer, mut out, client_fd, worker_state, mut event_loop)
		}
		io_multiplexing: unsafe { server.IOBackend(0) }
	})!

	srv.run()
}
