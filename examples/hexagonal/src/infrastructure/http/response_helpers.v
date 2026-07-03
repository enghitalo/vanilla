module http

import strings
import hash as wyhash
import time

const hex_digits = '0123456789abcdef'

// hex16 encodes the 64-bit wyhash as 16 lowercase hex chars on the stack —
// no `.hex()` string, no allocation.
@[direct_array_access]
fn hex16(h u64) [16]u8 {
	mut buf := [16]u8{}
	for i in 0 .. 16 {
		buf[i] = hex_digits[(h >> ((15 - i) * 4)) & 0xF]
	}
	return buf
}

const http_ok = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'.bytes()
const http_created = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n'.bytes()

const http_not_modified = 'HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const http_bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const http_not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const http_server_error = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

const http1_version = 'HTTP/1.1 '.bytes()
const content_type_header_field = 'Content-Type: '.bytes()
const connection_header_field = 'Connection: '.bytes()
const etag_header_field = 'Etag: '.bytes()
const content_length_header_field = 'Content-Length: '.bytes()

pub fn build_basic_response(status int, body_buffer []u8, content_type_buffer []u8) []u8 {
	status_text := match status {
		200 { 'OK'.bytes() }
		201 { 'Created'.bytes() }
		400 { 'Bad Request'.bytes() }
		404 { 'Not Found'.bytes() }
		500 { 'Internal Server Error'.bytes() }
		else { 'OK'.bytes() }
	}

	// ETag = 64-bit wyhash hex-encoded on the stack — a cheap, strong opaque
	// validator (same as http_server.static_assets); a crypto digest here is
	// pure cost, and md5 is broken anyway.
	etag := hex16(wyhash.wyhash_c(body_buffer.data, u64(body_buffer.len), 0))

	mut sb := strings.new_builder(256)
	// request line
	sb.write(http1_version) or { println(err) }
	sb.write_decimal(status)
	sb.write(' '.bytes()) or { println(err) }
	sb.write(status_text) or { println(err) }
	sb.write('\r\n'.bytes()) or { println(err) }

	// headers
	// Date
	sb.write('Date: '.bytes()) or { println(err) }
	time.utc().push_to_http_header(mut sb)
	sb.write('\r\n'.bytes()) or { println(err) }
	// content type
	sb.write(content_type_header_field) or { println(err) }
	sb.write(content_type_buffer) or { println(err) }
	sb.write('\r\n'.bytes()) or { println(err) }
	// etag — DQUOTEd on the wire (RFC 9110 §8.8.3), pushed from the stack
	// scratch (Builder IS []u8)
	sb.write(etag_header_field) or { println(err) }
	sb.write_u8(`"`)
	unsafe { sb.push_many(&etag[0], 16) }
	sb.write_u8(`"`)
	sb.write('\r\n'.bytes()) or { println(err) }
	// content length
	sb.write(content_length_header_field) or { println(err) }
	sb.write_decimal(body_buffer.len)
	sb.write('\r\n'.bytes()) or { println(err) }
	// connection
	sb.write(connection_header_field) or { println(err) }
	sb.write('close\r\n\r\n'.bytes()) or { println(err) }
	// body
	sb.write(body_buffer) or { println(err) }

	return sb
}
