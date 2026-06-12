module main

// Transfer-Encoding: chunked — reference design (request decode + response stream).
//
// Chunked encoding is how HTTP/1.1 sends a body of UNKNOWN length: a series of
// `<hex-size>\r\n<bytes>\r\n` chunks terminated by a `0\r\n\r\n`. It is the
// streaming primitive of HTTP/1.1 — large downloads, live logs, generated
// output you don't want to buffer entirely before sending.
//
// TWO DIRECTIONS, TWO STATES:
//
// 1. DECODING a chunked REQUEST body  — ASPIRATIONAL (core work).
//    `request.read_request` neither honors Content-Length nor decodes chunked
//    bodies. The core must, before calling the handler, detect
//    `Transfer-Encoding: chunked` and reassemble the body by consuming chunks
//    until the terminating zero-chunk. The pure decoder is shown below.
//    SECURITY: a request with BOTH Content-Length and Transfer-Encoding must be
//    rejected (or TE wins, CL stripped) — the ambiguity is the classic request
//    smuggling vector.
//
// 2. PRODUCING a chunked RESPONSE  — PARTLY POSSIBLE today, fully pure with a
//    streaming write API. Today a handler returns one []u8, so you'd build the
//    whole chunked body in memory (defeating the point). The pure design gives
//    the handler a writer it can push chunks into, backed by the fd and
//    EPOLLOUT for backpressure (see examples/request_limits for the write path).
import http_server
import http_server.http1_1.request_parser
import strings

// ---- request side: decode a chunked body (pure function over bytes) --------
//
// ASPIRATIONAL: the core would call this to produce the real body before
// dispatch. Shown as a standalone, testable function.
fn decode_chunked(buf []u8) ![]u8 {
	mut out := []u8{}
	mut pos := 0
	for pos < buf.len {
		// chunk size line: hex digits up to CRLF
		mut line_end := pos
		for line_end < buf.len && buf[line_end] != 13 { // 13 = CR (escaped runes are broken in this toolchain)
			line_end++
		}
		size_str := buf[pos..line_end].bytestr()
		size := ('0x' + size_str.trim_space()).int() // hex chunk size
		pos = line_end + 2 // skip CRLF
		if size == 0 {
			break // terminating chunk (trailers, if any, would follow)
		}
		if pos + size > buf.len {
			return error('truncated chunk')
		}
		out << buf[pos..pos + size]
		pos += size + 2 // skip chunk data + trailing CRLF
	}
	return out
}

// ---- response side: frame bytes as one or more chunks ----------------------
//
// In the pure streaming design these would be written to the fd as they are
// produced. Here we frame them into a buffer to illustrate the wire format.
fn chunk(data string) string {
	return '${data.len:x}\r\n${data}\r\n'
}

fn handle(req_buffer []u8, _ int, mut out []u8) ! {
	req := request_parser.decode_http_request(req_buffer)!

	// If the request arrived chunked (once the core reassembles it), the body
	// is already decoded plaintext by dispatch time — handler stays simple.
	_ := req

	// Stream a response of unknown length. No Content-Length; chunked framing.
	mut sb := strings.new_builder(256)
	sb.write_string('HTTP/1.1 200 OK\r\n')
	sb.write_string('Content-Type: text/plain\r\n')
	sb.write_string('Transfer-Encoding: chunked\r\n')
	sb.write_string('Connection: keep-alive\r\n\r\n')
	// In the pure design each of these is a separate write to the socket,
	// flushed as it's generated — here concatenated to show the framing.
	sb.write_string(chunk('first piece\n'))
	sb.write_string(chunk('second piece\n'))
	sb.write_string(chunk('third piece\n'))
	sb.write_string('0\r\n\r\n') // terminating chunk
	out << sb
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
	println('Chunked streaming demo on http://localhost:3000/')
	server.run()
}
