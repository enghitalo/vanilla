module main

// veb-like router — the production reference for declarative routing.
//
// Routes are declared as method attributes (`@['GET /users/:id']`) and
// compiled once, at startup, by the veb_like module (./veb_like) into a
// segment trie. Per request the router parses, walks the trie and makes one
// direct call: nothing is allocated, for a hit, a 404, a 405 or a 400. The
// handlers keep the full core.Handler contract — they append the response
// into `out` and return a core.Step — so a route can also park on an fd and
// `.suspend` (see /delay/:ms).
//
// Production properties wired here:
//   • never crashes on bad input — a malformed request is answered 400, not
//     panicked (a panic would end the whole server process, all workers);
//   • correct HTTP — 404 vs 405 (+ Allow), HEAD served by GET routes, 501 for
//     unknown methods, accurate Content-Length, application/json bodies;
//   • safe output — URL-derived values are JSON-escaped (no injection);
//   • bounded — request size / connection limits and read/write/idle timeouts;
//   • graceful shutdown — SIGTERM/SIGINT drain in-flight work, then exit.
import server
import core
import http1_1.request_parser { HttpRequest }
import os
import http1_1.veb_like { Params }

struct App {}

// ── static routes ──────────────────────────────────────────────────────────
// Bodies that never change are framed once, at init; the handler appends
// the const.

const users_list_response = fixed_json(json_200_head, '[]')
const user_created_response = fixed_json(json_201_head, '{"id":1}')

@['GET /users']
fn (app &App) list_users(_ HttpRequest, _ &Params, mut out []u8) core.Step {
	core.append_str(mut out, users_list_response)
	return .done
}

@['POST /users']
fn (app &App) create_user(_ HttpRequest, _ &Params, mut out []u8) core.Step {
	core.append_str(mut out, user_created_response)
	return .done
}

// ── one parameter at the end (a REST resource), across several verbs ─────────
// The same path on GET/PUT/PATCH/DELETE: a wrong verb on it is a 405 whose
// Allow header lists them all (plus HEAD, which GET serves).

@['GET /users/:id']
fn (app &App) show_user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	json_field(mut out, '{"id":', p.get('id'), '}')
	return .done
}

@['PUT /users/:id']
fn (app &App) replace_user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	json_field(mut out, '{"replaced":', p.get('id'), '}')
	return .done
}

@['PATCH /users/:id']
fn (app &App) update_user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	json_field(mut out, '{"updated":', p.get('id'), '}')
	return .done
}

@['DELETE /users/:id']
fn (app &App) delete_user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	json_field(mut out, '{"deleted":', p.get('id'), '}')
	return .done
}

// ── parameter followed by a literal tail ─────────────────────────────────────

@['GET /users/:id/profile']
fn (app &App) user_profile(_ HttpRequest, p &Params, mut out []u8) core.Step {
	json_field(mut out, '{"id":', p.get('id'), ',"section":"profile"}')
	return .done
}

// ── two parameters interleaved with literals ─────────────────────────────────
// A param's name belongs to its route: `:user_id` here and `:id` above share
// the same trie node without conflict.

@['GET /users/:user_id/posts/:post_id']
fn (app &App) user_post(_ HttpRequest, p &Params, mut out []u8) core.Step {
	b := begin_json(mut out)
	core.append_str(mut out, '{"user":')
	json_string(mut out, p.get('user_id'))
	core.append_str(mut out, ',"post":')
	json_string(mut out, p.get('post_id'))
	core.append_str(mut out, '}')
	end_json(mut out, b)
	return .done
}

// ── three parameters, deeply nested ──────────────────────────────────────────

@['GET /users/:user_id/posts/:post_id/comments/:comment_id']
fn (app &App) post_comment(_ HttpRequest, p &Params, mut out []u8) core.Step {
	b := begin_json(mut out)
	core.append_str(mut out, '{"user":')
	json_string(mut out, p.get('user_id'))
	core.append_str(mut out, ',"post":')
	json_string(mut out, p.get('post_id'))
	core.append_str(mut out, ',"comment":')
	json_string(mut out, p.get('comment_id'))
	core.append_str(mut out, '}')
	end_json(mut out, b)
	return .done
}

// ── three CONSECUTIVE parameters (no literals between) ───────────────────────

