module main

// Percent-decoding + form-urlencoded bodies — reference design.
//
// The parser deliberately does NOT decode percent-escapes (it returns raw
// bytes — the right default for a zero-copy core). But almost every real app
// needs decoded values, so this is the canonical place to do it: at the edge of
// the handler, explicitly, once, with request_parser.percent_decode_into.
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
// It can also be any bytes (`%FF`), while JSON must be UTF-8 (RFC 8259 §8.1):
// ill-formed UTF-8 is echoed as U+FFFD.
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
//   - DECODE STRAIGHT INTO THE OUTPUT: request_parser.percent_decode_into
//     writes each key and value directly into the JSON echo in `out`, where
//     it is then escaped (and ill-formed UTF-8 replaced) in place. The decoded
//     pairs are used once, within the call, so they never need to exist as
//     strings, in a map, or in a builder.
//   - The response is the JSON body written into `out`, then framed in place
//     (frame_body puts the const prefix and the exact Content-Length in front
//     of it) — no `${}`, no `+`, no allocation.
//   - Pairs are echoed in wire order, one JSON member per pair: a repeated
//     key (`tag=a&tag=b`, the usual multi-value form) appears once per pair.
import server
import core
import http1_1.request_parser
import http1_1.response
import strconv

// Rune-literal escapes are unreliable in this toolchain (docs/V_PERF_TOOLBOX.md
// gotcha) — the backslash byte as an explicit numeric value.
const backslash = u8(92)
const hex_lower = '0123456789abcdef'

// write_decoded_json appends the form-encoded bytes `s` to `out` as the
// inside of a JSON string. request_parser.percent_decode_into decodes them
// straight into `out`, exactly once: %XX escapes and '+' as a space, a
// malformed escape (dangling `%`, non-hex) kept as it is. The decoded bytes
// are then made JSON-safe in place, in two passes and with no scratch buffer:
//   1. Forwards, since UTF-8 is validated front to back: well-formed UTF-8
//      stays, and each ill-formed sequence (its maximal subpart, see
//      utf8_sequence) is to become one U+FFFD, so the JSON is UTF-8
//      (RFC 8259 §8.1). A 3-byte one is replaced right away, U+FFFD being 3
//      bytes too; a 1- or 2-byte one is marked FF or FE FE. UTF-8 never uses
//      FE or FF (one in the input is a 1-byte subpart, marked FF), so after
//      this pass every FE and FF is a marker. The pass also adds up how much
//      longer the bytes get: 2 per FF, 1 per FE FE, and the JSON escapes.
//   2. If they get longer, backwards, once `out` has grown by that much (each
//      byte moves right by the growth still ahead of it, so none is
//      overwritten before it is read): `"`, `\` and control bytes are
//      escaped, and each marker becomes U+FFFD.
@[direct_array_access]
fn write_decoded_json(mut out []u8, s []u8) {
	start := out.len
	request_parser.percent_decode_into(s, mut out, true)
	end := out.len
	mut extra := 0
	mut i := start
	for i < end {
		c := out[i]
		if c < 0x80 {
			extra += json_escape_extra(c)
			i++
			continue
		}
		n, ok := utf8_sequence(out, i, end)
		if !ok {
			if n == 3 {
				out[i] = 0xEF // U+FFFD REPLACEMENT CHARACTER
				out[i + 1] = 0xBF
				out[i + 2] = 0xBD
			} else if n == 2 {
				out[i] = 0xFE
				out[i + 1] = 0xFE
				extra++
			} else {
				out[i] = 0xFF
				extra += 2
			}
		}
		i += n
	}
	if extra == 0 {
		return
	}
	unsafe { out.grow_len(extra) }
	mut w := out.len
	for r := end - 1; r >= start; r-- {
		c := out[r]
		if c == `"` || c == backslash {
			w -= 2
			out[w] = backslash
			out[w + 1] = c
		} else if c < 0x20 {
			w -= 6
			out[w] = backslash
			out[w + 1] = `u`
			out[w + 2] = `0`
			out[w + 3] = `0`
			out[w + 4] = hex_lower[int(c >> 4)]
			out[w + 5] = hex_lower[int(c & 0x0F)]
		} else if c >= 0xFE { // a marker
			if c == 0xFE {
				r-- // the first byte of FE FE
			}
			w -= 3
			out[w] = 0xEF
			out[w + 1] = 0xBF
			out[w + 2] = 0xBD
		} else {
			w--
			out[w] = c
		}
	}
}

