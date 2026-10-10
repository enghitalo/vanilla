module main

import core
import http1_1.request_parser
import http1_1.response

fn get(target string) []u8 {
	return 'GET ${target} HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
}

// Routing compares the path in place, without its query string. It used to be
// a substring search over a copy of the whole request, so `/dbx` and a header
// holding ` /db` both reached the pool.
fn test_route_is_matches_the_db_path_only() {
	for target, want in {
		'/db':       true
		'/db?x=1':   true
		'/dbx':      false
		'/x/db':     false
		'/x?q= /db': false
		'/':         false
	} {
		req := request_parser.decode_http_request(get(target)) or { panic(err) }
		assert route_is(req, '/db') == want, target
	}
}

// Every path but /db answers synchronously and never touches the pool, so
// worker_state can be nil here.
fn test_handler_answers_other_paths_without_the_pool() {
	mut event_loop := core.EventLoop{}
	for target in ['/', '/dbx', '/x/db'] {
		mut out := []u8{}
		step := handler(get(target), mut out, -1, unsafe { nil }, mut event_loop)
		assert step == .done, target
		assert out.bytestr() == resp_ok, target
	}
	mut out := []u8{}
	step := handler('GET\r\n\r\n'.bytes(), mut out, -1, unsafe { nil }, mut event_loop)
	assert step == .close
	assert out == response.tiny_bad_request_response
}
