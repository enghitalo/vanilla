module http

import strings
import crypto.md5
import time

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

	etag := md5.sum(body_buffer).hex()

	mut sb := strings.new_builder(256)
	// request line
	sb.write(http1_version) or { println(err) }
	sb.write_string(status.str())
	sb.write(' '.bytes()) or { println(err) }
	sb.write(status_text) or { println(err) }
	sb.write('\r\n'.bytes()) or { println(err) }

	// headers
	// TODO: missing HTTP/1.1 obligatory headers
	// like Date, Server, etc.
	// Date
	sb.write('Date: '.bytes()) or { println(err) }
	// time.utc().push_to_http_header(sb) // After https://github.com/vlang/v/pull/26155
	sb.write_string(time.utc().http_header_string())
	sb.write('\r\n'.bytes()) or { println(err) }
	// content type
	sb.write(content_type_header_field) or { println(err) }
	sb.write(content_type_buffer) or { println(err) }
	// etag
	sb.write(etag_header_field) or { println(err) }
	sb.write(etag.bytes()) or { println(err) }
	sb.write('\r\n'.bytes()) or { println(err) }
	// content length
	sb.write(content_length_header_field) or { println(err) }
	sb.write(body_buffer.len.str().bytes()) or { println(err) }
	sb.write('\r\n'.bytes()) or { println(err) }
	// connection
	sb.write(connection_header_field) or { println(err) }
	sb.write('close\r\n\r\n'.bytes()) or { println(err) }
	// body
	sb.write(body_buffer) or { println(err) }

	return sb
}
