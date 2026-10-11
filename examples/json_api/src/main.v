module main

// JSON + multipart/form-data body handling — reference design.
//
// PREREQUISITE (lives in the library, not here):
//   `request.read_request` frames the body BEFORE the handler runs: it loops
//   recv() and asks the pure framer (`request_parser.frame_request_length`)
//   whether a complete message is present yet — honoring Content-Length and
//   Transfer-Encoding: chunked. `req.body` is therefore the COMPLETE body.
//   Residual core limitation: a request fragmented across epoll readiness
//   bursts (EAGAIN mid-message) is rejected with an error — never delivered
//   truncated. A handler must never read the socket itself.
//
// WHY THIS IS THE PURE SHAPE
//   The body is already a zero-copy Slice into the request buffer. JSON and
//   multipart parsing are just views over those bytes. The handler stays a
//   total function of (request) -> (response); no sockets, no globals.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - Routing compares method/path bytes IN PLACE by offsets (slice_eq) — no
//     `.to_string()` on the hot path.
//   - Static responses are const strings appended with core.append_str.
//     Dynamic bodies are encoded straight into `out` (json2.encode_append),
//     then frame_body puts the head with the exact Content-Length in front of
//     them, in place — no `${}`, no `+`, no body string, no builder.
//   - The JSON body reaches json2 as a `tos` VIEW of the request buffer: json2
//     is length-bounded and copies every string it decodes, so nothing it
//     returns points into the buffer. Its token array is reused per worker
//     (decode_reuse + make_state), not allocated per request.
//   - Multipart parts are VIEWS into the request buffer (tos/vbytes), walked
//     one at a time by PartIter: no array of parts per request, and CRLF is
//     matched as numeric bytes (13/10). The views must not outlive the request
//     buffer — safe here because the response is built synchronously in the
//     same call.
//   - What still allocates on /users is json2's own: every decode (the
//     strings it returns are owned copies, by design, plus a little
//     bookkeeping) and its formatting of the `id` number.
import server
import core
import http1_1.request_parser
import http1_1.response
import json2
import strconv

// ----- domain types ---------------------------------------------------------

struct CreateUser {
	name  string
	email string
}

struct CreatedUser {
	id    int
	name  string
	email string
}

// ----- static responses (const strings, appended with core.append_str) -------
// Each Content-Length is its body's length; test_static_responses_are_framed
// checks every one, so keep them in sync when a body changes.

// 404 is the honest status for an unmatched route (this used to be a 400).
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 21\r\nConnection: keep-alive\r\n\r\n{"error":"not found"}'
// Decode error detail stays server-side (BEST_PRACTICES §8) — clients get a
// generic, fully static 400.
const resp_400_invalid_json = 'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 24\r\nConnection: keep-alive\r\n\r\n{"error":"invalid JSON"}'
const resp_400_missing_fields = 'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 39\r\nConnection: keep-alive\r\n\r\n{"error":"name and email are required"}'
const resp_400_no_content_type = 'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 32\r\nConnection: keep-alive\r\n\r\n{"error":"missing Content-Type"}'
const resp_400_no_boundary = 'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 38\r\nConnection: keep-alive\r\n\r\n{"error":"missing multipart boundary"}'

// Heads of the dynamic responses: frame_body writes `head`, the body's length,
// then `head_tail` in front of the body.
const head_201 = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: '
const head_200 = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '
const head_tail = '\r\nConnection: keep-alive\r\n\r\n'

const cr = u8(13) // numeric, never `\r` in byte comparisons (V rune-literal footgun)
const lf = u8(10)

// ----- per-worker state ---------------------------------------------------------

// State is one worker's reusable decode storage: make_state runs once per
// worker thread, so no lock. json2.decode_reuse keeps its token array here
// between requests instead of allocating and freeing one per request.
struct State {
mut:
	decode json2.DecodeBuffer
}

fn make_state() voidptr {
	return &State{}
}

// ----- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------

// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()`.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// frame_body puts `head`, the body's decimal length and `tail` in front of the
// body the caller appended at out[mark..], in place: the body is already
// written, so the Content-Length is exact. Grow `out` by the head's size,
// shift the body right, copy the head into the gap (the in-place splice of
// examples/security_headers). No padded length, no scratch buffer, and no
// allocation once `out` has reached its high-water mark. Never slice `out`:
// that would make the server drop its write buffer.
fn frame_body(mut out []u8, mark int, head string, tail string) {
	body_len := out.len - mark
	mut digits := [24]u8{}
	mut view := unsafe { (&digits[0]).vbytes(digits.len) }
	n := strconv.write_dec(i64(body_len), mut view)
	gap := head.len + n + tail.len
	unsafe {
		out.grow_len(gap)
		p := &u8(out.data) + mark
		vmemmove(p + gap, p, body_len)
		vmemcpy(p, head.str, head.len)
		vmemcpy(p + head.len, &digits[0], n)
		vmemcpy(p + head.len + n, tail.str, tail.len)
	}
}

// ----- JSON endpoint: POST /users ---------------------------------------------

// decode_user decodes the body with the worker's reusable token storage, or
// with a one-off decode when the handler runs without make_state (the unit
// tests call handle() with a nil worker_state).
fn decode_user(body string, worker_state voidptr) !CreateUser {
	if worker_state == unsafe { nil } {
		return json2.decode[CreateUser](body)
	}
	mut st := unsafe { &State(worker_state) }
	return json2.decode_reuse[CreateUser](body, mut st.decode)
}

fn create_user_json(req request_parser.HttpRequest, mut out []u8, worker_state voidptr) {
	// A `tos` VIEW of the body: json2 reads only the view's length and copies
	// every string it decodes, so the view does not outlive this call. Taken
	// from a local copy of the buffer header, not `&req.buffer[...]`: a view of
	// a field of `req` that flows into a `!` call makes V move `req` to the
	// heap on every request.
	buf := req.buffer
	body := if req.body.len > 0 { unsafe { tos(&buf[req.body.start], req.body.len) } } else { '' }
	input := decode_user(body, worker_state) or {
		core.append_str(mut out, resp_400_invalid_json)
		return
	}
	if input.name == '' || input.email == '' {
		core.append_str(mut out, resp_400_missing_fields)
		return
	}
	created := CreatedUser{
		id:    1
		name:  input.name
		email: input.email
	}
	// json2 escapes the user-controlled strings (§8 — never reflect raw input)
	// and encodes straight into `out`; frame_body then puts the head in front.
	mark := out.len
	json2.encode_append(created, mut out, escape_unicode: true)
	frame_body(mut out, mark, head_201, head_tail)
}

// ----- multipart endpoint: POST /upload ---------------------------------------
//
// Zero copy: the body is scanned by OFFSETS and every Part field is a view into
// the request buffer (`tos` for the attribute strings, `vbytes` for content).
// PartIter yields the parts one at a time, so no array of parts is built. The
// views MUST NOT outlive req.buffer — here the summary response is built
// synchronously in the same handler call, so nothing retains them.

struct Part {
	name     string // view into the request buffer — do not retain past the request
	filename string // view; '' when the part has no filename attribute
	content  []u8   // view
}

// match_at reports whether needle's bytes appear verbatim at buf[at..].
@[direct_array_access; inline]
fn match_at(buf []u8, at int, needle []u8) bool {
	if at < 0 || at + needle.len > buf.len {
		return false
	}
	for i in 0 .. needle.len {
		if buf[at + i] != needle[i] {
			return false
		}
	}
	return true
}

// next_delim returns the offset of the next `--` + boundary at or after `from`,
// or -1. Two-phase compare — the two dashes, then the boundary bytes — so the
// delimiter is never materialized ('--' + boundary would be two allocations
// per request).
@[direct_array_access]
fn next_delim(body []u8, from int, boundary []u8) int {
	last := body.len - (2 + boundary.len)
	for i in from .. last + 1 {
		if body[i] == `-` && body[i + 1] == `-` && match_at(body, i + 2, boundary) {
			return i
		}
	}
	return -1
}

// starts_with_ci: case-insensitive prefix compare of buf[ls..le) against a
// lowercase needle. The fold is letters-only (same discipline as the core's
// ascii_ci_eq): a bare `| 0x20` would let `-` in the needle also match CR.
@[direct_array_access]
fn starts_with_ci(buf []u8, ls int, le int, needle string) bool {
	if le - ls < needle.len {
		return false
	}
	for i in 0 .. needle.len {
		x := buf[ls + i] ^ needle[i]
		if x == 0 {
			continue
		}
		// The only acceptable difference is the ASCII case bit on a letter.
		if x != 0x20 {
			return false
		}
		c := buf[ls + i] | 0x20
		if c < `a` || c > `z` {
			return false
		}
	}
	return true
}

