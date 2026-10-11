module main

// Content negotiation + compression — reference design.
//
// THE PURE SHAPE
//   Compression is a transport concern, not an application one. The handler
//   stays bytes-in/bytes-out; a negotiation step picks the encoding the client
//   accepts and the response carries `Content-Encoding` + `Vary: Accept-Encoding`.
//
// THE PERF SHAPE
//   This demo's body is STATIC, so everything is done ONCE at init: the body is
//   compressed with each encoder and four COMPLETE responses (headers + body)
//   are cached as consts — the same idea as the static_assets module serving
//   precompressed `.br`/`.gz` siblings from disk. The per-request work is:
//   parse → one pass over the Accept-Encoding bytes IN PLACE in the request
//   buffer (by offsets — not even a `buf[a..b]` slice, see pick_encoding)
//   → one append of the chosen const response into `out` (BEST_PRACTICES §1/§3a).
//   No `.to_string()`, no `strings.Builder`, no compression on the hot path.
//
// ENCODERS — all stdlib since vlang/v#27613 (2026-07-01):
//   - gzip (`compress.gzip`): pure V, always available.
//   - zstd (`compress.zstd`): vendored C sources, always available.
//   - brotli (`compress.brotli`): dlopens system libbrotlienc/libbrotlidec.
//     When the libraries are missing, `compress` errors at init, `resp_br`
//     stays empty and negotiation leaves br out (`brotli_ok`).
//
// NEGOTIATION (RFC 9110 §12.5.3) — pick_encoding:
//   - q-values count (§12.4.2): `gzip;q=0` refuses gzip, `br;q=0.5, gzip`
//     gets gzip. An element whose q does not parse (`q=2`, `q=0.1234`,
//     `q = 0`) is ignored.
//   - `*` lends its q to every coding the client did not list, `x-gzip` is
//     gzip, and a coding listed twice keeps its lowest q: a refusal wins.
//   - The highest q wins; ties go to br > zstd > gzip. When none of them is
//     acceptable the body goes out as is (identity), unless the client refused
//     identity too (`identity;q=0`, or `*;q=0` with no identity entry): 406.
//   - Only the first Accept-Encoding field line is read (get_header_value_slice):
//     a second line's elements are not merged in (RFC 9110 §5.3).
//
// DYNAMIC BODIES (when you cannot precompress)
//   - gzip/zstd per response are fine; `brotli.compress` dlopens/dlcloses the
//     library on EVERY call — keep it off the hot path (build time: q11).
//   - Only compress when it pays: skip tiny bodies (< ~256 B) and
//     already-compressed types (images, video, zip).
//   - If an encoder fails, fall back to identity and OMIT `Content-Encoding` —
//     never label uncompressed bytes as compressed.
import server
import core
import http1_1.request_parser
import http1_1.response
import compress.brotli
import compress.gzip
import compress.zstd
import strings

// The application just makes bytes — built once, compressed once.
const demo_body = ('{"message":"this body is large enough to be worth compressing",' +
	'"items":[1,2,3,4,5,6,7,8,9,10],"note":"' + 'repeated text compresses well '.repeat(12) + '"}').bytes()

// Complete precompressed responses, built at init — the hot path only picks one.
// brotli q11 / zstd 19 are build-time settings: ratio matters, latency doesn't.
const resp_identity = make_response('', demo_body)
const resp_gzip = make_response('gzip', gzip.compress(demo_body) or { panic(err) })
const resp_zstd = make_response('zstd', zstd.compress(demo_body, compression_level: 19) or {
	panic(err)
})
const body_br = brotli.compress(demo_body, quality: 11, mode: .text) or { []u8{} } // empty = no libbrotli
const resp_br = if body_br.len > 0 { make_response('br', body_br) } else { []u8{} }

// The client refused identity and accepts none of the codings we have. It
// still depends on Accept-Encoding, hence Vary; the connection stays open.
const resp_406 = 'HTTP/1.1 406 Not Acceptable\r\nContent-Length: 0\r\nVary: Accept-Encoding\r\nConnection: keep-alive\r\n\r\n'

enum Encoding {
	identity
	gzip
	zstd
	br
	not_acceptable // no acceptable coding, identity refused: 406
}

