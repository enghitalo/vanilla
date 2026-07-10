module main

import http_server.core

// Size limits are now enforced by the CORE (the read loop), not the handler —
// so the handler stays trivial and the limit behavior is tested where it lives:
// `frame_request_length_lim` in request_parser_test.v (413 from Content-Length
// before buffering; 431 for oversized header blocks). This file just confirms
// the handler is a plain 200 and the timeout protections still to come.

fn test_handler_is_trivial_200() {
	req := 'POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n0123456789'.bytes()
	assert serve(req).bytestr().contains('200 OK')
}

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-buffer shape the assertions expect.
fn serve(req []u8) []u8 {
	mut out := []u8{}
	mut worker := core.Worker{}
	assert handle(req, mut out, mut worker) == .done
	return out
}

/*
ASPIRATIONAL — Solution 2 (programmable raw client) + Solution 4 (fake clock).
These verify CORE behavior that no handler test can reach. Requires the proposed
testkit and the `Limits`/timeout support in the core (see ROADMAP.md):

  fn test_slowloris_times_out() {
      mut c := testkit.dial(port)
      c.send('GET / HTTP/1.1\r\n')        // partial request line...
      fake_clock.advance(read_header_timeout + 1)   // ...and then stall
      assert c.read_response().contains('408 Request Timeout')
  }

  fn test_header_flood_rejected() {
      mut c := testkit.dial(port)
      c.send('GET / HTTP/1.1\r\n')
      for _ in 0 .. 100_000 { c.send('X-Pad: ' + 'a'.repeat(100) + '\r\n') }
      assert c.read_response().contains('431')   // before buffering it all
  }

  fn test_oversized_body_rejected_before_buffering() {
      // CORE must 413 from the Content-Length alone, WITHOUT reading the body —
      // proving it doesn't buffer attacker-controlled bytes first.
  }
*/
