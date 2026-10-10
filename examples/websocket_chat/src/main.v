module main

// WebSocket chat over server push (vanilla#230): every connected client is in
// one room; a text message from any of them reaches all of them, whichever
// worker each connection lives on. Three kinds of wake-up, on one connection,
// without parking it:
//
//   - client frames: chat_conn (the core.ConnHandler) reads them as they come;
//   - application events: a message posted to the connection's ConnHandle
//     by whichever worker handled the sender's frame (post_bytes), delivered
//     to chat_wake on the receiver's own worker, between its client bursts;
//   - timers: chat_wake's wake_after keepalive, a ping every ping_ms, and a
//     peer that has not answered the previous ping by then is closed (1001).
//
// And when a connection goes, for any reason, chat_wake runs one last time
// with .closed: it leaves the room and frees the connection's state.
//
// The room (who is connected, by handle) is application state shared by every
// worker, so it has a lock; it is reached through each worker's make_state
// value, not a global, and taken once per joined, left and sent message —
// never per delivery or per ping. A ConnHandle carries its connection's
// generation: a message posted to a member who has just left is dropped on
// its worker, never delivered to the connection that reuses the fd number.
//
// Run:   v run examples/websocket_chat/src
// Try:   two websocket clients (websocat ws://localhost:3000/chat?name=ana and
//        ws://localhost:3000/chat?name=bo), then type in either.
import core
import http1_1.request_parser
import http1_1.response
import os
import server
import sync
import sync.stdatomic
import websocket

const switching_prefix = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '
const head_end = '\r\n\r\n'
const home_response = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 45\r\nConnection: keep-alive\r\n\r\nWebSocket chat: connect to /chat?name=<you>\r\n'
const not_found_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
// 501: no takeover here (not the epoll plain worker, or a tcc build), or no
// subscription (the chat needs one to receive anything).
const cannot_upgrade_response = 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
const bad_upgrade_response = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'

const max_name = 32

// A message posted to a member must fit a mailbox slot (240 B): the name, `: `
// and the text. A longer text is cut.
const max_post = 240

// Room is the chat's shared state: its members, by handle.
@[heap]
struct Room {
mut:
	mu          &sync.Mutex = sync.new_mutex()
	members     []Member
	next_id     u64
	next_worker i64
}

struct Member {
	id     u64
	handle core.ConnHandle
}

// Worker is one worker's make_state value: the room, the keepalive interval,
// its id (shown to clients, so tests can tell workers apart) and a scratch
// buffer for the messages it posts.
@[heap]
struct Worker {
mut:
	room    &Room
	ping_ms int
	id      int
	post    []u8
}

// Chat is one connection's state: its takeover_state and sub_state. Allocated
// at the upgrade, freed by .closed.
@[heap]
struct Chat {
mut:
	id       u64
	handle   core.ConnHandle
	pinging  bool // a ping is out and its pong has not come back
	name_len int
	name     [max_name]u8
}

// new_config is the server's config: `room` shared through make_state.
fn new_config(port int, workers int, ping_ms int, room &Room) server.ServerConfig {
	return server.ServerConfig{
		port:               port
		io_multiplexing:    default_backend()
		handler:            handle
		workers:            workers
		push_mailbox_slots: 4096
		make_state:         fn [room, ping_ms] () voidptr {
			mut r := unsafe { room }
			return voidptr(&Worker{
				room:    room
				ping_ms: ping_ms
				id:      int(stdatomic.add_i64(&r.next_worker, 1) - 1)
				post:    []u8{cap: max_post}
			})
		}
	}
}

fn default_backend() server.IOBackend {
	mut backend := unsafe { server.IOBackend(0) }
	$if linux {
		backend = server.IOBackend.epoll
	}
	return backend
}

// join adds a member and returns its id.
fn (mut r Room) join(h core.ConnHandle) u64 {
	r.mu.lock()
	r.next_id++
	id := r.next_id
	r.members << Member{
		id:     id
		handle: h
	}
	r.mu.unlock()
	return id
}

