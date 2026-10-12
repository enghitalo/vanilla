module main

// Handler and wake-fn tests without a socket: the routes, the broadcast
// endpoint, malformed input, the subscribe path through stand-in backend
// hooks, and the bytes sse_wake writes. The real streams (fan-out across
// workers, heartbeats, departures, shutdown) are server_end_to_end_test.v.
import core

// Recorded is what the stand-in hooks saw, found through EventLoop.reactor,
// which a test loop never hands to a real backend.
struct Recorded {
mut:
	sub_state voidptr
	wake_ms   int
	posts     int
}

fn record_subscribe(mut el core.EventLoop, wake_fn core.WakeFn, sub_state voidptr) core.ConnHandle {
	mut r := unsafe { &Recorded(el.reactor) }
	r.sub_state = sub_state
	return core.ConnHandle{
		fd: 7
	}
}

fn record_wake_after(mut el core.EventLoop, ms int) bool {
	mut r := unsafe { &Recorded(el.reactor) }
	r.wake_ms = ms
	return true
}

// counting_post stands in for a mailbox: it counts the posts made to it.
fn counting_post(mbox voidptr, fd int, epoch u64, tag u64, data []u8) core.PostResult {
	mut r := unsafe { &Recorded(mbox) }
	r.posts++
	return .ok
}

// recording_loop is an event loop whose subscribe and wake_after are recorded in `r`.
fn recording_loop(r &Recorded) core.EventLoop {
	return core.EventLoop{
		reactor:         voidptr(r)
		subscribe_hook:  record_subscribe
		wake_after_hook: record_wake_after
	}
}

// serve runs one request through the handler, with a plain event loop (no
// takeover, no subscriptions: the unit-test case of every backend), and
// returns the response and the step.
fn serve(req string, mut hub Hub) (string, core.Step) {
	mut out := []u8{}
	mut el := core.EventLoop{}
	step := handle(req.bytes(), mut out, -1, voidptr(hub), mut el)
	if _ := core.take_queued_takeover() {
		// a refused subscribe leaves nothing queued for the next request
	}
	return out.bytestr(), step
}

fn test_broadcast_endpoint_accepts() {
	mut hub := new_hub(15_000) // no subscribers
	out, step := serve('POST /broadcast HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello', mut hub)
	assert step == .done
	assert out == ok_response
}

fn test_broadcast_empty_body_is_ok() {
	// exercises the body.len == 0 guard: `data: \n\n` is still a valid SSE event
	mut hub := new_hub(15_000)
	out, step := serve('POST /broadcast HTTP/1.1\r\nContent-Length: 0\r\n\r\n', mut hub)
	assert step == .done
	assert out == ok_response
}

// A body past one mailbox slot is refused: post_bytes would report .too_big
// for every subscriber.
fn test_broadcast_too_large_is_413() {
	mut hub := new_hub(15_000)
	hub.add(1, core.ConnHandle{
		post: counting_post
		mbox: voidptr(&Recorded{})
		fd:   3
	})
	body := 'x'.repeat(max_event)
	out, step := serve('POST /broadcast HTTP/1.1\r\nContent-Length: ${max_event}\r\n\r\n${body}', mut
		hub)
	assert out == ok_response && step == .done
	out2, step2 := serve('POST /broadcast HTTP/1.1\r\nContent-Length: ${max_event + 1}\r\n\r\n${body}x', mut
		hub)
	assert out2 == too_large && step2 == .done
	r := unsafe { &Recorded(hub.subs[0].handle.mbox) }
	assert r.posts == 1, 'the oversized event was posted'
}

fn test_unknown_route_is_bad_request() {
	mut hub := new_hub(15_000)
	out, step := serve('GET /nope HTTP/1.1\r\nHost: x\r\n\r\n', mut hub)
	assert step == .done
	assert out == bad_request
}

fn test_malformed_request_errors() {
	mut hub := new_hub(15_000)
	// not even a request line — decode_into must reject it
	out1, step1 := serve('garbage', mut hub)
	assert step1 == .close, 'garbage input must close, not be routed'
	assert out1 == bad_request
	// truncated head: request line parses, but the header block never terminates
	out2, step2 := serve('GET /events HTTP/1.1\r\nHost: x', mut hub)
	assert step2 == .close, 'truncated request must close, not be routed'
	assert out2 == bad_request
	assert hub.size() == 0 // nothing was registered along the way
}

// Where the connection cannot be kept (no takeover, or no subscriptions: any
// backend but the epoll worker, a tcc build, a plain test loop), GET /events
// answers 501 and closes, and nothing is registered.
fn test_events_without_push_is_501() {
	mut hub := new_hub(15_000)
	out, step := serve('GET /events HTTP/1.1\r\nHost: x\r\n\r\n', mut hub)
	assert step == .close
	assert out == not_implemented
	assert hub.size() == 0
}

