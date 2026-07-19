module main

import time
import core
import server
import vtest

// Size limits are enforced by the CORE (the read loop), not the handler — so
// the handler stays trivial (asserted below) and every limit is tested where
// it lives: end-to-end against a real server, on vtest (docs/VTEST.md). This
// file's earlier revision carried these e2e cases as an ASPIRATIONAL comment
// (they needed Limits + timeout support in the core); the support exists now,
// so the comment became the tests. The only clocks are the server's own
// Limits — vtest has none.

fn test_handler_is_trivial_200() {
	req := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789'.bytes()
	assert serve(req).bytestr().contains('200 OK')
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut event_loop := core.EventLoop{}
	assert handle(req, mut out, -1, unsafe { nil }, mut event_loop) == .done
	return out
}

// --- the limits, end-to-end (the CORE's work, driven through this example's
// own handler) ---------------------------------------------------------------

// Slowloris: a client that opens a connection and dribbles a partial request
// must be ENDED by the server's read_timeout reaper — never served a 200.
// then_eof means completion can ONLY come from the server's clock; the
// stopwatch MEASURES how long that took after the fact, it is not a deadline.
fn test_slowloris_reaped_by_read_timeout() ! {
	mut h := vtest.start(server.ServerConfig{
		handler: handle
		limits:  server.Limits{
			read_timeout_ms: 400
		}
	})!
	defer {
		h.stop()
	}
	sw := time.new_stopwatch()
	out := h.fire([
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: 'GET / HTTP/1.1\r\nX-Dribble: a'.bytes() // ...and then stall
					want: 0
				},
			]
			then_eof: true
		},
	])!
	elapsed := sw.elapsed().milliseconds()
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, 'read_timeout must end a stalled connection'
	assert !c.raw.bytestr().contains('200 OK'), 'a stalled partial request must not be served, got: ${c.raw.bytestr()}'
	assert elapsed < 1500, 'the reaper should fire around read_timeout_ms=400, took ${elapsed}ms'
}

// Header flood: a header block over max_header_bytes gets 431 and a close —
// the server stops buffering attacker bytes at the limit, long before the
// flood ends. The 431 bytes themselves are asserted only when they arrived:
// the server closes with part of the flood unread, so the kernel may RST and
// discard the response in flight — the hard contract is "no 200, ended".
fn test_header_flood_rejected() ! {
	mut flood := []u8{cap: 16 * 1024}
	flood << 'GET / HTTP/1.1\r\nHost: x\r\n'.bytes()
	for i := 0; flood.len < 12 * 1024; i++ {
		flood << 'X-Pad-'.bytes()
		flood << i.str().bytes() // test scaffolding — not request-serving code
		flood << ': aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n'.bytes()
	}
	// No terminating blank line: the flood is still "headers" when it trips.
	out := vtest.drive(server.ServerConfig{
		handler: handle
		limits:  server.Limits{
			max_header_bytes: 4 * 1024
			read_timeout_ms:  2000 // backstop so a regression fails instead of hanging
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: flood
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, 'an oversized header block must end in a server close'
	raw := c.raw.bytestr()
	assert !raw.contains('200'), 'an oversized header block must never reach the handler, got: ${raw}'
	if c.raw.len > 0 {
		assert raw.starts_with('HTTP/1.1 431'), 'expected the 431 rejection, got: ${raw}'
	}
}

// Oversized body: a Content-Length over max_body_bytes is rejected 413 from
// the DECLARED length alone — the client here never sends a single body byte,
// so the response arriving at all proves the server did not wait for (or
// buffer) attacker-controlled body bytes first.
fn test_oversized_body_rejected_before_buffering() ! {
	out := vtest.drive(server.ServerConfig{
		handler: handle
		limits:  server.Limits{
			max_body_bytes:  1024
			read_timeout_ms: 2000 // backstop so a regression fails instead of hanging
		}
	}, [
		vtest.Script{
			rounds:   [
				vtest.Round{
					send: 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n'.bytes()
					want: 0
				},
			]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.eof, 'an over-limit Content-Length must end in a server close'
	raw := c.raw.bytestr()
	assert !raw.contains('200'), 'an over-limit body must never reach the handler, got: ${raw}'
	assert raw.starts_with('HTTP/1.1 413'), 'expected 413 from the Content-Length alone (no body was ever sent), got: ${raw}'
}
