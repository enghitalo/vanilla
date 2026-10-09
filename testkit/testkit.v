// testkit — raw-socket HTTP client helpers for end-to-end tests.
//
// V compiles every `_test.v` into its own binary and does not share test-only
// helpers across files, so these live in a normal importable module that any test
// (in `server` or an example `module main`) reuses. It depends only on
// `net`/`time` — never on `server` — so there is no import cycle. Every read
// has a per-read deadline so a stalled server fails the test fast instead of
// hanging.
//
// The tests bring the server up themselves: `spawn server.run()` on a thread and
// use ServerConfig.after_server_start (fired the instant the server is accepting)
// to drive the client workload / signal readiness. testkit only holds the read
// loops the stdlib lacks: `net` offers a single `read()` and a `\n`-framed
// `read_line()`, and `io.read_all` blocks forever on a keep-alive connection (no
// EOF) — none reads "until a marker / a byte count / a full Content-Length-framed
// message, bounded by a deadline". Connecting is just `net.dial_tcp` and counting
// occurrences is `string.count`, so those are used inline at the call sites rather
// than wrapped here. Tests that dial raw fds through `transport` instead of
// TcpConn use the fd_* family in fd_nix.c.v (same deadline discipline, raw
// poll(2) — still no vanilla imports).
module testkit

import net
import time

// read_until accumulates bytes from `c` (deadline per read) until `done(acc)` is
// true, the peer closes, or a read times out; returns everything read. The three
// public readers are thin predicates over this one loop.
fn read_until(mut c net.TcpConn, deadline_ms int, done fn (acc []u8) bool) []u8 {
	c.set_read_timeout(deadline_ms * time.millisecond)
	mut acc := []u8{}
	mut buf := []u8{len: 65536}
	for {
		nr := c.read(mut buf) or { break }
		if nr <= 0 {
			break
		}
		acc << buf[..nr]
		if done(acc) {
			break
		}
	}
	return acc
}

// read_until_count reads until `needle` has appeared `want` times (or the peer
// closes / a read times out); returns how many were seen.
pub fn read_until_count(mut c net.TcpConn, needle string, want int, deadline_ms int) int {
	acc := read_until(mut c, deadline_ms, fn [needle, want] (acc []u8) bool {
		return acc.bytestr().count(needle) >= want
	})
	return acc.bytestr().count(needle)
}

// read_full reads until at least `min_len` bytes accumulate; returns everything
// read. For verifying a full large body survived the send — a stalled peer yields
// a short read the caller's `assert acc.len >= min_len` fails fast on.
pub fn read_full(mut c net.TcpConn, min_len int, deadline_ms int) []u8 {
	return read_until(mut c, deadline_ms, fn [min_len] (acc []u8) bool {
		return acc.len >= min_len
	})
}

// read_response reads exactly one Content-Length-framed response (headers +
// declared body); a headers-only response completes at the blank line. NOT for
// chunked / open streams — use read_until_count there.
pub fn read_response(mut c net.TcpConn, deadline_ms int) []u8 {
	return read_until(mut c, deadline_ms, response_complete)
}

// response_complete reports whether `acc` holds a full Content-Length-framed
// response. Returns true (stop reading) once the framed message is complete OR the
// framing can't advance from a body header (headers-only ⇒ done at the blank line).
fn response_complete(acc []u8) bool {
	s := acc.bytestr()
	he := s.index('\r\n\r\n') or { return false } // headers not terminated yet
	cl_idx := s.index('Content-Length: ') or { return true } // no body to frame
	start := cl_idx + 'Content-Length: '.len
	end := s.index_after('\r\n', start) or { return false }
	cl := s[start..end].trim_space().int()
	return acc.len >= he + 4 + cl
}