fn (mut r Room) leave(id u64) {
	r.mu.lock()
	for i, m in r.members {
		if m.id == id {
			r.members.delete(i)
			break
		}
	}
	r.mu.unlock()
}

fn (mut r Room) size() int {
	r.mu.lock()
	n := r.members.len
	r.mu.unlock()
	return n
}

// broadcast posts `msg` to every member, the sender included (its client
// shows what the room saw, in the room's order). Never blocks: a member whose
// worker's mailbox is full misses the message (a real app would retry, or
// keep a backlog in its store and post a tag).
fn (mut r Room) broadcast(from u64, msg []u8) {
	r.mu.lock()
	for m in r.members {
		m.handle.post_bytes(from, msg)
	}
	r.mu.unlock()
}

@[direct_array_access]
fn slice_eq(buf []u8, s request_parser.Slice, want string) bool {
	if s.len != want.len {
		return false
	}
	for i in 0 .. want.len {
		if buf[s.start + i] != want[i] {
			return false
		}
	}
	return true
}

// query_name finds `name=<value>` in the request target, a view into the
// request (empty when absent).
@[direct_array_access]
fn query_name(buf []u8, target request_parser.Slice) []u8 {
	end := target.start + target.len
	mut i := target.start
	for i < end && buf[i] != `?` {
		i++
	}
	for i < end {
		i++ // past '?' or '&'
		if i + 5 <= end && buf[i] == `n` && buf[i + 1] == `a` && buf[i + 2] == `m` && buf[i + 3] == `e`
			&& buf[i + 4] == `=` {
			start := i + 5
			mut j := start
			for j < end && buf[j] != `&` {
				j++
			}
			if j == start {
				return []u8{}
			}
			return unsafe { (&buf[start]).vbytes(j - start) }
		}
		for i < end && buf[i] != `&` {
			i++
		}
	}
	return []u8{}
}

// handle is the HTTP side: GET /chat?name=<you> upgrades, joins the room and
// subscribes; anything else is a plain response.
fn handle(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	hr := request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	if !slice_eq(hr.buffer, hr.method, 'GET') {
		core.append_str(mut res, not_found_response)
		return .done
	}
	if slice_eq(hr.buffer, hr.path, '/') {
		core.append_str(mut res, home_response)
		return .done
	}
	if hr.path.len < 5 || !slice_eq(hr.buffer, request_parser.Slice{
		start: hr.path.start
		len:   5
	}, '/chat') {
		core.append_str(mut res, not_found_response)
		return .done
	}
	upgrade := hr.get_header_value_slice('Upgrade') or {
		core.append_str(mut res, bad_upgrade_response)
		return .close
	}
	key := hr.get_header_value_slice('Sec-WebSocket-Key') or {
		core.append_str(mut res, bad_upgrade_response)
		return .close
	}
	if !slice_eq(hr.buffer, upgrade, 'websocket') || worker_state == unsafe { nil } {
		core.append_str(mut res, bad_upgrade_response)
		return .close
	}
	mut w := unsafe { &Worker(worker_state) }
	mut st := &Chat{}
	name := query_name(hr.buffer, hr.path)
	st.name_len = if name.len > max_name { max_name } else { name.len }
	for i in 0 .. st.name_len {
		st.name[i] = name[i]
	}
	if !core.queue_takeover(chat_conn, voidptr(st)) {
		unsafe { free(st) }
		core.append_str(mut res, cannot_upgrade_response)
		return .close
	}
	st.handle = event_loop.subscribe(chat_wake, voidptr(st))
	if st.handle.is_nil() {
		// Taken over but not subscribed: nothing could ever reach it. The
		// takeover queued above is dropped with this .close.
		unsafe { free(st) }
		core.append_str(mut res, cannot_upgrade_response)
		return .close
	}
	st.id = w.room.join(st.handle)
	event_loop.wake_after(w.ping_ms)
	core.append_str(mut res, switching_prefix)
	websocket.append_accept_key(mut res, unsafe { tos(&hr.buffer[key.start], key.len) })
	core.append_str(mut res, head_end)
	// A first frame, right behind the handshake: which worker serves you.
	welcome(mut res, w.id)
	return .done
}