// attr_range returns (start, len) of the value of `key` + value + `"` on the
// header line buf[ls..le), or (-1, 0). `key` must end with `="` (e.g.
// 'name="'). Whole-attribute match: the byte before the key must be a
// delimiter, so `name="` can never match the tail of `filename="`.
@[direct_array_access]
fn attr_range(buf []u8, ls int, le int, key string) (int, int) {
	if le - ls < key.len {
		return -1, 0
	}
	for i in ls .. le - key.len + 1 {
		mut j := 0
		for j < key.len && buf[i + j] == key[j] {
			j++
		}
		if j < key.len {
			continue
		}
		if i > ls && buf[i - 1] !in [u8(` `), `;`, 9] {
			continue
		}
		vs := i + key.len
		mut ve := vs
		for ve < le && buf[ve] != `"` {
			ve++
		}
		if ve >= le {
			return -1, 0 // unterminated quote
		}
		return vs, ve - vs
	}
	return -1, 0
}

// scan_part parses ONE part between two delimiters: header lines, a blank line
// (CRLFCRLF), then content. Returns none when the separator is missing.
@[direct_array_access]
fn scan_part(body []u8, start int, end int) ?Part {
	mut hb := -1
	for i in start .. end - 3 {
		if body[i] == cr && body[i + 1] == lf && body[i + 2] == cr && body[i + 3] == lf {
			hb = i
			break
		}
	}
	if hb < 0 {
		return none
	}
	mut name_s := -1
	mut name_l := 0
	mut file_s := -1
	mut file_l := 0
	mut ls := start
	for ls < hb {
		mut le := ls
		for le < hb && body[le] != cr {
			le++
		}
		// [ls, le) is one header line.
		if starts_with_ci(body, ls, le, 'content-disposition') {
			name_s, name_l = attr_range(body, ls, le, 'name="')
			file_s, file_l = attr_range(body, ls, le, 'filename="')
		}
		ls = le + 2 // step over the CRLF
	}
	// Views into the request buffer — do NOT retain them past this request.
	name := if name_l > 0 { unsafe { tos(&body[name_s], name_l) } } else { '' }
	filename := if file_l > 0 { unsafe { tos(&body[file_s], file_l) } } else { '' }
	content_start := hb + 4
	content := if end > content_start {
		unsafe { (&body[content_start]).vbytes(end - content_start) }
	} else {
		[]u8{} // len 0 / cap 0 — alloc-free
	}
	return Part{
		name:     name
		filename: filename
		content:  content
	}
}

// PartIter splits a multipart/form-data body into its parts — in place, zero
// copies, one part per `next()`, so `for p in parts_of(body, boundary)` walks
// them without building an array. `boundary` is the bare token (no leading
// `--`); each delimiter line is `--` + boundary (next_delim). The preamble
// before the first delimiter and the closing `--boundary--` are skipped per
// the RFC 2046 structure.
struct PartIter {
	body     []u8
	boundary []u8
mut:
	pos int // offset of the next delimiter; -1 once the body is exhausted
}

fn parts_of(body []u8, boundary []u8) PartIter {
	return PartIter{
		body:     body
		boundary: boundary
		pos:      if boundary.len == 0 { -1 } else { next_delim(body, 0, boundary) }
	}
}

@[direct_array_access]
fn (mut it PartIter) next() ?Part {
	dlen := 2 + it.boundary.len
	for it.pos >= 0 {
		mut start := it.pos + dlen
		// `--` right after the boundary is the closing delimiter — done.
		if start + 2 <= it.body.len && it.body[start] == `-` && it.body[start + 1] == `-` {
			it.pos = -1
			break
		}
		// Skip the CRLF that ends the delimiter line.
		if start + 2 <= it.body.len && it.body[start] == cr && it.body[start + 1] == lf {
			start += 2
		}
		next := next_delim(it.body, start, it.boundary)
		mut end := if next >= 0 { next } else { it.body.len }
		// The CRLF before the next delimiter belongs to the delimiter.
		if end - start >= 2 && it.body[end - 2] == cr && it.body[end - 1] == lf {
			end -= 2
		}
		it.pos = next // -1 when this was the last part
		if end > start {
			if p := scan_part(it.body, start, end) {
				return p
			}
		}
	}
	return none
}

