module main

// veb-like router — a production-minded reference.
//
// Routes are declared as method attributes (`@['GET /users/:id']`) and
// dispatched by a comptime-unrolled router (see router.v). It keeps the project
// values: the handler contract is still bytes-in/bytes-out; a static route
// dispatches with zero allocations; a dynamic match allocates only the params
// map it hands the handler (created only after the match is validated); and
// every response is framed from consts with `out <<` — no `${}` interpolation
// anywhere. There is "no magic" — you can read every step.
//
// Production properties wired here:
//   • never crashes on bad input — a malformed request is answered 400, not
//     panicked (a panic would take down the worker thread);
//   • correct HTTP — 404 vs 405 (+ Allow), accurate Content-Length, and
//     application/json for JSON bodies;
//   • safe output — URL-derived values are JSON-escaped (no injection);
//   • bounded — request size / connection limits and read/write timeouts;
//   • graceful shutdown — SIGTERM/SIGINT drain in-flight work, then exit.
import http_server
import http_server.core
import http_server.http1_1.request_parser { HttpRequest, Slice }
import os

struct App {}

// p reads param `key` as a zero-copy VIEW of its bytes in the request buffer —
// no `.to_string()` copy. The view only feeds json_escape_into, which reads it
// before the buffer is recycled, so nothing needs to outlive the request.
// Route params use the ':' prefix, catch-alls the '*' prefix. A missing or
// empty param yields an empty view (`[]u8{}` at len 0 / cap 0 allocates
// nothing).
fn p(req HttpRequest, params map[string]Slice, key string) []u8 {
	sl := unsafe { params[key] }
	if sl.len <= 0 {
		return []u8{}
	}
	return unsafe { (&req.buffer[sl.start]).vbytes(sl.len) }
}

// ── static routes ──────────────────────────────────────────────────────────
// Static bodies never change, so the full responses are framed ONCE at init
// (Content-Length still computed, never hand-typed); the handlers return the
// const — nothing is built per request.

const users_list_response = json_ok('[]'.bytes())
const user_created_response = json_created('{"id":1}'.bytes())

@['GET /users']
fn (app App) list_users(_ HttpRequest, _ map[string]Slice) []u8 {
	return users_list_response
}

@['POST /users']
fn (app App) create_user(_ HttpRequest, _ map[string]Slice) []u8 {
	return user_created_response
}

// ── one parameter at the end (a REST resource), across several verbs ─────────
// The same path on GET/PUT/PATCH/DELETE shows the router keying on METHOD+path,
// and a wrong verb on it yields 405 with every allowed method in Allow.
// Handler shape for dynamic bodies: JSON skeleton via `ws` consts, params
// escaped straight into the builder, then json_ok() frames it.

@['GET /users/:id']
fn (app App) show_user(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 64}
	ws(mut body, '{"id":')
	json_escape_into(mut body, p(req, params, ':id'))
	ws(mut body, '}')
	return json_ok(body)
}

@['PUT /users/:id']
fn (app App) replace_user(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 64}
	ws(mut body, '{"replaced":')
	json_escape_into(mut body, p(req, params, ':id'))
	ws(mut body, '}')
	return json_ok(body)
}

@['PATCH /users/:id']
fn (app App) update_user(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 64}
	ws(mut body, '{"updated":')
	json_escape_into(mut body, p(req, params, ':id'))
	ws(mut body, '}')
	return json_ok(body)
}

@['DELETE /users/:id']
fn (app App) delete_user(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 64}
	ws(mut body, '{"deleted":')
	json_escape_into(mut body, p(req, params, ':id'))
	ws(mut body, '}')
	return json_ok(body)
}

// ── parameter followed by a literal tail ─────────────────────────────────────

@['GET /users/:id/profile']
fn (app App) user_profile(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 64}
	ws(mut body, '{"id":')
	json_escape_into(mut body, p(req, params, ':id'))
	ws(mut body, ',"section":"profile"}')
	return json_ok(body)
}

// ── two parameters interleaved with literals ─────────────────────────────────

