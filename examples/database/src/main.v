module main

import server
import core
import http1_1.response
import http1_1.request_parser
import db.pg

fn handle_request(req_buffer []u8, mut out []u8, mut pool ConnectionPool) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	// Views into `req_buffer`, not `req.buffer`: a view of `req.buffer` that
	// reaches a callee moves `req` to the heap, a copy on every request.
	method := unsafe { tos(&req_buffer[req.method.start], req.method.len) }
	path := unsafe { tos(&req_buffer[req.path.start], req.path.len) }

	if method == 'GET' {
		if path == '/' {
			home_controller(mut out)
			return .done
		} else if path.starts_with('/user/') {
			// The raw bytes after `/user/` (query string included) are attacker
			// input; get_user_controller answers 400 to anything but a plain
			// integer id (`1/**/OR/**/1=1`, `1;DELETE...`, `abc`) before it
			// touches the database.
			id := unsafe { tos(path.str + 6, path.len - 6) } // view, no copy
			get_user_controller(id, mut pool, mut out)
			return .done
		} else if path == '/user' {
			get_users_controller(mut pool, mut out)
			return .done
		}
	} else if method == 'POST' {
		if path == '/user' {
			create_user_controller(mut pool, mut out)
			return .done
		}
	}

	out << response.tiny_bad_request_response
	return .done
}

fn main() {
	mut pool := new_connection_pool(pg.Config{
		host:     'localhost'
		port:     5435
		user:     'username'
		password: 'password'
		dbname:   'example'
	}, 5) or { panic('Failed to create pg pool: ${err}') }

	mut db := pool.acquire() or { panic(err) }
	db.exec('create table if not exists users (id serial primary key, name text not null)') or {
		panic('Failed to create table users: ${err}')
	}
	pool.release(db)

	// Create and run the server with the handle_request function

	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: unsafe { server.IOBackend(0) }
		handler:         fn [mut pool] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle_request(req_buffer, mut out, mut pool)
		}
	})!

	srv.run()

	pool.close()
}
