module main

import core
import http1_1.response
import compress.brotli
import compress.gzip
import compress.zstd

// SOLUTION: pure negotiation + round-trip + raw-request E2E (BEST_PRACTICES §9).
// pick_encoding is pure over raw bytes; each precompressed const response is
// verified with a ROUND-TRIP oracle: split it, decompress the body, assert we
// got the original demo_body back. Handlers are pure, so the E2E test feeds
// raw request bytes straight to handle() — no listening socket required.

// pick adapts pick_encoding's offset-based signature for test readability.
fn pick(accept string, brotli_ok bool) Encoding {
	return pick_encoding(accept.bytes(), 0, accept.len, brotli_ok)
}

fn test_pick_preference_order() {
	assert pick('gzip, deflate', true) == .gzip
	assert pick('br, gzip', true) == .br // br preferred when offered
	assert pick('zstd, gzip', true) == .zstd // zstd beats gzip
	assert pick('gzip, deflate, br, zstd', true) == .br // what browsers send
	assert pick('gzip;q=1, br', true) == .br // `;` ends the coding
	assert pick('deflate', true) == .identity // nothing we have
	assert pick('identity', true) == .identity
	assert pick('', true) == .identity // an empty value: no coding wanted
	assert pick(' , ,gzip,,', true) == .gzip // empty elements are skipped
}

fn test_pick_q_zero_refuses() {
	// RFC 9110 §12.4.2: q=0 means "not acceptable" (§12.5.3).
	assert pick('gzip;q=0', true) == .identity
	assert pick('gzip;q=0.000', true) == .identity
	assert pick('gzip;q=0.', true) == .identity // `0.` is a valid qvalue
	assert pick('br;q=0, gzip', true) == .gzip
	assert pick('br;q=0, zstd;q=0, gzip;q=0', true) == .identity
}

fn test_pick_highest_q_wins() {
	assert pick('br;q=0.5, gzip', true) == .gzip
	assert pick('gzip;q=0.8, zstd;q=0.9', true) == .zstd
	assert pick('br;q=0.001, gzip;q=0.002', true) == .gzip
	assert pick('zstd;q=0.999, gzip;q=1.000', true) == .gzip
}

fn test_pick_ties_follow_server_order() {
	assert pick('gzip;q=0.5, zstd;q=0.5, br;q=0.5', true) == .br
	assert pick('gzip, zstd', true) == .zstd
	assert pick('gzip;q=0.7, zstd;q=0.70', true) == .zstd // same q, spelt differently
}

fn test_pick_star() {
	assert pick('*', true) == .br // any coding: server order decides
	assert pick('*', false) == .zstd
	assert pick('*;q=0.5, gzip', true) == .gzip // gzip 1 beats br/zstd at 0.5 via `*`
	assert pick('br;q=0, zstd;q=0, *', true) == .gzip // `*` covers only unlisted codings
	assert pick('*, gzip;q=0', false) == .zstd
	// `*;q=0` refuses every unlisted coding, identity included: 406...
	assert pick('*;q=0', true) == .not_acceptable
	assert pick('*;q=0', false) == .not_acceptable
	// ...unless identity has its own entry, or a listed coding is acceptable.
	assert pick('*;q=0, identity', true) == .identity
	assert pick('*;q=0, identity;q=0.5', true) == .identity
	assert pick('*;q=0, gzip', true) == .gzip
}

fn test_pick_identity_refused() {
	assert pick('identity;q=0', true) == .not_acceptable
	assert pick('identity;q=0, gzip', true) == .gzip // a usable coding still wins
	assert pick('identity;q=0, deflate', true) == .not_acceptable // deflate we don't have
	assert pick('identity;q=0, *', true) == .br
	assert pick('identity;q=0, *;q=0', true) == .not_acceptable
}