// make_response frames one complete response. Runs ONCE per encoding at init,
// so `${}` is fine here — nothing below executes per request.
fn make_response(label string, body []u8) []u8 {
	mut sb := strings.new_builder(160 + body.len)
	sb.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n')
	sb.write_string('Content-Length: ${body.len}\r\nVary: Accept-Encoding\r\n')
	if label != '' {
		sb.write_string('Content-Encoding: ${label}\r\n')
	}
	sb.write_string('Connection: keep-alive\r\n\r\n')
	sb.write(body) or {}
	return sb
}

// is_delim: the bytes that end a coding, a qvalue or (with `=`) a parameter
// name.
@[inline]
fn is_delim(c u8) bool {
	return c == `,` || c == `;` || c == ` ` || c == `\t`
}

// is_ows: optional whitespace, SP or HTAB (RFC 9110 §5.6.3).
@[inline]
fn is_ows(c u8) bool {
	return c == ` ` || c == `\t`
}

// lower_eq reports whether the `s.len` bytes at `buf[i]`, ASCII-lowercased,
// equal `s` (lowercase). A real lowercase, not `| 0x20`: that trick only works
// for letters, and `x-gzip` has a `-` (`| 0x20` maps CR to `-` too).
@[direct_array_access; inline]
fn lower_eq(buf []u8, i int, s string) bool {
	for k in 0 .. s.len {
		mut c := buf[i + k]
		if c >= `A` && c <= `Z` {
			c += 32
		}
		if c != s[k] {
			return false
		}
	}
	return true
}

// qvalue parses `buf[i .. end]` as a qvalue, `0[.ddd]` or `1[.000]` (RFC 9110
// §12.4.2), into thousandths: 0..1000. Anything else is -1: `2`, `1.5`, `.5`,
// `0.1234` (four decimals), an empty value.
@[direct_array_access; inline]
fn qvalue(buf []u8, i int, end int) int {
	n := end - i
	if n < 1 || n > 5 || (buf[i] != `0` && buf[i] != `1`) {
		return -1
	}
	if n == 1 {
		return int(buf[i] - `0`) * 1000
	}
	if buf[i + 1] != `.` {
		return -1
	}
	mut frac := 0
	for k in i + 2 .. i + 5 { // three decimals, a missing one counts as 0
		frac *= 10
		if k < end {
			c := buf[k]
			if c < `0` || c > `9` {
				return -1
			}
			frac += int(c - `0`)
		}
	}
	if buf[i] == `1` {
		return if frac == 0 { 1000 } else { -1 }
	}
	return frac
}

// lowest folds a repeated entry: the lower q counts, so a refusal anywhere
// wins. `cur` is -1 while the coding is not listed.
@[inline]
fn lowest(cur int, q int) int {
	return if cur < 0 || q < cur { q } else { cur }
}

