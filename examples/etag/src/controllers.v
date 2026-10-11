module main

import strconv
import core
import http1_1.request_parser
import hash as wyhash

// The front-end demo is a different origin (file.serve on :4001), so the 304
// needs Access-Control-Allow-Origin too — without it the browser turns the
// 304 into a network error.
const not_modified_response = 'HTTP/1.1 304 Not Modified\r\nAccess-Control-Allow-Origin: *\r\n\r\n'

// `If-None-Match` is not a CORS-safelisted request header, so a cross-origin
// conditional GET is preceded by an OPTIONS preflight.
const preflight_response = 'HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET\r\nAccess-Control-Allow-Headers: If-None-Match\r\nAccess-Control-Max-Age: 86400\r\n\r\n'

const http_ok_response = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n'

const http_created_response = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n'

const hex_digits = '0123456789abcdef'

// ETag = 64-bit wyhash of the content, hex-encoded on the STACK — a cheap,
// strong opaque validator, the same choice as server.static_assets.
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

// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()`. A fixed-size array is zeroed on every
// call (V gotcha), so keep the scratch small: 24 bytes covers any i64.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

fn home_controller(mut out []u8) {
	core.append_str(mut out, http_ok_response)
}

fn get_users_controller(mut out []u8) {
	core.append_str(mut out, http_ok_response)
}

// get_user_controller echoes the id back with its ETag, or answers 304 when
// the client's cached ETag still matches. `id` is a view into the request
// buffer: read here, never retained.
fn get_user_controller(id string, req request_parser.HttpRequest, mut out []u8) {
	// Hash the body bytes straight from the string — a view, no copy.
	etag := etag_hex(unsafe { id.str.vbytes(id.len) })

	// Conditional GET: if the client's cached ETag matches, save the bytes.
	if inm := req.get_header_value_slice('If-None-Match') {
		if etag_matches(req.buffer, inm, etag) {
			core.append_str(mut out, not_modified_response)
			return
		}
	}

	// Frame the response straight into `out` — no `${}`, no `+`, no `.str()`;
	// the hex etag is pushed from the stack array.
	core.append_str(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nETag: "')
	unsafe { out.push_many(&etag[0], 16) }
	core.append_str(mut out, '"\r\nContent-Length: ')
	wi(mut out, id.len)
	// Expose-Headers: cross-origin JS can only read the ETag if it is listed.
	core.append_str(mut out, '\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Expose-Headers: ETag\r\n\r\n')
	core.append_str(mut out, id)
}

fn create_user_controller(mut out []u8) {
	core.append_str(mut out, http_created_response)
}