fn test_pick_x_gzip_alias() {
	// RFC 9110 §8.4.1.3: x-gzip is gzip.
	assert pick('x-gzip', true) == .gzip
	assert pick('X-Gzip', true) == .gzip
	assert pick('br;q=0.5, x-gzip', true) == .gzip
	assert pick('gzip, x-gzip;q=0', true) == .identity // one coding: its lowest q
}

fn test_pick_case_insensitive() {
	// Codings and the parameter name are case-insensitive (§8.4.1, §5.6.6).
	assert pick('GZIP;Q=1', true) == .gzip
	assert pick('GZIP;Q=0', true) == .identity
	assert pick('Br', true) == .br
	assert pick('ZsTd', true) == .zstd
	assert pick('IDENTITY;Q=0', true) == .not_acceptable
}

fn test_pick_invalid_qvalue_ignored() {
	// An element whose qvalue does not parse (§12.4.2) is ignored: these would
	// all accept gzip if the bad weight were read as 1 or clamped.
	assert pick('gzip;q=2', true) == .identity
	assert pick('gzip;q=0.1234', true) == .identity
	assert pick('gzip;q=', true) == .identity
	assert pick('gzip;q=1.5', true) == .identity
	assert pick('gzip;q=.5', true) == .identity
	assert pick('gzip;q=0.5x', true) == .identity
	assert pick('gzip;q="1"', true) == .identity
	assert pick('gzip;q', true) == .identity
	assert pick('gzip x', true) == .identity // junk after the coding
	// Only the bad element drops out, and an ignored refusal refuses nothing:
	assert pick('br;q=2, gzip', true) == .gzip
	assert pick('identity;q=00', true) == .identity
	assert pick('identity;q=00, *;q=0', true) == .not_acceptable
}

fn test_pick_ows() {
	// weight = OWS ";" OWS "q=" qvalue: whitespace around `;` is fine...
	assert pick('gzip ; q=0', true) == .identity
	assert pick('gzip\t;\tq=0, zstd', true) == .zstd
	assert pick('br ;q=0.4 , gzip; q=0.5 ', true) == .gzip
	assert pick('identity ; q=0', true) == .not_acceptable
	// ...but not around `=` (§5.6.6): `q = 0` does not parse, so the element
	// is ignored — neither a refusal nor an acceptance.
	assert pick('gzip ; q = 0', true) == .identity
	assert pick('gzip;q =1', true) == .identity
	assert pick('gzip;q= 1', true) == .identity
	assert pick('identity ; q = 0', true) == .identity
}

fn test_pick_whole_tokens_only() {
	// pack200-gzip is a DIFFERENT registered coding — substring matching would
	// serve gzip to a client that never accepted it (RFC 9110 §12.5.3).
	assert pick('pack200-gzip', true) == .identity
	assert pick('pack200-gzip, gzip', true) == .gzip
	assert pick('gzip2, xbr, zstd-x, x-gzip-y', true) == .identity
}

fn test_pick_duplicates_keep_lowest_q() {
	// A refusal anywhere wins, whatever the order.
	assert pick('gzip, gzip;q=0', true) == .identity
	assert pick('gzip;q=0, gzip', true) == .identity
	assert pick('br;q=0.9, gzip;q=0.5, br;q=0.1', true) == .gzip
	assert pick('gzip;q=1;q=0', true) == .identity // two weights in one element
	assert pick('identity, identity;q=0', true) == .not_acceptable
	assert pick('*, *;q=0', true) == .not_acceptable
}

fn test_pick_other_parameters_skipped() {
	// Accept-Encoding defines no parameter but q: others are skipped.
	assert pick('gzip;level=9', true) == .gzip
	assert pick('gzip;level=9;q=0', true) == .identity
	assert pick('gzip;q=0;level=9', true) == .identity
	assert pick('gzip;;q=0', true) == .identity // an empty parameter
}

