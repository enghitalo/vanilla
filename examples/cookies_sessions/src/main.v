module main

// Cookies + sessions — reference design.
//
// HTTP is stateless; sessions bolt state on via a cookie carrying an opaque,
// unguessable id that keys server-side state. The cookie itself holds NO
// secrets — just the id.
//
// SECURITY ATTRIBUTES (all mandatory for a session cookie):
//   HttpOnly             — JS cannot read it (blunts XSS token theft)
//   Secure               — only sent over HTTPS
//   SameSite=Lax/Strict  — not sent on cross-site requests (CSRF defense)
//   Path=/; Max-Age=...   — scope + lifetime
//   The id must come from a CSPRNG (crypto.rand), never a counter or timestamp.
//
// WORKS TODAY: cookie parsing + Set-Cookie are just headers; crypto.rand is
// stdlib. The only shared state is the session store (a mutex-guarded map here;
// Redis/db in production).

import http_server
import http_server.http1_1.request_parser
import sync
import crypto.rand
import encoding.hex

struct Session {
	user_id   string
	csrf_token string
}

struct Store {
mut:
	mu       &sync.RwMutex = sync.new_rwmutex()
	sessions map[string]Session
}

fn (mut s Store) create(user_id string) string {
	id := new_token()
	s.mu.lock()
	s.sessions[id] = Session{
		user_id:    user_id
		csrf_token: new_token()
	}
	s.mu.unlock()
	return id
}

fn (mut s Store) get(id string) ?Session {
	s.mu.rlock()
	defer { s.mu.runlock() }
	return s.sessions[id] or { return none }
}

// CSPRNG token — 32 bytes of entropy, hex-encoded. Never a predictable value.
fn new_token() string {
	buf := rand.bytes(32) or { panic('csprng unavailable') }
	return hex.encode(buf)
}

// Parse the Cookie header into key/value pairs. Format: "a=1; b=2".
fn parse_cookies(header string) map[string]string {
	mut out := map[string]string{}
	for pair in header.split('; ') {
		if eq := pair.index('=') {
			out[pair[..eq]] = pair[eq + 1..]
		}
	}
	return out
}

fn handle(req_buffer []u8, _ int, mut store Store) ![]u8 {
	req := request_parser.decode_http_request(req_buffer)!
	path := req.path.to_string(req.buffer)

	cookies := if c := req.get_header_value_slice('Cookie') {
		parse_cookies(c.to_string(req.buffer))
	} else {
		map[string]string{}
	}

	match path {
		'/login' {
			// (Authenticate first — see examples/auth.) Then mint a session.
			sid := store.create('user-42')
			// Note ALL the security attributes on the Set-Cookie.
			return ('HTTP/1.1 200 OK\r\n' +
				'Set-Cookie: sid=${sid}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400\r\n' +
				'Content-Length: 0\r\n\r\n').bytes()
		}
		'/me' {
			sid := cookies['sid'] or {
				return 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'.bytes()
			}
			sess := store.get(sid) or {
				return 'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n'.bytes()
			}
			body := '{"user":"${sess.user_id}"}'
			return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
		}
		'/logout' {
			// Expire the cookie (Max-Age=0) and drop the server-side session.
			return ('HTTP/1.1 200 OK\r\n' +
				'Set-Cookie: sid=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0\r\n' +
				'Content-Length: 0\r\n\r\n').bytes()
		}
		else {
			return 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'.bytes()
		}
	}
}

fn main() {
	mut store := &Store{}
	mut server := http_server.new_server(http_server.ServerConfig{
		port:            3000
		io_multiplexing: http_server.IOBackend.epoll
		request_handler: fn [mut store] (req_buffer []u8, fd int) ![]u8 {
			return handle(req_buffer, fd, mut store)
		}
	})!
	println('Cookies/sessions demo on http://localhost:3000/  (/login, /me, /logout)')
	server.run()
}
