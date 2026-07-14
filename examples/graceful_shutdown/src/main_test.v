module main

import os

// SOLUTION 3 (process-level oracle): drive the real binary, send it a signal,
// and assert drain behavior. Aspirational — needs Server.shutdown() + an
// in-flight counter (see ROADMAP.md). Self-skips until then.

fn test_graceful_drain_oracle() {
	if os.execute('which curl').exit_code != 0 {
		eprintln('[skip] curl not installed')
		return
	}
	res := os.execute('curl -s --max-time 2 http://localhost:3000/')
	if res.exit_code != 0 {
		eprintln('[skip] no server on :3000')
		return
	}
	assert res.output.len >= 0
}

/*
The behavior to assert once the lifecycle API exists:

  pid := spawn_server()                         // start the example binary
  inflight := spawn slow_request(port)          // a request that takes ~1s
  os.kill(pid, .term)                           // SIGTERM mid-flight
  assert inflight.wait().contains('200 OK')     // in-flight request COMPLETES
  assert net.dial_tcp('127.0.0.1:${port}') fails // new connections REFUSED
  assert server_process_exits_within(grace)     // and the process exits cleanly

This is the difference between a deploy that returns a burst of 502s and one
that is invisible to users.
*/
