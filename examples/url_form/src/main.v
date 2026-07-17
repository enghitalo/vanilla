module main

// Percent-decoding + form-urlencoded bodies — reference design.
//
// The parser deliberately does NOT decode percent-escapes (it returns raw
// bytes — the right default for a zero-copy core). But almost every real app
// needs decoded values, so this is the canonical place to do it: at the edge of
// the handler, explicitly, once.
//
// TWO PLACES ENCODING APPEARS:
//   1. The URL/query:  /search?q=hello%20world&tag=c%2B%2B
//      `%20` -> space, `+` -> space (in query strings), `%2B` -> '+'.
//   2. application/x-www-form-urlencoded BODIES (classic HTML form POSTs):
//      same encoding, `key=val&key2=val2`.
//
// SECURITY: decode ONCE. Double-decoding (decoding an already-decoded value) is
// a classic filter-bypass — `%2527` becoming `%27` becoming `'`. Decode at the
// boundary and treat the result as final. And what you decoded is USER INPUT:
// echoing it into JSON needs string escaping, or the response is injectable.
//
// WORKS TODAY (pure byte transformation). Body framing is handled by the core:
// every read loop frames the request by Content-Length/chunked before dispatch,
// so `req.body` is the complete body for bodies within the engine's buffering
// limits.
//
// BYTE DISCIPLINE (docs/BEST_PRACTICES.md §2/§3, docs/V_PERF_TOOLBOX.md):
//   - INPUTS ARE VIEWS: routing, the `?` scan, the Content-Type check and the
//     pair iteration all read the request buffer in place by offsets — no
//     `.to_string()`, no `split()`, no substring copies.
//   - OUTPUTS ARE OWNED — on purpose: a decoded value is a TRANSFORMED byte
//     sequence (escapes collapsed), and it lives in a map that must outlive
//     the request buffer. That one `bytestr()` per key/value is the copy this
//     example exists to demonstrate; everything around it stays zero-copy.
//   - The response is framed with a const prefix + `wi`/`ws` appends; the JSON
//     body is genuinely dynamic (map echo), so it gets ONE strings.Builder.
import server
import core
import http1_1.request_parser
import http1_1.response
import strconv
import strings

// Rune-literal escapes are unreliable in this toolchain (docs/V_PERF_TOOLBOX.md
// gotcha) — the backslash byte as an explicit numeric value.
const backslash = u8(92)
const hex_lower = '0123456789abcdef'

// percent_decode: turn %XX escapes and '+' into bytes. Decode exactly once.
// The input is a zero-copy view; the RETURN is an owned string on purpose —
// decoded bytes differ from the wire bytes and become map keys/values that
// must outlive the request buffer (the justified copy, see header).
// Malformed escapes (dangling `%`, non-hex) emit the literal `%` and move on.
@[direct_array_access]
fn percent_decode(s []u8) string {
	mut out := []u8{cap: s.len}
	mut i := 0
	for i < s.len {
		c := s[i]
		if c == `%` && i + 2 < s.len {
			hi := hex_val(s[i + 1]) or {
				out << c
				i++
				continue
			}
			lo := hex_val(s[i + 2]) or {
				out << c
				i++
				continue
			}
			out << u8(hi * 16 + lo)
			i += 3
		} else if c == `+` {
			out << ` ` // '+' means space in query / form encoding
			i++
		} else {
			out << c
			i++
		}
	}
	return out.bytestr()
}

fn hex_val(c u8) ?int {
	return match c {
		`0`...`9` { int(c - `0`) }
		`a`...`f` { int(c - `a` + 10) }
		`A`...`F` { int(c - `A` + 10) }
		else { none }
	}
}

// view returns a zero-copy window into buf, or an empty slice for len == 0
// (`&buf[start]` on an empty window would index out of bounds; a len-0/cap-0
// literal is alloc-free).
@[inline]
fn view(buf []u8, start int, len int) []u8 {
	if len <= 0 {
		return []u8{}
	}
	return unsafe { (&buf[start]).vbytes(len) }
}

// parse_form: decode `key=val&...` bytes into a map (used for both query
// strings and x-www-form-urlencoded bodies). Pairs are walked by OFFSET —
// no split(), no substring copies; the only allocations are the decoded
// key/value strings the map owns.
@[direct_array_access]
fn parse_form(s []u8) map[string]string {
	mut out := map[string]string{}
	mut pos := 0
	for pos < s.len {
		mut amp := pos // pair is s[pos..amp), amp = next '&' or end
		for amp < s.len && s[amp] != `&` {
			amp++
		}
		if amp == pos { // empty pair (leading '&' or '&&')
			pos++
			continue
		}
		mut eq := pos
		for eq < amp && s[eq] != `=` {
			eq++
		}
		if eq < amp {
			key := percent_decode(view(s, pos, eq - pos))
			val := percent_decode(view(s, eq + 1, amp - eq - 1))
			out[key] = val
		} else {
			out[percent_decode(view(s, pos, amp - pos))] = ''
		}
		pos = amp + 1
	}
	return out
}

