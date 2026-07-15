module main

import strings
import http_server.http1_1.response
import http_server.http1_1.request_parser
import hash as wyhash

const not_modified_response = 'HTTP/1.1 304 Not Modified\r\n\r\n'.bytes()

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n'.bytes()

const http_created_response = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n'.bytes()

const hex_digits = '0123456789abcdef'

// ETag = 64-bit wyhash of the content, hex-encoded on the STACK — a cheap,
// strong opaque validator, the same choice as http_server.static_assets.
// Cache validators need collision resistance for correctness, not
// cryptographic strength: a crypto digest here (md5 previously) is pure
// cost — slower, allocating, and md5 is broken anyway.
@[direct_array_access]
fn etag_hex(content []u8) [16]u8 {
	h := wyhash.wyhash_c(content.data, u64(content.len), 0)
	mut buf := [16]u8{}
	for i in 0 .. 16 {
		buf[i] = hex_digits[(h >> ((15 - i) * 4)) & 0xF]
	}
	return buf
}

// etag_matches compares the If-None-Match value IN PLACE against `"<16 hex>"`
// (18 bytes — entity-tags are DQUOTEd on the wire, RFC 9110 §8.8.3). Exact
// match only: no weak validators, no comma-separated lists.
@[direct_array_access]
fn etag_matches(buf []u8, s request_parser.Slice, etag [16]u8) bool {
	if s.len != 18 || buf[s.start] != `"` || buf[s.start + 17] != `"` {
		return false
	}
	for i in 0 .. 16 {
		if buf[s.start + 1 + i] != etag[i] {
			return false
		}
	}
	return true
}

fn home_controller(_paramsparams []string) ![]u8 {
	return http_ok_response
}

fn get_users_controller(_paramsparams []string) ![]u8 {
	return http_ok_response
}

fn get_user_controller(params []string, req request_parser.HttpRequest) ![]u8 {
	if params.len == 0 {
		return response.tiny_bad_request_response
	}
	id := params[0]
	// Hash the body bytes straight from the string — a view, no copy.
	etag := etag_hex(unsafe { id.str.vbytes(id.len) })

	// Conditional GET: if the client's cached ETag matches, save the bytes.
	if inm := req.get_header_value_slice('If-None-Match') {
		if etag_matches(req.buffer, inm, etag) {
			return not_modified_response
		}
	}

	// Frame the response in ONE builder — no `${}`, no `+`, no `.str()`;
	// the hex etag is pushed from the stack scratch (Builder IS []u8).
	mut sb := strings.new_builder(160 + id.len)
	sb.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nETag: "')
	unsafe { sb.push_many(&etag[0], 16) }
	sb.write_string('"\r\nContent-Length: ')
	sb.write_decimal(id.len)
	sb.write_string('\r\nAccess-Control-Allow-Origin: *\r\n\r\n')
	sb.write_string(id)
	return sb
}

fn create_user_controller(_paramsparams []string) ![]u8 {
	return http_created_response
}
