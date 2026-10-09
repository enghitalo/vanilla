module main

import server
import core
import vtest

// SSE fan-out end to end, on vtest (docs/VTEST.md) — the test main_test.v could
// only sketch: 8 subscribers open real streams (GET /events answers headers and
// stays open in the reactor), one POST /broadcast fans the event out to every
// registered fd, and wait() blocks until each stream received it. Ordering is
// completion-based (fire → fire → wait), no sleeps, no timeouts.

const subscribe_req = 'GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
const broadcast_req = 'POST /broadcast HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello'.bytes()
const event_marker = 'data: hello\n\n'
const n_subscribers = 8

fn test_sse_fanout_end_to_end() ! {
	// Same wiring as main(): one shared &Clients registry captured by the
	// adapter closure (the reference field is shared across closure copies).
	mut clients := &Clients{}
	mut h := vtest.start(server.ServerConfig{
		handler: fn [mut clients] (req_buffer []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
			return handle(req_buffer, client_fd, mut out, mut clients)
		}
	})!
	defer {
		h.stop()
	}

	// Subscribe: each round completes when the SSE head arrived. handle()
	// registers the fd BEFORE the core sends the head, so once headers_seen
	// holds the broadcast below cannot miss a subscriber.
	subs := h.fire(vtest.repeat(n_subscribers, vtest.Script{
		rounds: [vtest.Round{
			send:  subscribe_req
			until: vtest.headers_seen
		}]
	}))!
	for c in subs.conns {
		assert c.connect_err == '', c.connect_err
		assert c.raw.bytestr().contains('text/event-stream')
	}

	// Publish once. broadcast() runs synchronously inside the handler, so the
	// 200 ack implies every registered fd was written.
	ack := h.fire([
		vtest.Script{
			rounds: [vtest.Round{
				send: broadcast_req
			}]
		},
	])!
	assert ack.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200')

	// Every stream must receive `data: hello\n\n`; a stream the server closed
	// before the event arrived would surface as unmet.
	got := h.wait(subs.group, vtest.count(event_marker, 1))!
	for i, c in got.conns {
		assert !c.unmet, 'subscriber ${i} lost its stream before the event'
		assert c.raw.bytestr().contains(event_marker), 'subscriber ${i} got: ${c.raw.bytestr()}'
	}
}
