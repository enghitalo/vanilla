module main

// JSON + multipart/form-data body handling — reference design.
//
// ASPIRATIONAL PREREQUISITE (lives in the library, not here):
//   `request.read_request` currently stops at the first short read and never
//   consults Content-Length, so any body that spans more than one TCP segment
//   reaches the handler TRUNCATED. The pure fix is in the core: frame the body
//   by Content-Length (or Transfer-Encoding: chunked) BEFORE calling the
//   handler. A request handler should never read the socket itself.
//
//   Everything below assumes that fix — i.e. `req.body` is the COMPLETE body.
//   Then body handling becomes pure data: decode bytes, never touch I/O.
//
// WHY THIS IS THE PURE SHAPE
//   The body is already a zero-copy Slice into the request buffer. JSON and
//   multipart parsing are just views over those bytes. The handler stays a
//   total function of (request) -> (response); no sockets, no globals.
import http_server
import http_server.http1_1.request_parser
import strings
import json

// ----- domain types -------------------------------------------------------

struct CreateUser {
	name  string
	email string
}

struct CreatedUser {
	id    int
	name  string
	email string
}

// ----- response builders (self-contained, no shared helpers) ---------------

fn json_response(status int, reason string, body string) []u8 {
	mut sb := strings.new_builder(96 + body.len)
	sb.write_string('HTTP/1.1 ${status} ${reason}\r\n')
	sb.write_string('Content-Type: application/json\r\n')
	sb.write_string('Content-Length: ${body.len}\r\n')
	sb.write_string('Connection: keep-alive\r\n\r\n')
	sb.write_string(body)
	return sb
}

fn bad_request(msg string) []u8 {
	return json_response(400, 'Bad Request', '{"error":${json.encode(msg)}}')
}

// ----- JSON endpoint: POST /users ------------------------------------------

fn create_user_json(req request_parser.HttpRequest) []u8 {
	body := req.body.to_string(req.buffer)
	input := json.decode(CreateUser, body) or { return bad_request('invalid JSON: ${err}') }
	if input.name == '' || input.email == '' {
		return bad_request('name and email are required')
	}
	created := CreatedUser{
		id:    1
		name:  input.name
		email: input.email
	}
	return json_response(201, 'Created', json.encode(created))
}

// ----- multipart endpoint: POST /upload ------------------------------------

struct Part {
	name     string
	filename string
	content  []u8
}

// extract_attr pulls `key="value"` out of a Content-Disposition line.
fn extract_attr(line string, key string) string {
	needle := '${key}="'
	i := line.index(needle) or { return '' }
	start := i + needle.len
	end := line.index_after('"', start) or { return '' }
	return line[start..end]
}

// parse_multipart splits a multipart/form-data body into its parts.
//
// NOTE: this version materializes the body as a string for readability. For
// large file uploads the pure form scans the raw Slice and returns each part's
// content as a sub-slice (zero copy) — same logic, no allocation per file.
fn parse_multipart(body []u8, boundary string) []Part {
	mut parts := []Part{}
	text := body.bytestr()
	for chunk in text.split(boundary) {
		c := chunk.trim_left('\r\n')
		if c == '' || c.starts_with('--') {
			continue // preamble or closing "--" delimiter
		}
		hb := c.index('\r\n\r\n') or { continue }
		headers := c[..hb]
		mut content := c[hb + 4..]
		if content.ends_with('\r\n') {
			content = content[..content.len - 2] // CRLF before the next boundary
		}
		mut name := ''
		mut filename := ''
		for line in headers.split('\r\n') {
			if line.to_lower().starts_with('content-disposition') {
				name = extract_attr(line, 'name')
				filename = extract_attr(line, 'filename')
			}
		}
		parts << Part{
			name:     name
			filename: filename
			content:  content.bytes()
		}
	}
	return parts
}

fn upload(req request_parser.HttpRequest) []u8 {
	ct_slice := req.get_header_value_slice('Content-Type') or {
		return bad_request('missing Content-Type')
	}
	ct := ct_slice.to_string(req.buffer)
	marker := 'boundary='
	bi := ct.index(marker) or { return bad_request('missing multipart boundary') }
	// Each part is preceded by "--" + boundary.
	boundary := '--' + ct[bi + marker.len..]

	body := req.buffer[req.body.start..req.body.start + req.body.len]
	parts := parse_multipart(body, boundary)
	mut files := []string{}
	for p in parts {
		if p.filename != '' {
			files << '{"field":${json.encode(p.name)},"filename":${json.encode(p.filename)},"size":${p.content.len}}'
		}
	}
	return json_response(200, 'OK', '{"received":[${files.join(',')}]}')
}

// ----- routing -------------------------------------------------------------

fn handle(req_buffer []u8, _ int) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	method := req.method.to_string(req.buffer)
	path := req.path.to_string(req.buffer)

	if method == 'POST' && path == '/users' {
		return create_user_json(req)
	}
	if method == 'POST' && path == '/upload' {
		return upload(req)
	}
	return bad_request('not found')
}

fn main() {
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
		request_handler: handle
	})!
	println('JSON API on http://localhost:3000/  (POST /users, POST /upload)')
	server.run()
}