fn welcome(mut out []u8, worker int) {
	digits := if worker >= 10 { 2 } else { 1 }
	websocket.write_frame_header(mut out, websocket.op_text, 15 + digits)
	core.append_str(mut out, 'joined, worker ')
	if worker >= 10 {
		out << u8(`0` + worker / 10 % 10)
	}
	out << u8(`0` + worker % 10)
}

// chat_conn reads the client's frames (a core.ConnHandler): a text message
// goes to the room; ping -> pong; a pong ends the keepalive's wait; close
// completes the close handshake.
fn chat_conn(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut st := unsafe { &Chat(takeover_state) }
	mut w := unsafe { &Worker(worker_state) }
	mut consumed := 0
	for consumed < buf.len {
		mut rest := unsafe { (&buf[consumed]).vbytes(buf.len - consumed) }
		h := websocket.frame_head(rest)
		if h.total == websocket.incomplete {
			break
		}
		if h.total == websocket.err_malformed || !h.masked {
			websocket.write_close(mut out, websocket.close_protocol_error)
			return consumed, core.Step.close
		}
		websocket.unmask_in_place(mut rest, h)
		payload := if h.payload_len > 0 {
			unsafe { (&rest[h.payload_off]).vbytes(h.payload_len) }
		} else {
			[]u8{}
		}
		match h.opcode {
			websocket.op_text {
				if !h.fin {
					websocket.write_close(mut out, websocket.close_unsupported)
					return consumed, core.Step.close
				}
				// `name: text`, built in the worker's scratch, cut to a slot.
				unsafe {
					w.post.len = 0
				}
				unsafe { w.post.push_many(&st.name[0], st.name_len) }
				core.append_str(mut w.post, ': ')
				room := max_post - w.post.len
				n := if payload.len > room { room } else { payload.len }
				if n > 0 {
					unsafe { w.post.push_many(payload.data, n) }
				}
				w.room.broadcast(st.id, w.post)
			}
			websocket.op_ping {
				websocket.write_pong(mut out, payload)
			}
			websocket.op_pong {
				st.pinging = false
			}
			websocket.op_close {
				websocket.write_close(mut out, websocket.close_normal)
				return consumed + h.total, core.Step.close
			}
			else {
				websocket.write_close(mut out, websocket.close_unsupported)
				return consumed, core.Step.close
			}
		}

		consumed += h.total
	}
	return consumed, core.Step.done
}

// chat_wake is the connection's wake fn: messages posted to it, its keepalive
// timer, the server's shutdown, and its close.
fn chat_wake(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &Chat(watch_payload) }
	match event_loop.reason() {
		.posted {
			data := event_loop.post_data()
			websocket.write_frame_header(mut out, websocket.op_text, data.len)
			if data.len > 0 {
				unsafe { out.push_many(data.data, data.len) }
			}
		}
		.timeout {
			if st.pinging {
				// The last ping got no pong in a whole interval: gone.
				websocket.write_close(mut out, websocket.close_going_away)
				return .close
			}
			websocket.write_ping(mut out, []u8{})
			st.pinging = true
			w := unsafe { &Worker(worker_state) }
			event_loop.wake_after(w.ping_ms)
		}
		.shutdown {
			websocket.write_close(mut out, websocket.close_going_away)
			return .close
		}
		.closed {
			mut w := unsafe { &Worker(worker_state) }
			w.room.leave(st.id)
			unsafe { free(st) } // nothing references it any more
		}
		else {}
	}
	return .done
}

fn main() {
	ping_ms := if os.getenv('CHAT_PING_MS') != '' {
		os.getenv('CHAT_PING_MS').int()
	} else {
		25_000
	}
	mut srv := server.new_server(new_config(3000, 0, ping_ms, &Room{}))!
	println('WebSocket chat on ws://localhost:3000/chat?name=<you>')
	srv.run()
}