// The subscribe path, through stand-in hooks: the head, the drain-only
// takeover, the subscription (its sub_state is the hub id), the hub entry and
// the first heartbeat. Takeover is inert under tcc (#173).
fn test_events_subscribes() {
	$if tinyc {
		return
	}
	core.enable_takeover() // this thread may queue a takeover, as an epoll worker does
	mut hub := new_hub(15_000)
	mut r := &Recorded{}
	mut el := recording_loop(r)
	mut out := []u8{}
	step := handle('GET /events HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), mut out, -1, voidptr(hub), mut
		el)
	qt := core.take_queued_takeover() or { core.QueuedTakeover{} }
	assert step == .done
	assert out.bytestr() == sse_head
	assert voidptr(qt.cont) == voidptr(drain_conn), 'the connection was not handed to drain_conn'
	assert hub.size() == 1
	assert hub.subs[0].handle.fd == 7
	assert u64(usize(r.sub_state)) == hub.subs[0].id
	assert r.wake_ms == 15_000, 'the heartbeat was not armed'
}

// drain_conn drops whatever a subscriber sends, a pipelined request included.
fn test_drain_conn_consumes_everything() {
	mut out := []u8{}
	mut el := core.EventLoop{}
	buf := 'GET /events HTTP/1.1\r\nHost: x\r\n\r\nPOST /broadcast'.bytes()
	n, step := drain_conn(buf, mut out, -1, unsafe { nil }, unsafe { nil }, mut el)
	assert n == buf.len && step == .done
	assert out.len == 0
}

// wake runs sse_wake for `reason`, with `data` as the post, and returns what
// it appended and its step.
fn wake(reason core.WakeReason, data string, id u64, mut hub Hub, mut r Recorded) (string, core.Step) {
	mut el := recording_loop(r)
	el.reason = reason
	el.post_ptr = voidptr(data.str)
	el.post_len = data.len
	mut out := []u8{}
	step := sse_wake(mut out, 9, false, voidptr(usize(id)), voidptr(hub), mut el)
	return out.bytestr(), step
}

fn test_sse_wake_frames_posts_as_events() {
	mut hub := new_hub(15_000)
	mut r := Recorded{}
	for data, want in {
		'hello':        'data: hello\n\n'
		'':             'data: \n\n'
		'a\nb':         'data: a\ndata: b\n\n'
		'a\r\nb\rc':    'data: a\ndata: b\ndata: c\n\n'
		'x\n\ndata: y': 'data: x\ndata: \ndata: data: y\n\n' // cannot end the event early
		'end\n':        'data: end\ndata: \n\n'
	} {
		out, step := wake(.posted, data, 1, mut hub, mut r)
		assert step == .done
		assert out == want, 'post ${data}'
	}
}

fn test_sse_wake_heartbeat_shutdown_and_closed() {
	mut hub := new_hub(250)
	mut r := Recorded{}
	out, step := wake(.timeout, '', 1, mut hub, mut r)
	assert out == keepalive_event && step == .done
	assert r.wake_ms == 250, 'the heartbeat was not re-armed'
	out2, step2 := wake(.shutdown, '', 1, mut hub, mut r)
	assert out2 == '' && step2 == .close
	hub.add(4, core.ConnHandle{})
	hub.add(5, core.ConnHandle{})
	_, step3 := wake(.closed, '', 4, mut hub, mut r)
	assert step3 == .done
	assert hub.size() == 1 && hub.subs[0].id == 5, 'the departed subscriber is still in the hub'
}

// Serving and delivering allocate nothing: POST /broadcast to a subscriber,
// the 400s and the malformed close, and sse_wake's event and heartbeat, 20k
// times through one reused `out`, as a worker would; the collector's lifetime
// allocation counter must not move. (Under `-gc none`, vanilla's production
// build, the same allocation would be a permanent leak.)
fn test_serving_allocates_nothing() {
	$if gcboehm ? {
		reqs := [
			'POST /broadcast HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello',
			'POST /broadcast HTTP/1.1\r\nContent-Length: 0\r\n\r\n',
			'GET /nope HTTP/1.1\r\nHost: x\r\n\r\n',
			'garbage',
		].map(it.bytes())
		mut hub := new_hub(15_000)
		mut r := &Recorded{}
		hub.add(1, core.ConnHandle{
			post: counting_post
			mbox: voidptr(r)
			fd:   3
		})
		mut el := recording_loop(r)
		mut out := []u8{cap: 4096}
		event := 'patient-A:queue-position=3\n'
		rounds := 20_000
		mut before := u64(0)
		for round in 0 .. rounds + 1 {
			if round == 1 { // round 0 was the warm-up: `out` reached its high-water mark
				before = gc_heap_usage().total_bytes
			}
			for req in reqs {
				unsafe {
					out.len = 0
				}
				handle(req, mut out, -1, voidptr(hub), mut el)
			}
			unsafe {
				out.len = 0
			}
			el.reason = .posted
			el.post_ptr = voidptr(event.str)
			el.post_len = event.len
			sse_wake(mut out, 9, false, voidptr(usize(1)), voidptr(hub), mut el)
			unsafe {
				out.len = 0
			}
			el.reason = .timeout
			sse_wake(mut out, 9, false, voidptr(usize(1)), voidptr(hub), mut el)
		}
		grown := gc_heap_usage().total_bytes - before
		assert r.posts == 2 * (rounds + 1) // both broadcasts reached the subscriber
		assert grown < 4096, 'serving allocated ${grown} bytes over ${rounds} rounds'
	}
}