fn test_pick_without_brotli() {
	// libbrotli missing at runtime: br drops out, never fail the request.
	assert pick('br, gzip', false) == .gzip
	assert pick('br, zstd, gzip', false) == .zstd
	assert pick('br', false) == .identity
	assert pick('br;q=1, gzip;q=0.1', false) == .gzip
	// br is all the client takes besides identity, which it refused: 406
	// without libbrotli, br with it.
	assert pick('br, identity;q=0', false) == .not_acceptable
	assert pick('br, identity;q=0', true) == .br
}

fn test_qvalue_grammar() {
	// qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] ), in thousandths.
	qv := fn (s string) int {
		return qvalue(s.bytes(), 0, s.len)
	}
	assert qv('0') == 0
	assert qv('0.') == 0
	assert qv('0.5') == 500
	assert qv('0.05') == 50
	assert qv('0.005') == 5
	assert qv('0.999') == 999
	assert qv('1') == 1000
	assert qv('1.') == 1000
	assert qv('1.0') == 1000
	assert qv('1.000') == 1000
	for bad in ['', '2', '1.001', '1.5', '0.1234', '.5', '01', '00', '-0', '0,5', '0.5x', ' 0',
		'q'] {
		assert qv(bad) == -1, bad
	}
}

fn test_pick_respects_offsets() {
	// The value is addressed by offsets into the request buffer: bytes before
	// `start` and after `start + len` must never leak into the parse.
	buf := 'br, gzip;q=0.5'.bytes()
	assert pick_encoding(buf, 0, 2, true) == .br // `br`
	assert pick_encoding(buf, 4, 4, true) == .gzip // `gzip`: its weight lies outside
	assert pick_encoding(buf, 4, 9, true) == .identity // `gzip;q=0.`: weight 0
	assert pick_encoding(buf, 4, 10, true) == .gzip // `gzip;q=0.5`
	assert pick_encoding(buf, 4, 3, true) == .identity // `gzi`: cut by the window end
	assert pick_encoding(buf, 5, 3, true) == .identity // `zip`
}

// Split a serialized response into (headers, body) at the CRLFCRLF terminator.
fn split_response(resp []u8) (string, []u8) {
	s := resp.bytestr()
	idx := s.index('\r\n\r\n') or {
		assert false, 'response has no header terminator'
		return s, []u8{}
	}
	return s[..idx], resp[idx + 4..]
}

fn test_identity_response() {
	headers, body := split_response(resp_identity)
	assert !headers.contains('Content-Encoding') // identity: header omitted
	assert headers.contains('Vary: Accept-Encoding') // mandatory for caches
	assert headers.contains('Content-Length: ${body.len}')
	assert body == demo_body
}

fn test_gzip_response_roundtrip() ! {
	headers, body := split_response(resp_gzip)
	assert headers.contains('Content-Encoding: gzip')
	assert headers.contains('Vary: Accept-Encoding')
	assert headers.contains('Content-Length: ${body.len}')
	assert body.len < demo_body.len // it actually compressed
	assert gzip.decompress(body)! == demo_body
}

fn test_zstd_response_roundtrip() ! {
	headers, body := split_response(resp_zstd)
	assert headers.contains('Content-Encoding: zstd')
	assert headers.contains('Vary: Accept-Encoding')
	assert headers.contains('Content-Length: ${body.len}')
	assert body.len < demo_body.len
	assert zstd.decompress(body)! == demo_body
}

fn test_brotli_response_roundtrip() ! {
	if resp_br.len == 0 {
		println('skipping: system libbrotli not installed')
		return
	}
	headers, body := split_response(resp_br)
	assert headers.contains('Content-Encoding: br')
	assert headers.contains('Vary: Accept-Encoding')
	assert headers.contains('Content-Length: ${body.len}')
	assert body.len < demo_body.len
	assert brotli.decompress(body)! == demo_body
}

