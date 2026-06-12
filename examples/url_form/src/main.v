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
// boundary and treat the result as final.
//
// WORKS TODAY (pure byte transformation). For the body case it shares the
// "needs the full body" caveat with examples/json_api.
import http_server
import http_server.http1_1.request_parser

// percent_decode: turn %XX escapes and '+' into bytes. Decode exactly once.
fn percent_decode(s string) string {
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

// parse_form: decode a key=val&... string into a map (used for both query
// strings and x-www-form-urlencoded bodies).
fn parse_form(s string) map[string]string {
	mut out := map[string]string{}
	for pair in s.split('&') {
		if pair == '' {
			continue
		}
		if eq := pair.index('=') {
			key := percent_decode(pair[..eq])
			val := percent_decode(pair[eq + 1..])
			out[key] = val
		} else {
			out[percent_decode(pair)] = ''
		}
	}
	return out
}

fn handle(req_buffer []u8, _ int, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!
	method := req.method.to_string(req.buffer)
	path := req.path.to_string(req.buffer)

	// Query string case.
	mut decoded := map[string]string{}
	if qi := path.index('?') {
		decoded = parse_form(path[qi + 1..])
	}

	// form-urlencoded body case.
	if method == 'POST' {
		ct := if c := req.get_header_value_slice('Content-Type') {
			c.to_string(req.buffer)
		} else {
			''
		}
		if ct.starts_with('application/x-www-form-urlencoded') {
			body := req.body.to_string(req.buffer)
			decoded = parse_form(body)
		}
	}

	mut parts := []string{}
	for k, v in decoded {
		parts << '"${k}":"${v}"'
	}
	body := '{${parts.join(',')}}'
	out << 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
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
		request_handler: handle
	})!
	println('URL/form decoding demo on http://localhost:3000/  (try /x?q=hello%20world&tag=c%2B%2B)')
	server.run()
}
