module main

import time
import server
import vtest

// The lifecycle this example demos, asserted for real on vtest (docs/VTEST.md).
// This file predates Server.shutdown() — it was a self-skipping curl probe with
// the wanted behaviour written out as a comment. The API exists now, so the
// comment became the test:
//   1. the example's handler serves while the server is up;
//   2. shutdown() returns promptly on an idle server (the drain is PRECISE —
//      per-worker in-flight counters, not the full grace);
//   3. after shutdown, new connections are refused.
// The signal wiring in main() is the one part not covered here: it is exactly
// `os.signal_opt(.term, ...) -> srv.shutdown(2000)`, and driving a real
// SIGTERM needs a spawned process — the process-level oracle stays in the
// example's README narrative.

const gs_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()

fn test_graceful_drain() ! {
	mut h := vtest.start(server.ServerConfig{ handler: handle })!
	defer {
		h.stop()
	}
	// 1. Served while up.
	first := h.fire([
		vtest.Script{
			rounds: [
				vtest.Round{
					send: gs_req
				},
			]
		},
	])!
	assert first.conns[0].connect_err == '', first.conns[0].connect_err
	assert first.conns[0].frames.len == 1
	assert first.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200')

	// 2. Idle shutdown returns in ~ms; the 2s grace is only the cap. The
	// stopwatch MEASURES the drain after it completed — it is not a deadline.
	sw := time.new_stopwatch()
	h.server_ref().shutdown(2000)
	elapsed := sw.elapsed().milliseconds()
	assert elapsed < 1000, 'idle shutdown should be prompt (precise drain), took ${elapsed}ms'

	// 3. Every listener is closed: fresh connects must be refused — a connect
	// error, or an immediate close with no response ever arriving.
	probes := h.fire(vtest.repeat(4, vtest.Script{
		rounds:   [
			vtest.Round{
				send: gs_req
				want: 0
			},
		]
		then_eof: true
	}))!
	for i, c in probes.conns {
		refused := c.connect_err != '' || (c.eof && c.frames.len == 0)
		assert refused, 'post-shutdown connect ${i} must be refused, got ${c.frames.len} responses'
	}
}
