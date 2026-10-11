// v -d vanilla_tls run examples/https/src
// curl --cacert certs/cert.pem https://localhost:8443/
module main

// https — an HTTPS server. The handler is the same as for plain HTTP: TLS
// lives in the server's epoll worker (the handshake, record I/O, kTLS), so
// ServerConfig.tls_config is the only difference. Needs Mbed TLS 4 and the
// `-d vanilla_tls` build flag; Linux epoll only (new_server refuses TLS on
// every other backend).
import os
import core
import server
import tls
import http1_1.router

const https_port = 8443

const hello_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, HTTPS!'
const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
const root_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
// HEAD gets the GET headers, Content-Length included, and no body
// (RFC 9110 §9.3.2).
const hello_head_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\n'

// route answers GET and HEAD on `/`, 405 for any other method there, and 404
// for every other path. It reads only the request line (http1_1/router) and
// appends const responses: no allocation per request.
fn route(req_buffer []u8, mut out []u8, _ int, _ voidptr, mut _ core.EventLoop) core.Step {
	mut path := router.path(req_buffer)
	// `/` is one empty segment.
	if path.next() != '' || !path.done() {
		core.append_str(mut out, not_found_response)
		return .done
	}
	match router.method(req_buffer) {
		.get { core.append_str(mut out, hello_response) }
		.head { core.append_str(mut out, hello_head_response) }
		else { core.append_str(mut out, root_405) }
	}
	return .done
}

// load_tls builds the server's TLS config. With HTTPS_CERT and HTTPS_KEY set
// (paths to a PEM certificate chain and its PEM key, e.g. from Let's Encrypt)
// it loads them. Otherwise it issues a self-signed certificate for localhost,
// 127.0.0.1 and ::1, kept in `cert_dir` (cert.pem, key.pem): later runs load
// it again, so a client that trusts certs/cert.pem keeps working across
// restarts.
fn load_tls(cert_dir string) !&tls.Config {
	cert_path := os.getenv('HTTPS_CERT')
	key_path := os.getenv('HTTPS_KEY')
	if cert_path == '' && key_path == '' {
		return tls.new_self_signed(persist_dir: cert_dir)
	}
	if cert_path == '' || key_path == '' {
		return error('set both HTTPS_CERT and HTTPS_KEY, or neither')
	}
	return tls.new_from_pem(os.read_bytes(cert_path)!, os.read_bytes(key_path)!)
}

fn main() {
	cfg := load_tls('certs') or {
		// Also what a build without `-d vanilla_tls` reports.
		eprintln('https: ${err}')
		exit(1)
	}
	mut srv := server.new_server(server.ServerConfig{
		port:       https_port
		handler:    route
		tls_config: cfg
		limits:     server.Limits{
			// The first request's read deadline starts at accept, so it also
			// bounds the handshake: a client that connects and never finishes
			// it is closed after 10 s.
			read_timeout_ms:  10_000
			write_timeout_ms: 30_000 // a parked response must drain within 30 s
			idle_timeout_ms:  75_000 // keep-alive wait for the next request
		}
	}) or {
		eprintln('https: ${err}')
		exit(1)
	}
	srv.run()
}
