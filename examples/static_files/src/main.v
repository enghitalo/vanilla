module main

// Static file serving — reference design.
//
// This is deceptively deep: doing it correctly means MIME detection, byte
// Range requests (how video/audio seek works), conditional GET (ETag /
// If-Modified-Since for caching), and — above all — path-traversal safety.
//
// SECURITY FIRST
//   The single most important line in a static server is the one that prevents
//   `GET /../../etc/passwd`. We resolve the requested path against the root and
//   verify the result is still inside the root. Never trust the URL path.
//
// WORKS TODAY: everything here is plain file I/O + header building. The only
// thing the core could improve is zero-copy `sendfile(2)` for large files
// (kernel copies file -> socket without a userspace bounce) and EPOLLOUT-driven
// streaming so a 4 GB file doesn't sit in a single []u8.

import http_server
import http_server.http1_1.request_parser
import os
import strings
import crypto.md5

const web_root = './public'

// Minimal MIME table. A fuller one (or libmagic) covers more types.
fn mime_type(path string) string {
	ext := os.file_ext(path).to_lower()
	return match ext {
		'.html' { 'text/html; charset=utf-8' }
		'.css' { 'text/css' }
		'.js' { 'application/javascript' }
		'.json' { 'application/json' }
		'.png' { 'image/png' }
		'.jpg', '.jpeg' { 'image/jpeg' }
		'.svg' { 'image/svg+xml' }
		'.mp4' { 'video/mp4' }
		'.woff2' { 'font/woff2' }
		else { 'application/octet-stream' }
	}
}

// SECURITY: resolve `url_path` under `web_root` and confirm it cannot escape.
fn safe_path(url_path string) ?string {
	// Strip query string and decode is done upstream; here defend the FS.
	clean := os.norm_path(os.join_path(web_root, url_path.trim_left('/')))
	root_abs := os.abs_path(web_root)
	cand_abs := os.abs_path(clean)
	if !cand_abs.starts_with(root_abs) {
		return none // traversal attempt — refuse
	}
	return cand_abs
}

fn not_found() []u8 {
	return 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'.bytes()
}

// Parse "Range: bytes=START-END" -> (start, end) inclusive, clamped to size.
fn parse_range(range_header string, size i64) ?(i64, i64) {
	if !range_header.starts_with('bytes=') {
		return none
	}
	spec := range_header['bytes='.len..]
	parts := spec.split('-')
	if parts.len != 2 {
		return none
	}
	mut start := i64(0)
	mut end := size - 1
	if parts[0] == '' {
		// suffix range "bytes=-N": the LAST N bytes
		n := parts[1].i64()
		start = if n >= size { i64(0) } else { size - n }
		end = size - 1
	} else {
		start = parts[0].i64()
		end = if parts[1] == '' { size - 1 } else { parts[1].i64() }
	}
	if start < 0 || end >= size || start > end {
		return none
	}
	return start, end
}

fn handle(req_buffer []u8, _ int) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	method := req.method.to_string(req.buffer)
	mut path := req.path.to_string(req.buffer)
	if method != 'GET' && method != 'HEAD' {
		return 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\n\r\n'.bytes()
	}
	// Strip query string for file lookup.
	if qi := path.index('?') {
		path = path[..qi]
	}
	if path == '/' {
		path = '/index.html'
	}

	fs_path := safe_path(path) or { return not_found() }
	if !os.is_file(fs_path) {
		return not_found()
	}

	content := os.read_bytes(fs_path) or { return not_found() }
	ctype := mime_type(fs_path)
	etag := md5.sum(content).hex()

	// Conditional GET: if the client's cached ETag matches, save the bytes.
	if inm := req.get_header_value_slice('If-None-Match') {
		if inm.to_string(req.buffer) == '"${etag}"' {
			return 'HTTP/1.1 304 Not Modified\r\nETag: "${etag}"\r\n\r\n'.bytes()
		}
	}

	// Range request: serve 206 Partial Content (this is how seeking works).
	if rng := req.get_header_value_slice('Range') {
		if start, end := parse_range(rng.to_string(req.buffer), content.len) {
			slice := content[start..end + 1]
			mut sb := strings.new_builder(256 + slice.len)
			sb.write_string('HTTP/1.1 206 Partial Content\r\n')
			sb.write_string('Content-Type: ${ctype}\r\n')
			sb.write_string('Content-Range: bytes ${start}-${end}/${content.len}\r\n')
			sb.write_string('Accept-Ranges: bytes\r\n')
			sb.write_string('Content-Length: ${slice.len}\r\n')
			sb.write_string('ETag: "${etag}"\r\n\r\n')
			if method == 'GET' {
				sb.write(slice) or {}
			}
			return sb
		}
	}

	mut sb := strings.new_builder(256 + content.len)
	sb.write_string('HTTP/1.1 200 OK\r\n')
	sb.write_string('Content-Type: ${ctype}\r\n')
	sb.write_string('Content-Length: ${content.len}\r\n')
	sb.write_string('Accept-Ranges: bytes\r\n') // advertise range support
	sb.write_string('ETag: "${etag}"\r\n')
	sb.write_string('Cache-Control: public, max-age=3600\r\n')
	sb.write_string('Connection: keep-alive\r\n\r\n')
	if method == 'GET' {
		sb.write(content) or {}
	}
	return sb
}

fn main() {
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: http_server.IOBackend.epoll
		request_handler: handle
	})!
	println('Static server on http://localhost:3000/  (root: ${web_root})')
	println('PURE UPGRADE: serve large files via sendfile(2) + EPOLLOUT instead of read_bytes into RAM.')
	server.run()
}
