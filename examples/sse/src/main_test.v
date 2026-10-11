module main

// Handler-state tests without a socket: the routes, the broadcast endpoint and
// malformed input. Subscribing (a registered connection, NO per-client thread)
// is tested in registry_nix_test.v; the real push fan-out is proven in
// server_end_to_end_test.v.
import core

// serve adapts the raw-handler contract (writes into a caller-owned buffer) to
// the return-a-string shape the assertions expect, alongside the handler's
// Step. Callers pass their own Clients so they can inspect subscriber state
// afterwards. fd -1 keeps any accidental send() harmless (EBADF), never a
// write to a real descriptor.
fn serve(req string, mut clients Clients) (string, core.Step) {
	mut out := []u8{}
	step := handle(req.bytes(), -1, mut out, mut clients)
	return out.bytestr(), step
}

fn test_broadcast_endpoint_accepts() {
	mut clients := Clients{} // empty set: no real fds to write to
	out, step := serve('POST /broadcast HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello', mut clients)
	assert step == .done
	assert out == ok_response // the event framed in `out` was rolled back
}

// The event is framed at the end of `out` and rolled back: a response already
// in the buffer (pipelined) is left as it was, followed by this one's.
fn test_broadcast_keeps_earlier_responses_in_out() {
	mut clients := Clients{}
	mut out := ok_response.bytes()
	step := handle('POST /broadcast HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello'.bytes(), -1, mut
		out, mut clients)
	assert step == .done
	assert out.bytestr() == ok_response + ok_response
}

fn test_broadcast_empty_body_is_ok() {
	// exercises the body.len == 0 guard: `data: \n\n` is still a valid SSE event
	mut clients := Clients{}
	out, step := serve('POST /broadcast HTTP/1.1\r\nContent-Length: 0\r\n\r\n', mut clients)
	assert step == .done
	assert out.contains('200 OK')
}

fn test_unknown_route_is_bad_request() {
	mut clients := Clients{}
	out, step := serve('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n', mut clients)
	assert step == .done
	assert out.contains('400')
}

fn test_malformed_request_errors() {
	mut clients := Clients{}
	// not even a request line — decode_into must reject it
	out1, step1 := serve('garbage', mut clients)
	assert step1 == .close, 'garbage input must close, not be routed'
	assert out1.contains('400')
	// truncated head: request line parses, but the header block never terminates
	out2, step2 := serve('GET /events HTTP/1.1\r\nHost: x', mut clients)
	assert step2 == .close, 'truncated request must close, not be routed'
	assert out2.contains('400')
	assert clients.snapshot().len == 0 // nothing was registered along the way
}

// POST /broadcast, the 400s and the malformed close run 20k times through one
// reused `out`, as a worker would serve them; the collector's lifetime
// allocation counter must not move. (Under `-gc none`, vanilla's production
// build, the same allocation would be a permanent leak.) A broadcast to a
// live subscriber is measured in registry_nix_test.v.
fn test_serving_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'POST /broadcast HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello',
			'POST /broadcast HTTP/1.1\r\nContent-Length: 0\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n',
			'garbage',
		].map(it.bytes())
		mut clients := Clients{}
		mut out := []u8{cap: 4096}
		for r in reqs { // warm-up: `out` reaches its high-water mark
			unsafe {
				out.len = 0
			}
			handle(r, -1, mut out, mut clients)
		}
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle(r, -1, mut out, mut clients)
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'serving allocated ${grown} bytes over ${rounds * reqs.len} requests'
	}
}

// Real push fan-out (N live streams → POST /broadcast → all receive) is proven
// end to end in server_end_to_end_test.v, on vtest (docs/VTEST.md).
