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
//   - Static responses are consts appended with `out <<`; dynamic responses
//     are framed straight into `out` with ws/wi — no `${}`, no `+`.
//   - Multipart parts are VIEWS into the request buffer (tos/vbytes): parsing
//     allocates nothing per part, and CRLF is matched as numeric bytes (13/10).
//     The views must not outlive `req.buffer` — safe here because the response
//     is built synchronously in the same call.
//   - ONE deliberate copy remains: `json.decode` is cJSON-backed and reads its
//     input through strlen — see create_user_json.
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response
import json
import strconv
import strings

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

// ----- static responses (consts — built once, appended per request) ----------

// frame_static builds one COMPLETE response at init (the consts below).
// Interpolation-free even here: the builder writes the length as a decimal.
fn frame_static(status_line string, body string) []u8 {
	mut sb := strings.new_builder(96 + body.len)
	sb.write_string('HTTP/1.1 ')
	sb.write_string(status_line)
	sb.write_string('\r\nContent-Type: application/json\r\nContent-Length: ')
	sb.write_decimal(body.len)
	sb.write_string('\r\nConnection: keep-alive\r\n\r\n')
	sb.write_string(body)
	return sb
}

// 404 is the honest status for an unmatched route (this used to be a 400).
const resp_404 = frame_static('404 Not Found', '{"error":"not found"}')
// Decode error detail stays server-side (BEST_PRACTICES §8) — clients get a
// generic, fully static 400.
const resp_400_invalid_json = frame_static('400 Bad Request', '{"error":"invalid JSON"}')
const resp_400_missing_fields = frame_static('400 Bad Request',
	'{"error":"name and email are required"}')
const resp_400_no_content_type = frame_static('400 Bad Request', '{"error":"missing Content-Type"}')
const resp_400_no_boundary = frame_static('400 Bad Request',
	'{"error":"missing multipart boundary"}')

const cr = u8(13) // numeric, never `\r` in byte comparisons (V rune-literal footgun)
const lf = u8(10)

// ----- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------

// ws appends a string's bytes straight into `out` — no allocation.
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

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

// ----- JSON endpoint: POST /users ---------------------------------------------

fn create_user_json(req request_parser.HttpRequest, mut out []u8) {
	// DELIBERATE COPY — a string API genuinely requires it: json.decode is
	// cJSON-backed (vlib's json_parse hands `s.str` to C.cJSON_Parse, which
	// measures its input with strlen). A `tos` view into the request buffer is
	// not NUL-terminated at the body's end and would over-read past it.
	body := req.body.to_string(req.buffer)
	input := json.decode(CreateUser, body) or {
		out << resp_400_invalid_json
		return
	}
	if input.name == '' || input.email == '' {
		out << resp_400_missing_fields
		return
	}
	created := CreatedUser{
		id:    1
		name:  input.name
		email: input.email
	}
	// json.encode escapes the user-controlled strings (§8 — never reflect raw
	// input); ws/wi frame it straight into `out` — no intermediate response
	// buffer, no `${}`.
	payload := json.encode(created)
	ws(mut out, 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, payload.len)
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	ws(mut out, payload)
}

// ----- multipart endpoint: POST /upload ---------------------------------------
//
// Zero copy: the body is scanned by OFFSETS and every Part field is a view into
// the request buffer (`tos` for the attribute strings, `vbytes` for content).
// The views MUST NOT outlive req.buffer — here the summary response is built
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

// parse_multipart splits a multipart/form-data body into its parts — in place,
// zero copies. `boundary` is the bare token (no leading `--`); each delimiter
// line is `--` + boundary (next_delim). The preamble before the first delimiter
// and the closing `--boundary--` are skipped per the RFC 2046 structure.
@[direct_array_access]
fn parse_multipart(body []u8, boundary []u8) []Part {
	mut parts := []Part{}
	if boundary.len == 0 {
		return parts
	}
	dlen := 2 + boundary.len
	mut pos := next_delim(body, 0, boundary)
	for pos >= 0 {
		mut start := pos + dlen
		// `--` right after the boundary is the closing delimiter — done.
		if start + 2 <= body.len && body[start] == `-` && body[start + 1] == `-` {
			break
		}
		// Skip the CRLF that ends the delimiter line.
		if start + 2 <= body.len && body[start] == cr && body[start + 1] == lf {
			start += 2
		}
		next := next_delim(body, start, boundary)
		mut end := if next >= 0 { next } else { body.len }
		// The CRLF before the next delimiter belongs to the delimiter.
		if end - start >= 2 && body[end - 2] == cr && body[end - 1] == lf {
			end -= 2
		}
		if end > start {
			if p := scan_part(body, start, end) {
				parts << p
			}
		}
		if next < 0 {
			break
		}
		pos = next
	}
	return parts
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
		out << resp_400_no_content_type
		return
	}
	b_start, b_len := boundary_range(req.buffer, ct.start, ct.len)
	if b_len <= 0 {
		out << resp_400_no_boundary
		return
	}
	boundary := unsafe { (&req.buffer[b_start]).vbytes(b_len) } // view
	mut parts := []Part{}
	if req.body.len > 0 {
		body := unsafe { (&req.buffer[req.body.start]).vbytes(req.body.len) } // view
		parts = parse_multipart(body, boundary)
	}
	// The summary must be sized before the headers can be written, so it is
	// assembled in ONE builder. json.encode escapes the two user-controlled
	// strings (§8 — hand-rolled escaping would be an injection risk); it is
	// length-safe on view strings (json_ascii_string iterates by len).
	// Everything else is write_string/write_decimal — no `${}`, no `+`, no join.
	mut summary := strings.new_builder(32 + parts.len * 64)
	summary.write_string('{"received":[')
	mut first := true
	for p in parts {
		if p.filename.len == 0 {
			continue
		}
		if !first {
			summary.write_u8(`,`)
		}
		first = false
		summary.write_string('{"field":')
		summary.write_string(json.encode(p.name))
		summary.write_string(',"filename":')
		summary.write_string(json.encode(p.filename))
		summary.write_string(',"size":')
		summary.write_decimal(p.content.len)
		summary.write_u8(`}`)
	}
	summary.write_string(']}')
	ws(mut out, 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ')
	wi(mut out, summary.len)
	ws(mut out, '\r\nConnection: keep-alive\r\n\r\n')
	out << summary // Builder IS []u8 — appended directly, never re-stringified
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
fn handle(req_buffer []u8, mut out []u8, mut ctx core.Ctx) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	if slice_eq(req.buffer, req.method, 'POST') {
		if slice_eq(req.buffer, req.path, '/users') {
			create_user_json(req, mut out)
			return .done
		}
		if slice_eq(req.buffer, req.path, '/upload') {
			upload(req, mut out)
			return .done
		}
	}
	out << resp_404
	return .done
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
		handler:         handle
	})!
	println('JSON API on http://localhost:3000/  (POST /users, POST /upload)')
	server.run()
}
