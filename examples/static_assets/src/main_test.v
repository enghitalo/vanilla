module main

// Pure handler test — no socket. `handle` is a total function of the request
// bytes, so we feed a raw request and assert the raw response, exactly like the
// rest of vanilla. `assets` is loaded once from `../dist` at program start.
import http_server.core

fn serve(line string) string {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	if handle((line + '\r\n\r\n').bytes(), mut out, -1, unsafe { nil }, mut event_loop) != .done {
		return 'ERR'
	}
	return out.bytestr()
}

fn test_wasm_served_with_application_wasm_and_immutable() {
	r := serve('GET /main.7b2e10.wasm HTTP/1.1')
	assert r.starts_with('HTTP/1.1 200')
	assert r.contains('Content-Type: application/wasm')
	assert r.contains('Cache-Control: public, max-age=31536000, immutable')
}

fn test_index_html_is_no_cache() {
	r := serve('GET / HTTP/1.1')
	assert r.starts_with('HTTP/1.1 200')
	assert r.contains('Content-Type: text/html')
	assert r.contains('Cache-Control: no-cache')
}

fn test_brotli_negotiation() {
	r := serve('GET /app.3f5a9c.js HTTP/1.1\r\nAccept-Encoding: br, gzip')
	assert r.contains('Content-Encoding: br')
	assert r.contains('Vary: Accept-Encoding')
}

fn test_spa_fallback_for_client_route() {
	r := serve('GET /dashboard/settings HTTP/1.1')
	assert r.starts_with('HTTP/1.1 200')
	assert r.contains('Content-Type: text/html')
}

fn test_missing_asset_is_404() {
	r := serve('GET /missing.deadbeef.wasm HTTP/1.1')
	assert r.starts_with('HTTP/1.1 404')
}
