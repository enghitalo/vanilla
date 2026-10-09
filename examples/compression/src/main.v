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
//   are cached as consts — the same idea as server.static_assets serving
//   precompressed `.br`/`.gz` siblings from disk. The per-request work is:
//   parse → case-insensitive scan of the Accept-Encoding bytes IN PLACE in the
//   request buffer (by offsets — not even a `buf[a..b]` slice, see has_token)
//   → one append of the chosen const response into `out` (BEST_PRACTICES §1/§3a).
//   No `.to_string()`, no `strings.Builder`, no compression on the hot path.
//
// ENCODERS — all stdlib since vlang/v#27613 (2026-07-01):
//   - gzip (`compress.gzip`): pure V, always available.
//   - zstd (`compress.zstd`): vendored C sources, always available.
//   - brotli (`compress.brotli`): dlopens system libbrotlienc/libbrotlidec.
//     When the libraries are missing, `compress` errors at init, `resp_br`
//     stays empty and negotiation falls through to zstd/gzip.
//
// DYNAMIC BODIES (when you cannot precompress)
//   - gzip/zstd per response are fine; `brotli.compress` dlopens/dlcloses the
//     library on EVERY call — keep it off the hot path (build time: q11).
//   - Only compress when it pays: skip tiny bodies (< ~256 B) and
//     already-compressed types (images, video, zip).
//   - A real impl parses q-values (`gzip;q=0` DISABLES an encoding), treats
//     `*` as "any" and the legacy `x-gzip` alias as gzip — the scan below only
//     shows the selection shape; those all safely fall back to identity here.
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

enum Encoding {
	identity
	gzip
	zstd
	br
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

// has_token reports whether `buf[start .. start + len]` — the Accept-Encoding
// value addressed by OFFSETS, never by `buf[a..b]` (V array slicing marks the
// source buffer on every call, ~11% of a hot path per docs/V_PERF_TOOLBOX.md;
// pure waste for a transient read-only scan) — contains `needle` as a WHOLE
// token: `gzip` matches `gzip` and `GZIP;q=1`, but not `pack200-gzip` (a
// distinct IANA coding — substring matching would serve gzip to a client that
// never accepted it). Tokens are case-insensitive (RFC 9110); `| 0x20`
// lowercases ASCII letters, so `needle` must be LOWERCASE LETTERS ONLY — the
// constraint is load-bearing: for non-letters the trick aliases other bytes
// (`-` would also match CR, `0` would match DLE).
// Zero allocations, zero copies. In-bounds by construction: the parser
// guarantees start/len sit inside buf, so direct_array_access is safe.
@[direct_array_access]
fn has_token(buf []u8, start int, len int, needle string) bool {
	if needle.len == 0 || len < needle.len {
		return false
	}
	end := start + len
	for i in start .. end - needle.len + 1 {
		mut j := 0
		for j < needle.len && (buf[i + j] | 0x20) == needle[j] {
			j++
		}
		if j < needle.len {
			continue
		}
		// Delimited on both sides: start/end of value, `,`, `;` or whitespace.
		before_ok := i == start || buf[i - 1] in [u8(`,`), ` `, 9]
		after := i + needle.len
		after_ok := after == end || buf[after] in [u8(`,`), `;`, ` `, 9]
		if before_ok && after_ok {
			return true
		}
	}
	return false
}

// Pick the best encoding we both support and the client accepts, straight from
// the Accept-Encoding bytes in the request buffer. Preference: br > zstd >
// gzip > identity. Availability is a parameter so both branches are testable.
@[inline]
fn pick_encoding(buf []u8, start int, len int, brotli_ok bool) Encoding {
	if brotli_ok && has_token(buf, start, len, 'br') {
		return .br
	}
	if has_token(buf, start, len, 'zstd') {
		return .zstd
	}
	if has_token(buf, start, len, 'gzip') {
		return .gzip
	}
	return .identity
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