@['GET /tags/:a/:b/:c']
fn (app &App) tags(_ HttpRequest, p &Params, mut out []u8) core.Step {
	b := begin_json(mut out)
	core.append_str(mut out, '{"a":')
	json_string(mut out, p.get('a'))
	core.append_str(mut out, ',"b":')
	json_string(mut out, p.get('b'))
	core.append_str(mut out, ',"c":')
	json_string(mut out, p.get('c'))
	core.append_str(mut out, '}')
	end_json(mut out, b)
	return .done
}

// ── a single parameter that often carries odd characters (search query) ──────

@['GET /search/:term']
fn (app &App) search(_ HttpRequest, p &Params, mut out []u8) core.Step {
	// :term is one segment; richer queries belong in ?q=… (req.get_query).
	json_field(mut out, '{"term":', p.get('term'), '}')
	return .done
}

// ── catch-all / wildcard: '*path' captures the REST of the path, slashes and
//    all (e.g. /files/css/app.css -> path = "css/app.css"). ──────────────────

@['GET /files/*path']
fn (app &App) serve_file(_ HttpRequest, p &Params, mut out []u8) core.Step {
	json_field(mut out, '{"file":', p.get('path'), '}')
	return .done
}

@['GET /proxy/*upstream']
fn (app &App) proxy(_ HttpRequest, p &Params, mut out []u8) core.Step {
	json_field(mut out, '{"upstream":', p.get('upstream'), '}')
	return .done
}

// ── waiting without blocking the worker: the full handler shape ──────────────
// The long shape adds client_fd, worker_state and event_loop. This route parks
// the request on a timer and returns .suspend; the worker serves other
// connections until the timer fires (delay_linux.c.v; elsewhere: 501).

const delay_bad_ms_response = fixed_json(json_400_head, '{"error":"ms must be 0..10000"}')
const not_implemented_response = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'

@['GET /delay/:ms']
fn (app &App) delay(_ HttpRequest, p &Params, mut out []u8, _ int, _ voidptr, mut event_loop core.EventLoop) core.Step {
	ms := parse_ms(p.get('ms')) or {
		core.append_str(mut out, delay_bad_ms_response)
		return .done
	}
	$if linux {
		return start_delay(ms, mut out, mut event_loop)
	} $else {
		core.append_str(mut out, not_implemented_response)
		return .done
	}
}

// parse_ms reads a decimal millisecond count in 0..10000, in place.
fn parse_ms(s string) ?int {
	if s.len == 0 || s.len > 5 {
		return none
	}
	mut n := 0
	for c in s {
		if c < `0` || c > `9` {
			return none
		}
		n = n * 10 + int(c - `0`)
	}
	return if n <= 10_000 { n } else { none }
}

fn main() {
	router := veb_like.new[App](&App{}) or {
		eprintln(err.msg())
		exit(1)
	}
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         fn [router] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return router.handle(req_buffer, mut out, client_fd, worker_state, mut event_loop)
		}
		// Production limits: bound resource use so a single client can't exhaust
		// the server. All default to 0 (unlimited) — set explicitly here. The
		// timeouts are what keep max_connections honest: they reap connections
		// that never send a byte and keep-alive peers that vanished, which would
		// otherwise hold their slots forever.
		limits:          server.Limits{
			max_header_bytes: 16 * 1024   // 16 KiB headers  -> 431
			max_body_bytes:   1024 * 1024 // 1 MiB body     -> 413 (from Content-Length)
			max_connections:  100_000     // refuse past this many concurrent
			read_timeout_ms:  10_000      // finish the request within 10s of accept / its first byte (408 if partial)
			write_timeout_ms: 30_000      // drain a parked response within 30s
			idle_timeout_ms:  75_000      // keep-alive wait for the next request; longer than a load balancer's usual 60s (0 would inherit 10s)
		}
	})!

	// Graceful shutdown: SIGTERM/SIGINT (docker stop / k8s / Ctrl-C) stop new
	// accepts and drain in-flight requests before exit, so deploys drop no work.
	// The handler runs in async-signal context, on whichever thread the kernel
	// interrupts, so it only write(2)s a byte to a pipe; the spawned thread
	// below does the shutdown + exit in normal context.
	wake := os.pipe()!
	on_signal := fn [wake] (_ os.Signal) {
		saved := C.errno
		C.write(wake.write_fd, c'x', 1)
		C.errno = saved
	}
	os.signal_opt(.term, on_signal)!
	os.signal_opt(.int, on_signal)!
	spawn fn [srv, wake] () {
		os.fd_read(wake.read_fd, 1) // blocks until SIGTERM / SIGINT
		srv.shutdown(2000)
		exit(0)
	}()

	println('veb-like (production) on http://localhost:3000/')
	srv.run()
}
