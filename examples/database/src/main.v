module main

import server
import core
import http1.response
import http1.request_parser
import db.pg

fn handle_request(req_buffer []u8, mut out []u8, mut pool ConnectionPool) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	method := unsafe { tos(&req.buffer[req.method.start], req.method.len) }
	path := unsafe { tos(&req.buffer[req.path.start], req.path.len) }

	if method == 'GET' {
		if path == '/' {
			out << home_controller([]) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		} else if path.starts_with('/user/') {
			id := path[6..]
			out << get_user_controller([id], mut pool) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		} else if path == '/user' {
			out << get_users_controller([], mut pool) or {
				out << response.tiny_bad_request_response
				return .close
			}
			return .done
		}
	} else if method == 'POST' {
		if path == '/user' {
			out << create_user_controller([], mut pool) or {
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
	mut pool := new_connection_pool(pg.Config{
		host:     'localhost'
		port:     5435
		user:     'username'
		password: 'password'
		dbname:   'example'
	}, 5) or { panic('Failed to create pg pool: ${err}') }

	db := pool.acquire() or { panic(err) }
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