// pick_encoding negotiates over the Accept-Encoding value at
// `buf[start .. start + len]`, addressed by OFFSETS, never by `buf[a..b]` (V
// array slicing marks the source buffer on every call, ~11% of a hot path per
// docs/V_PERF_TOOLBOX.md; pure waste for a transient read-only scan). One pass,
// zero allocations, zero copies. In-bounds by construction: the parser
// guarantees start/len sit inside buf, so direct_array_access is safe.
//
// The value is a comma-separated list (RFC 9110 §12.5.3); each element is a
// coding, then `;` parameters, OWS allowed around the `;`. The coding is a
// whole token compared case-insensitively (§8.4.1): `pack200-gzip` is a
// different coding, not gzip; `x-gzip` is gzip (§8.4.1.3). The weight is the
// `q` parameter (name in any case, no OWS around its `=`: §12.4.2, §5.6.6) in
// thousandths, 1000 when absent; other parameters are skipped. An element
// whose q does not parse (`q=2`, `q=`, `q = 0`), or with anything but `;`
// after its coding, is ignored. Repeats keep the lowest q (`lowest`).
//
// A coding we have takes its own q, else the q of `*` when `*` is listed,
// else 0. The highest q above 0 wins, ties going to br > zstd > gzip (br only
// when `brotli_ok`, a parameter so both branches are testable). With no
// winner the answer is identity, unless the client refused it: `identity;q=0`,
// or `*;q=0` with no identity entry (§12.5.3) give .not_acceptable.
@[direct_array_access; inline]
fn pick_encoding(buf []u8, start int, len int, brotli_ok bool) Encoding {
	// q of each coding we track, in thousandths; -1 = not listed.
	mut q_br := -1
	mut q_zstd := -1
	mut q_gzip := -1
	mut q_identity := -1
	mut q_any := -1 // `*`
	end := start + len
	mut i := start
	for i < end {
		// One element, up to its `,`: OWS, the coding, then its parameters.
		for i < end && is_ows(buf[i]) {
			i++
		}
		name := i
		for i < end && !is_delim(buf[i]) {
			i++
		}
		name_len := i - name
		mut q := 1000
		mut ok := true
		for {
			for i < end && is_ows(buf[i]) {
				i++
			}
			if i == end || buf[i] == `,` {
				break
			}
			if buf[i] != `;` {
				ok = false // `gzip x`: not a coding followed by parameters
				break
			}
			i++
			for i < end && is_ows(buf[i]) {
				i++
			}
			p := i
			for i < end && buf[i] != `=` && !is_delim(buf[i]) {
				i++
			}
			if i - p != 1 || (buf[p] != `q` && buf[p] != `Q`) {
				// Not the weight: skip this parameter's value.
				for i < end && buf[i] != `;` && buf[i] != `,` {
					i++
				}
				continue
			}
			if i == end || buf[i] != `=` {
				ok = false // `q`, `q =0`
				break
			}
			i++
			v := i
			for i < end && !is_delim(buf[i]) {
				i++
			}
			w := qvalue(buf, v, i)
			if w < 0 {
				ok = false // `q=2`, `q=0.1234`, `q=`, `q= 0`
				break
			}
			q = lowest(q, w)
		}
		for i < end && buf[i] != `,` { // the rest of an ignored element
			i++
		}
		i++ // past the `,`
		if !ok {
			continue
		}
		match name_len {
			1 {
				if buf[name] == `*` {
					q_any = lowest(q_any, q)
				}
			}
			2 {
				if lower_eq(buf, name, 'br') {
					q_br = lowest(q_br, q)
				}
			}
			4 {
				if lower_eq(buf, name, 'gzip') {
					q_gzip = lowest(q_gzip, q)
				} else if lower_eq(buf, name, 'zstd') {
					q_zstd = lowest(q_zstd, q)
				}
			}
			6 {
				if lower_eq(buf, name, 'x-gzip') {
					q_gzip = lowest(q_gzip, q)
				}
			}
			8 {
				if lower_eq(buf, name, 'identity') {
					q_identity = lowest(q_identity, q)
				}
			}
			else {}
		}
	}
	// An unlisted coding takes the q of `*`, or 0 when `*` is not listed either.
	star := if q_any > 0 { q_any } else { 0 }
	mut best := Encoding.identity
	mut best_q := 0
	if brotli_ok {
		w := if q_br >= 0 { q_br } else { star }
		if w > best_q {
			best = .br
			best_q = w
		}
	}
	w_zstd := if q_zstd >= 0 { q_zstd } else { star }
	if w_zstd > best_q {
		best = .zstd
		best_q = w_zstd
	}
	w_gzip := if q_gzip >= 0 { q_gzip } else { star }
	if w_gzip > best_q {
		best = .gzip
	}
	if best == .identity && (q_identity == 0 || (q_identity < 0 && q_any == 0)) {
		return .not_acceptable
	}
	return best
}

fn handle(req_buffer []u8, mut out []u8, _client_fd int, _worker_state voidptr, mut _event_loop core.EventLoop) core.Step {
	req := request_parser.decode_http_request(req_buffer) or {
		out << response.tiny_bad_request_response
		return .close
	}
	mut enc := Encoding.identity
	if s := req.get_header_value_slice('Accept-Encoding') {
		enc = pick_encoding(req.buffer, s.start, s.len, resp_br.len > 0)
	}
	match enc {
		.br { out << resp_br }
		.zstd { out << resp_zstd }
		.gzip { out << resp_gzip }
		.identity { out << resp_identity }
		.not_acceptable { core.append_str(mut out, resp_406) }
	}

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
	println('Compression demo on http://localhost:3000/  (try: curl --compressed -v localhost:3000)')
	if resp_br.len == 0 {
		println('note: system libbrotli not found — `br` disabled, negotiating zstd/gzip instead')
	}
	srv.run()
}