// utf8_sequence reads the UTF-8 sequence that starts at buf[i] (i < end;
// nothing at or past `end` is read). When it is well-formed (Unicode
// Table 3-7: no overlong form, no surrogate, nothing past U+10FFFF), it
// returns its length, 1 to 4, and true. Otherwise it returns the length of
// its maximal subpart, 1 to 3, and false: the lead byte and the continuation
// bytes that still fit it, which one U+FFFD replaces (Unicode §3.9 "U+FFFD
// Substitution of Maximal Subparts", as the WHATWG UTF-8 decoder does). A
// byte that cannot lead (a stray continuation 80..BF, C0, C1, F5..FF) is a
// maximal subpart of its own.
@[direct_array_access]
fn utf8_sequence(buf []u8, i int, end int) (int, bool) {
	b := buf[i]
	if b < 0x80 {
		return 1, true
	}
	mut need := 0 // continuation bytes after the lead
	mut lo := u8(0x80) // the range the next continuation byte must be in
	mut hi := u8(0xBF)
	if b >= 0xC2 && b <= 0xDF {
		need = 1
	} else if b >= 0xE0 && b <= 0xEF {
		need = 2
		if b == 0xE0 {
			lo = 0xA0 // E0 80..9F would be an overlong form
		} else if b == 0xED {
			hi = 0x9F // ED A0..BF would be a surrogate
		}
	} else if b >= 0xF0 && b <= 0xF4 {
		need = 3
		if b == 0xF0 {
			lo = 0x90 // F0 80..8F would be an overlong form
		} else if b == 0xF4 {
			hi = 0x8F // F4 90..BF would be past U+10FFFF
		}
	} else {
		return 1, false
	}
	for k in 1 .. need + 1 {
		if i + k >= end || buf[i + k] < lo || buf[i + k] > hi {
			return k, false
		}
		lo = 0x80
		hi = 0xBF
	}
	return need + 1, true
}

// json_escape_extra is how many bytes longer the ASCII byte `c` gets inside a
// JSON string: RFC 8259 REQUIRES escaping `"`, `\` and control bytes < 0x20.
// Decoded form values are user input — echoing them raw would produce broken
// (and injectable) JSON (BEST_PRACTICES §8).
@[inline]
fn json_escape_extra(c u8) int {
	return if c == `"` || c == backslash {
		1
	} else if c < 0x20 {
		5
	} else {
		0
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

// write_form_json appends the pairs of `key=val&...` bytes (a query string or
// an x-www-form-urlencoded body) to `out` as a JSON object, decoding each key
// and value straight into it. Pairs are walked by OFFSET — no split(), no
// substring copies, no map: one member per pair, in wire order. A pair
// without '=' is a key with an empty value.
@[direct_array_access]
fn write_form_json(mut out []u8, s []u8) {
	out << `{`
	mut first := true
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
		if !first {
			out << `,`
		}
		first = false
		out << `"`
		write_decoded_json(mut out, view(s, pos, eq - pos))
		core.append_str(mut out, '":"')
		if eq < amp {
			write_decoded_json(mut out, view(s, eq + 1, amp - eq - 1))
		}
		out << `"`
		pos = amp + 1
	}
	out << `}`
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

// ---- zero-alloc append helper (BEST_PRACTICES §3b) --------------------------
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
	mut view_ := unsafe { (&digits[0]).vbytes(digits.len) }
	n := strconv.write_dec(i64(body_len), mut view_)
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

const resp_prefix = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '
const resp_prefix_tail = '\r\n\r\n'

@[direct_array_access]
fn handle(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	// decode_into, not decode_http_request: a malformed request would box an
	// error() per request there.
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	if !request_parser.decode_into(mut req) {
		out << response.tiny_bad_request_response
		return .close
	}

	// Query string case: find '?' IN PLACE over the path bytes.
	mut form_start := 0
	mut form_len := 0
	path_end := req.path.start + req.path.len
	mut q := req.path.start
	for q < path_end && req_buffer[q] != `?` {
		q++
	}
	if q < path_end {
		form_start = q + 1
		form_len = path_end - q - 1
	}

	// form-urlencoded body case — method and Content-Type compared in place.
	// The body replaces the query.
	if slice_eq(req_buffer, req.method, 'POST') && is_form_urlencoded(req) {
		form_start = req.body.start
		form_len = req.body.len
	}

	// JSON echo, decoded straight into `out`, then framed in place.
	mark := out.len
	write_form_json(mut out, view(req_buffer, form_start, form_len))
	frame_body(mut out, mark, resp_prefix, resp_prefix_tail)
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