fn test_not_acceptable_response() {
	assert resp_406.starts_with('HTTP/1.1 406 Not Acceptable\r\n')
	assert resp_406.contains('\r\nContent-Length: 0\r\n') // no body
	assert resp_406.contains('\r\nVary: Accept-Encoding\r\n') // it depends on the header
	assert resp_406.contains('\r\nConnection: keep-alive\r\n')
	assert resp_406.ends_with('\r\n\r\n')
}

// serve adapts the unified handler contract (writes into a caller-owned
// buffer) to the return-a-buffer shape the assertions expect. Every
// well-formed request, the 406 included, keeps the connection (.done).
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle(req, mut out, -1, unsafe { nil }, mut event_loop) == .done
	return out
}

fn test_handle_raw_requests() {
	assert serve('GET / HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n'.bytes()) == resp_gzip
	// Header NAMES are case-insensitive too (RFC 9110 §5.1).
	assert serve('GET / HTTP/1.1\r\naccept-encoding: zstd\r\n\r\n'.bytes()) == resp_zstd
	assert serve('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) == resp_identity
	assert serve('GET / HTTP/1.1\r\nAccept-Encoding: pack200-gzip\r\n\r\n'.bytes()) == resp_identity
	assert serve('GET / HTTP/1.1\r\nAccept-Encoding:\r\n\r\n'.bytes()) == resp_identity
	assert serve('GET / HTTP/1.1\r\nAccept-Encoding: gzip;q=0\r\n\r\n'.bytes()) == resp_identity
	assert serve('GET / HTTP/1.1\r\nAccept-Encoding: zstd;q=0.5, gzip\r\n\r\n'.bytes()) == resp_gzip
	assert serve('GET / HTTP/1.1\r\nAccept-Encoding: identity;q=0\r\n\r\n'.bytes()) == resp_406.bytes()
	assert serve('GET / HTTP/1.1\r\nAccept-Encoding: *;q=0\r\n\r\n'.bytes()) == resp_406.bytes()
	if resp_br.len > 0 {
		assert serve('GET / HTTP/1.1\r\nAccept-Encoding: br, gzip\r\n\r\n'.bytes()) == resp_br
		assert serve('GET / HTTP/1.1\r\nAccept-Encoding: *\r\n\r\n'.bytes()) == resp_br
	}
}

// Every negotiation outcome runs 20k times through one reused buffer, as a
// worker would serve them; the collector's lifetime allocation counter must
// not move. (Under `-gc none`, vanilla's epoll build, an allocation here would
// be a permanent leak.) Well-formed requests only: decode_http_request boxes
// an error() for a malformed head, and that request closes the connection.
fn test_requests_allocate_nothing() {
	$if gcboehm ? {
		reqs := [
			'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, deflate, br, zstd\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br;q=0.5, zstd;q=0.9, gzip;q=0.8\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip;q=0\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: X-GZIP ; Q=1.000, br;level=9;q=0\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip;q=2, gzip ; q = 0, *;q=0.001\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: identity;q=0\r\n\r\n',
			'GET / HTTP/1.1\r\nHost: x\r\nAccept-Encoding: *;q=0, identity\r\n\r\n',
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		mut event_loop := core.EventLoop{}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle(r, mut out, -1, unsafe { nil }, mut event_loop)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle(r, mut out, -1, unsafe { nil }, mut event_loop)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'the handler allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

fn test_handle_malformed_requests() {
	// Malformed input gets the canned 400 appended and the connection closed
	// (return .close) — BEST_PRACTICES §9.
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle('garbage'.bytes(), mut out, -1, unsafe { nil }, mut event_loop) == .close
	assert out == response.tiny_bad_request_response
	// Truncated before the CRLFCRLF terminator.
	mut out2 := []u8{}
	mut event_loop2 := core.EventLoop{}
	assert handle('GET / HTTP/1.1\r\nHost: local'.bytes(), mut out2, -1, unsafe { nil }, mut
		event_loop2) == .close
	assert out2 == response.tiny_bad_request_response
}
