module main

// veb-like router — a production-minded reference.
//
// Routes are declared as method attributes (`@['GET /users/:id/get']`) and
// dispatched by a comptime-unrolled router (see router.v). It keeps the project
// values: the handler contract is still bytes-in/bytes-out, matching is
// allocation-free on the hot path, and there is "no magic" — you can read every
// step.
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
import http_server.http1_1.request_parser { HttpRequest, Slice }
import os

struct App {}

// p is a tiny helper: read param `key` from the request buffer (zero-copy slice
// -> string). Route params use the ':' prefix, catch-alls the '*' prefix.
fn p(req HttpRequest, params map[string]Slice, key string) string {
	return unsafe { params[key] }.to_string(req.buffer)
}

// ── static routes ──────────────────────────────────────────────────────────

@['GET /users']
fn (app App) list_users(_ HttpRequest, _ map[string]Slice) []u8 {
	return json_response('200 OK', '[]')
}

@['POST /users']
fn (app App) create_user(_ HttpRequest, _ map[string]Slice) []u8 {
	return json_response('201 Created', '{"id":1}')
}

// ── one parameter at the end (a REST resource), across several verbs ─────────
// The same path on GET/PUT/PATCH/DELETE shows the router keying on METHOD+path,
// and a wrong verb on it yields 405 with every allowed method in Allow.

@['GET /users/:id']
fn (app App) show_user(req HttpRequest, params map[string]Slice) []u8 {
	return json_response('200 OK', '{"id":${json_str(p(req, params, ':id'))}}')
}

@['PUT /users/:id']
fn (app App) replace_user(req HttpRequest, params map[string]Slice) []u8 {
	return json_response('200 OK', '{"replaced":${json_str(p(req, params, ':id'))}}')
}

@['PATCH /users/:id']
fn (app App) update_user(req HttpRequest, params map[string]Slice) []u8 {
	return json_response('200 OK', '{"updated":${json_str(p(req, params, ':id'))}}')
}

@['DELETE /users/:id']
fn (app App) delete_user(req HttpRequest, params map[string]Slice) []u8 {
	return json_response('200 OK', '{"deleted":${json_str(p(req, params, ':id'))}}')
}

// ── parameter followed by a literal tail ─────────────────────────────────────

@['GET /users/:id/profile']
fn (app App) user_profile(req HttpRequest, params map[string]Slice) []u8 {
	return json_response('200 OK', '{"id":${json_str(p(req, params, ':id'))},"section":"profile"}')
}

// ── two parameters interleaved with literals ─────────────────────────────────

@['GET /users/:user_id/posts/:post_id']
fn (app App) user_post(req HttpRequest, params map[string]Slice) []u8 {
	body := '{"user":${json_str(p(req, params, ':user_id'))},"post":${json_str(p(req, params,
		':post_id'))}}'
	return json_response('200 OK', body)
}

// ── three parameters, deeply nested ──────────────────────────────────────────

@['GET /users/:user_id/posts/:post_id/comments/:comment_id']
fn (app App) post_comment(req HttpRequest, params map[string]Slice) []u8 {
	body := '{"user":${json_str(p(req, params, ':user_id'))},"post":${json_str(p(req, params,
		':post_id'))},"comment":${json_str(p(req, params, ':comment_id'))}}'
	return json_response('200 OK', body)
}

// ── three CONSECUTIVE parameters (no literals between) ───────────────────────

@['GET /tags/:a/:b/:c']
fn (app App) tags(req HttpRequest, params map[string]Slice) []u8 {
	body := '{"a":${json_str(p(req, params, ':a'))},"b":${json_str(p(req, params, ':b'))},"c":${json_str(p(req,
		params, ':c'))}}'
	return json_response('200 OK', body)
}

// ── a single parameter that often carries odd characters (search query) ──────

@['GET /search/:term']
fn (app App) search(req HttpRequest, params map[string]Slice) []u8 {
	// :term is one segment; richer queries belong in ?q=… (req.get_query).
	return json_response('200 OK', '{"term":${json_str(p(req, params, ':term'))}}')
}

// ── catch-all / wildcard: '*path' captures the REST of the path, slashes and
//    all (e.g. /files/css/app.css -> path = "css/app.css"). ──────────────────

@['GET /files/*path']
fn (app App) serve_file(req HttpRequest, params map[string]Slice) []u8 {
	return json_response('200 OK', '{"file":${json_str(p(req, params, '*path'))}}')
}

@['GET /proxy/*upstream']
fn (app App) proxy(req HttpRequest, params map[string]Slice) []u8 {
	return json_response('200 OK', '{"upstream":${json_str(p(req, params, '*upstream'))}}')
}

fn main() {
	app := App{}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: http_server.IOBackend.epoll
		request_handler: fn [app] (req_buffer []u8, client_conn_fd int) ![]u8 {
			return router(req_buffer, client_conn_fd, app)
		}
		// Production limits: bound resource use so a single client can't exhaust
		// the server. All default to 0 (unlimited) — set explicitly here.
		limits:          http_server.Limits{
			max_header_bytes: 16 * 1024 // 16 KiB headers  -> 431
			max_body_bytes:   1024 * 1024 // 1 MiB body     -> 413 (from Content-Length)
			max_connections:  100_000 // refuse past this many concurrent
			read_timeout_ms:  10_000 // finish the request within 10s or 408
			write_timeout_ms: 30_000 // drain a parked response within 30s
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