// boundary_range scans the Content-Type VALUE (by offsets, in place) for the
// `boundary=` parameter and returns (start, len) of the bare token, or (-1, 0).
// The parameter name is case-insensitive (RFC 2045); the value runs to the next
// `;` or the end of the header value. Quoted boundaries are not handled — same
// as before the rewrite; browsers and curl send them bare.
@[direct_array_access]
fn boundary_range(buf []u8, start int, len int) (int, int) {
	key := 'boundary='
	end := start + len
	if len < key.len {
		return -1, 0
	}
	for i in start .. end - key.len + 1 {
		if !starts_with_ci(buf, i, end, key) {
			continue
		}
		vs := i + key.len
		mut ve := vs
		for ve < end && buf[ve] != `;` {
			ve++
		}
		if ve > vs {
			return vs, ve - vs
		}
		return -1, 0
	}
	return -1, 0
}

fn upload(req request_parser.HttpRequest, mut out []u8) {
	ct := req.get_header_value_slice('Content-Type') or {
		core.append_str(mut out, resp_400_no_content_type)
		return
	}
	buf := req.buffer // views come from this local, not `&req.buffer[...]` (see create_user_json)
	b_start, b_len := boundary_range(buf, ct.start, ct.len)
	if b_len <= 0 {
		core.append_str(mut out, resp_400_no_boundary)
		return
	}
	boundary := unsafe { (&buf[b_start]).vbytes(b_len) } // view
	body := if req.body.len > 0 {
		unsafe { (&buf[req.body.start]).vbytes(req.body.len) } // view
	} else {
		[]u8{} // len 0 / cap 0 — alloc-free
	}
	// The summary is written straight into `out`, then framed in place.
	// json2.encode_append escapes the two user-controlled strings (§8 —
	// hand-rolled escaping would be an injection risk); it is length-safe on
	// view strings (it iterates by len). Everything else is append_str/wi — no
	// `${}`, no `+`, no builder.
	mark := out.len
	core.append_str(mut out, '{"received":[')
	mut first := true
	for p in parts_of(body, boundary) {
		if p.filename.len == 0 {
			continue
		}
		if !first {
			out << `,`
		}
		first = false
		core.append_str(mut out, '{"field":')
		json2.encode_append(p.name, mut out, escape_unicode: true)
		core.append_str(mut out, ',"filename":')
		json2.encode_append(p.filename, mut out, escape_unicode: true)
		core.append_str(mut out, ',"size":')
		wi(mut out, p.content.len)
		out << `}`
	}
	core.append_str(mut out, ']}')
	frame_body(mut out, mark, head_200, head_tail)
}

// ----- routing -----------------------------------------------------------------

// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` (V array slicing marks the source buffer
// on every call; see docs/V_PERF_TOOLBOX.md). In-bounds by construction: the
// parser guarantees the Slice sits inside buf.
@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, lit string) bool {
	if s.len != lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if buf[s.start + i] != lit[i] {
			return false
		}
	}
	return true
}

// Sub-handlers take `mut out` and append directly — nothing is returned just
// to be copied again (no return-then-copy).
fn handle(req_buffer []u8, mut out []u8, _client_fd int, worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	// decode_into, not decode_http_request: a malformed request would box an
	// error() per request there.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		out << response.tiny_bad_request_response
		return .close
	}

	if slice_eq(req_buffer, req.method, 'POST') {
		if slice_eq(req_buffer, req.path, '/users') {
			create_user_json(req, mut out, worker_state)
			return .done
		}
		if slice_eq(req_buffer, req.path, '/upload') {
			upload(req, mut out)
			return .done
		}
	}
	core.append_str(mut out, resp_404)
	return .done
}

fn main() {
	// Explicit per-OS backend selection (other OSes keep the default = 0).
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	$if darwin {
		backend = server.IOBackend.kqueue
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            3000
		io_multiplexing: backend
		handler:         handle
		make_state:      make_state
	})!
	println('JSON API on http://localhost:3000/  (POST /users, POST /upload)')
	srv.run()
}
