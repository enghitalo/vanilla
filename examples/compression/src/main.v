module main

// Content negotiation + compression — reference design.
//
// THE PURE SHAPE
//   Compression is a transport concern, not an application one. The handler
//   produces the resource bytes once; a thin step negotiates `Accept-Encoding`
//   against what we can produce and encodes the body, setting `Content-Encoding`
//   and `Vary: Accept-Encoding`. The handler never thinks about gzip.
//
// WORKS TODAY: gzip/deflate via V's stdlib `compress` modules.
// ASPIRATIONAL: brotli (`br`) and zstd are not in V's stdlib — bind the C
//   libraries (libbrotlienc, libzstd). The negotiation logic below already
//   accounts for them; only the encoders are missing.
//
// CORRECTNESS NOTES
//   - Only compress when it pays: skip tiny bodies and already-compressed types
//     (images, video, zip). Compressing a 200-byte JSON wastes CPU.
//   - `Vary: Accept-Encoding` is mandatory so caches don't serve a gzipped body
//     to a client that can't decode it.
//   - Quality values (`gzip;q=0`) can DISABLE an encoding — respect them.
import http_server
import http_server.http1_1.request_parser
import compress.gzip
import strings

const min_compress_size = 256

// Pick the best encoding we both support and the client accepts.
// Preference order: br > zstd > gzip > identity. (br/zstd encode = aspirational.)
fn negotiate_encoding(accept string) string {
	a := accept.to_lower()
	// A real impl parses q-values; this shows the selection shape.
	if a.contains('br') {
		return 'br' // aspirational encoder
	}
	if a.contains('zstd') {
		return 'zstd' // aspirational encoder
	}
	if a.contains('gzip') {
		return 'gzip' // works today
	}
	return 'identity'
}

fn compressible(content_type string) bool {
	ct := content_type.to_lower()
	return ct.starts_with('text/') || ct.contains('json') || ct.contains('javascript')
		|| ct.contains('xml') || ct.contains('svg')
}

fn build_response(content_type string, body []u8, encoding string) []u8 {
	mut out_body := body.clone()
	mut enc_header := ''

	if body.len >= min_compress_size && compressible(content_type) {
		match encoding {
			'gzip' {
				out_body = gzip.compress(body) or { body } // works today
				enc_header = 'gzip'
			}
			'br' {
				// out_body = brotli.compress(body)   // aspirational: bind libbrotlienc
				enc_header = ''
			}
			'zstd' {
				// out_body = zstd.compress(body)     // aspirational: bind libzstd
				enc_header = ''
			}
			else {}
		}
	}

	mut sb := strings.new_builder(128 + out_body.len)
	sb.write_string('HTTP/1.1 200 OK\r\n')
	sb.write_string('Content-Type: ${content_type}\r\n')
	sb.write_string('Content-Length: ${out_body.len}\r\n')
	sb.write_string('Vary: Accept-Encoding\r\n') // mandatory for caches
	if enc_header != '' {
		sb.write_string('Content-Encoding: ${enc_header}\r\n')
	}
	sb.write_string('Connection: keep-alive\r\n\r\n')
	sb.write(out_body) or {}
	return sb
}

fn handle(req_buffer []u8, _ int) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	accept := if s := req.get_header_value_slice('Accept-Encoding') {
		s.to_string(req.buffer)
	} else {
		''
	}
	encoding := negotiate_encoding(accept)

	// The application just makes bytes. Compression happens after.
	body := ('{"message":"this body is large enough to be worth compressing",' +
		'"items":[1,2,3,4,5,6,7,8,9,10],"note":"repeated text compresses well ' +
		'repeated text compresses well repeated text compresses well"}').bytes()

	return build_response('application/json', body, encoding)
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
	println('Compression demo on http://localhost:3000/  (try: curl --compressed -v localhost:3000)')
	server.run()
}