@['GET /users/:user_id/posts/:post_id']
fn (app App) user_post(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 64}
	ws(mut body, '{"user":')
	json_escape_into(mut body, p(req, params, ':user_id'))
	ws(mut body, ',"post":')
	json_escape_into(mut body, p(req, params, ':post_id'))
	ws(mut body, '}')
	return json_ok(body)
}

// ── three parameters, deeply nested ──────────────────────────────────────────

@['GET /users/:user_id/posts/:post_id/comments/:comment_id']
fn (app App) post_comment(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 96}
	ws(mut body, '{"user":')
	json_escape_into(mut body, p(req, params, ':user_id'))
	ws(mut body, ',"post":')
	json_escape_into(mut body, p(req, params, ':post_id'))
	ws(mut body, ',"comment":')
	json_escape_into(mut body, p(req, params, ':comment_id'))
	ws(mut body, '}')
	return json_ok(body)
}

// ── three CONSECUTIVE parameters (no literals between) ───────────────────────

@['GET /tags/:a/:b/:c']
fn (app App) tags(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 64}
	ws(mut body, '{"a":')
	json_escape_into(mut body, p(req, params, ':a'))
	ws(mut body, ',"b":')
	json_escape_into(mut body, p(req, params, ':b'))
	ws(mut body, ',"c":')
	json_escape_into(mut body, p(req, params, ':c'))
	ws(mut body, '}')
	return json_ok(body)
}

// ── a single parameter that often carries odd characters (search query) ──────

@['GET /search/:term']
fn (app App) search(req HttpRequest, params map[string]Slice) []u8 {
	// :term is one segment; richer queries belong in ?q=… (req.get_query).
	mut body := []u8{cap: 64}
	ws(mut body, '{"term":')
	json_escape_into(mut body, p(req, params, ':term'))
	ws(mut body, '}')
	return json_ok(body)
}

// ── catch-all / wildcard: '*path' captures the REST of the path, slashes and
//    all (e.g. /files/css/app.css -> path = "css/app.css"). ──────────────────

@['GET /files/*path']
fn (app App) serve_file(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 96}
	ws(mut body, '{"file":')
	json_escape_into(mut body, p(req, params, '*path'))
	ws(mut body, '}')
	return json_ok(body)
}

@['GET /proxy/*upstream']
fn (app App) proxy(req HttpRequest, params map[string]Slice) []u8 {
	mut body := []u8{cap: 96}
	ws(mut body, '{"upstream":')
	json_escape_into(mut body, p(req, params, '*upstream'))
	ws(mut body, '}')
	return json_ok(body)
}

fn main() {
	app := App{}
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	}
	$if darwin {
		backend = http_server.IOBackend.kqueue
	}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         fn [app] (req_buffer []u8, mut out []u8, mut worker core.Worker) core.Step {
			out << router(req_buffer, worker.client_fd, app) or {
				out << bad_request_response
				return .close
			}
			return .done
		}
		// Production limits: bound resource use so a single client can't exhaust
		// the server. All default to 0 (unlimited) — set explicitly here.
		limits: http_server.Limits{
			max_header_bytes: 16 * 1024   // 16 KiB headers  -> 431
			max_body_bytes:   1024 * 1024 // 1 MiB body     -> 413 (from Content-Length)
			max_connections:  100_000     // refuse past this many concurrent
			read_timeout_ms:  10_000      // finish the request within 10s or 408
			write_timeout_ms: 30_000      // drain a parked response within 30s
		}
	})!

	// Graceful shutdown: SIGTERM/SIGINT (docker stop / k8s / Ctrl-C) stop new
	// accepts and drain in-flight requests before exit, so deploys drop no work.
	os.signal_opt(.term, fn [server] (_ os.Signal) {
		server.shutdown(2000)
		exit(0)
	}) or {}
	os.signal_opt(.int, fn [server] (_ os.Signal) {
		server.shutdown(2000)
		exit(0)
	}) or {}

	println('veb-like (production) on http://localhost:3000/')
	server.run()
}
