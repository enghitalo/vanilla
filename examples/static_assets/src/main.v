module main

// Serving a CSR/WASM single-page-app bundle — reference design.
//
// A built SPA bundle (HTML + JS + **WASM** + CSS, content-hashed and
// precompressed) is the ideal payload for vanilla: nothing is rendered per
// request, the server just ships immutable bytes. The `static_assets` module
// does the four things a bare file server doesn't (and that are easy to get
// subtly wrong): `application/wasm` MIME, `.br`/`.gz` negotiation, immutable vs
// `no-cache` policy, and SPA fallback. See GitHub issue #19.
//
// THE WHOLE HANDLER IS TWO LINES. Everything below `handle` is just wiring.
import http_server
import http_server.core
import http_server.http1_1.response
import http_server.static_assets
import os

// Built ONCE at boot: read the whole `dist/` bundle, precompute a ready-to-send
// HTTP response for every asset and every precompressed representation. The
// server is immutable afterwards, so the handler shares it across all worker
// threads with no locking and the hot 200 path allocates nothing.
const dist_dir = os.norm_path(os.join_path(os.dir(@FILE), '..', 'dist'))

const assets = static_assets.new(static_assets.Config{
	root: dist_dir
	// defaults: spa_fallback = 'index.html', immutable_glob = '*.[hash].*',
	//           precompressed = [.br, .gz], sendfile_min_bytes = 256 KiB
}) or { panic(err) }

// resolve path -> asset, negotiate Accept-Encoding, set application/wasm +
// immutable Cache-Control, and fall back to index.html for client routes.
// respond_into appends the response to `out`; for a body >= sendfile_min_bytes
// it hands the file to the worker to stream with sendfile(2) — no userspace
// copy — and falls back to copying the bytes on backends that can't (TLS,
// non-Linux). Use respond_into (not respond) to get that fast path.
fn handle(req []u8, mut out []u8, mut worker core.Worker) core.Step {
	assets.respond_into(req, mut out) or {
		out << response.tiny_bad_request_response
		return .close
	}
	return .done
}

fn main() {
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
		handler:         handle
	})!
	println('SPA/WASM server on http://localhost:3000/  (root: ${dist_dir})')
	println('try: curl -v http://localhost:3000/main.7b2e10.wasm           # Content-Type: application/wasm')
	println('     curl -v --compressed http://localhost:3000/app.3f5a9c.js # Content-Encoding: br')
	println('     curl -v http://localhost:3000/any/client/route           # SPA fallback -> index.html')
	server.run()
}