// ---- zero-alloc append helpers (BEST_PRACTICES §3b) -------------------------
// ws appends a string's bytes straight into `out` — no allocation.
@[inline]
fn ws(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}

// wi appends n's decimal digits into `out` — itoa into a stack scratch, then
// append. No allocation, no `.str()`.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view_ := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view_)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// slice_eq compares a request Slice against a literal IN PLACE by offsets —
// no `.to_string()`, no `buf[a..b]` slice-marking. In-bounds by construction:
// the parser guarantees the Slice sits inside buf.
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

// is_form_urlencoded checks Content-Type IN PLACE over the header bytes: a
// case-insensitive PREFIX compare. `| 0x20` lowercases ASCII letters (every
// non-letter byte of this needle already has bit 5 set, so the fold is a
// no-op on them — the needle must be all-lowercase for this to work).
// Case-insensitivity is an RFC 9110 §8.3.1 correctness improvement over the
// old case-sensitive starts_with; matching the prefix (not the whole value)
// keeps tolerating a `;charset=` suffix, as before.
@[direct_array_access]
fn is_form_urlencoded(req request_parser.HttpRequest) bool {
	s := req.get_header_value_slice('Content-Type') or { return false }
	lit := 'application/x-www-form-urlencoded'
	if s.len < lit.len {
		return false
	}
	for i in 0 .. lit.len {
		if (req.buffer[s.start + i] | 0x20) != lit[i] {
			return false
		}
	}
	return true
}

// write_json_escaped appends s into the builder with the escapes RFC 8259
// REQUIRES inside a JSON string: `"`, `\` and control bytes < 0x20. Decoded
// form values are user input — echoing them raw would produce broken (and
// injectable) JSON (BEST_PRACTICES §8).
@[direct_array_access]
fn write_json_escaped(mut sb strings.Builder, s string) {
	for i in 0 .. s.len {
		c := s[i]
		if c == `"` || c == backslash {
			sb.write_u8(backslash)
			sb.write_u8(c)
		} else if c < 0x20 {
			sb.write_string('\\u00')
			sb.write_u8(hex_lower[int(c >> 4)])
			sb.write_u8(hex_lower[int(c & 0x0F)])
		} else {
			sb.write_u8(c)
		}
	}
}

const resp_prefix = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '.bytes()

@[direct_array_access]
fn handle(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}

	// Query string case: find '?' IN PLACE over the path bytes.
	mut decoded := map[string]string{}
	path_end := req.path.start + req.path.len
	mut q := req.path.start
	for q < path_end && req.buffer[q] != `?` {
		q++
	}
	if q < path_end {
		decoded = parse_form(view(req.buffer, q + 1, path_end - q - 1))
	}

	// form-urlencoded body case — method and Content-Type compared in place.
	if slice_eq(req.buffer, req.method, 'POST') && is_form_urlencoded(req) {
		decoded = parse_form(view(req.buffer, req.body.start, req.body.len))
	}

	// JSON echo. The body is genuinely dynamic (map contents), so it gets ONE
	// strings.Builder — decoded output never exceeds the wire input, so the
	// path+body seed only over-shoots by the escaping (rare). Zero `${}`.
	mut body := strings.new_builder(64 + req.path.len + req.body.len)
	body.write_u8(`{`)
	mut first := true
	for k, v in decoded {
		if !first {
			body.write_u8(`,`)
		}
		first = false
		body.write_u8(`"`)
		write_json_escaped(mut body, k)
		body.write_string('":"')
		write_json_escaped(mut body, v)
		body.write_u8(`"`)
	}
	body.write_u8(`}`)
	// Frame: const prefix + decimal length + blank line + the builder's bytes
	// (Builder IS []u8 — it appends into `out` directly, no bytestr()).
	out << resp_prefix
	wi(mut out, body.len)
	ws(mut out, '\r\n\r\n')
	out << body
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
	})!
	println('URL/form decoding demo on http://localhost:3000/  (try /x?q=hello%20world&tag=c%2B%2B)')
	srv.run()
}
