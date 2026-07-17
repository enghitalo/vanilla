module vtest

// vtest — event-driven end-to-end test client for vanilla servers.
// Design + contract: docs/VTEST.md. The short version:
//
//   - drive()/start() own the whole lifecycle: bind (always port 0/ephemeral),
//     spawn run(), and the client work begins the instant after_server_start
//     fires. The test author never sees readiness.
//   - There is NO timeout anywhere in this module. The reactor blocks in
//     poll(-1); progress comes from the server (bytes or close), so the only
//     clocks in a test are the server's own configs (Limits). A server that
//     loses liveness hangs the test — deliberately (CI step timeout backstops).
//   - A run terminates exactly when every connection reached a terminal state:
//     its script's expectations met, or EOF from the server.
//   - Scripts are data. The engine is this one file; read it once and every
//     e2e test in the tree is just "server config + scripts + asserts".
//
// The reactor runs on the CALLER's thread inside fire()/wait() — no reactor
// thread, no cross-thread machinery. Connections persist across calls (the
// kernel socket buffers hold anything that arrives in between), which is what
// makes multi-step choreography (SSE subscribe → publish → expect) work with
// completion-based ordering instead of sleeps.
import net
import sync.stdatomic
import server
import socket

fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int

// Round is one send-then-expect step of a connection's life. Round k+1's bytes
// go out only after round k's expectation held.
pub struct Round {
pub:
	send []u8
	// want adds this many complete framed responses to the connection's
	// cumulative target (predicates always run against ALL bytes received on
	// the connection so far). want: 0 = fire-and-forget send.
	want int = 1
	// until is the general form and overrides want: the round is done when this
	// pure predicate holds on the accumulated bytes. See frames()/headers_seen/
	// count() for the packaged ones.
	until fn (acc []u8) bool = unsafe { nil }
}

// Script is one connection's whole life, as data.
pub struct Script {
pub:
	rounds   []Round
	then_eof bool // after the last round, require the SERVER to close (EOF)
	shut_wr  bool // half-close (SHUT_WR) once the final round's bytes are written
}

pub struct ConnResult {
pub mut:
	frames      [][]u8 // complete framed responses, in arrival order
	raw         []u8   // everything received (SSE / chunked asserts read this)
	eof         bool   // the server closed (or reset) the connection
	unmet       bool   // EOF arrived before the script's expectations were satisfied
	connect_err string // non-empty when the connect itself failed
}

// Group identifies the connections created by one fire() call, in script order.
pub type Group = []int

pub struct Outcome {
pub:
	group Group
	// conns is in the SAME order as the scripts passed to fire(): position is
	// identity. Within a connection, frames[j] answers the j-th request.
	conns []ConnResult
	// Server internals, sampled when this Outcome was built (after shutdown for
	// drive(); live for fire()/wait()). inflight_after == 0 proves the drain;
	// active_after can lag EOF bookkeeping by a beat on a live server — assert
	// it == 0 in drive() outcomes.
	inflight_after i64
	active_after   i64
}

struct HConn {
mut:
	tcp         &net.TcpConn = unsafe { nil }
	fd          int          = -1
	rounds      []Round
	then_eof    bool
	shut_wr     bool
	round       int // index of the round in flight
	sent        int // bytes of the current round's send already written
	cum_want    int // cumulative frame target across armed want-rounds
	acc         []u8
	eof         bool
	done        bool
	half_closed bool
	unmet       bool
	connect_err string
}

@[heap]
pub struct Harness {
mut:
	server  server.Server
	conns   []HConn
	stopped bool
pub mut:
	grace_ms int = 500 // shutdown grace handed to Server.shutdown in stop()
}

// start brings the server up and returns once it is accepting: new_server binds
// the listeners synchronously, and the returned Harness only exists after
// after_server_start fired on the run() thread. Always binds port 0 — the
// resolved port is h.port() / h.server.port; tests never coordinate ports.
pub fn start(config server.ServerConfig) !&Harness {
	ready := chan bool{cap: 1}
	user_hook := config.after_server_start
	cfg := server.ServerConfig{
		...config
		port:               0
		after_server_start: fn [ready, user_hook] () {
			if user_hook != unsafe { nil } {
				user_hook()
			}
			ready <- true
		}
	}
	mut h := &Harness{
		server: server.new_server(cfg)!
	}
	mut srv := h.server // the run thread's copy shares the &Counter fields
	spawn fn [mut srv] () {
		srv.run()
	}()
	_ := <-ready
	return h
}

// port the server actually listens on (kernel-assigned).
pub fn (h &Harness) port() int {
	return h.server.port
}

// server exposes the underlying Server for hand-rolled steps a Script cannot
// express (e.g. calling shutdown() mid-flight in a graceful-drain test).
pub fn (mut h Harness) server_ref() &server.Server {
	return &h.server
}

// fire connects one socket per script, runs the reactor until every one of
// THESE scripts finished its rounds (met, or EOF), and returns their results.
// The connections stay open in the harness — a later wait() can add
// expectations (SSE), and stop() closes everything.
pub fn (mut h Harness) fire(scripts []Script) !Outcome {
	mut group := []int{cap: scripts.len}
	for s in scripts {
		mut hc := HConn{
			rounds:   s.rounds.clone()
			then_eof: s.then_eof
			shut_wr:  s.shut_wr
			acc:      []u8{cap: 8192}
		}
		mut tcp := net.dial_tcp('127.0.0.1:${h.server.port}') or {
			hc.connect_err = err.msg()
			hc.eof = true
			hc.done = true
			h.conns << hc
			group << h.conns.len - 1
			continue
		}
		hc.tcp = tcp
		// TcpConn carries two handle fields; dial_tcp only fills sock.handle
		// (the outer .handle stays 0 — vlib itself reads sock.handle everywhere).
		hc.fd = tcp.sock.handle
		socket.set_blocking(hc.fd, false)
		hc.arm_round()
		h.conns << hc
		group << h.conns.len - 1
	}
	h.pump(group)
	return h.results(group)
}

// wait blocks until `until` holds on every connection of the group (or the
// server closed it), then returns fresh results. This is the choreography
// primitive: fire(subscribers) → fire(publisher) → wait(subscribers, count(...)).
pub fn (mut h Harness) wait(group Group, until fn (acc []u8) bool) !Outcome {
	for gi in group {
		if h.conns[gi].eof {
			continue
		}
		h.conns[gi].rounds << Round{
			send:  []u8{}
			until: until
		}
		h.conns[gi].done = false
	}
	h.pump(group)
	return h.results(group)
}

// stop closes every client connection, then shuts the server down (draining
// in-flight up to grace_ms). Idempotent.
pub fn (mut h Harness) stop() {
	if h.stopped {
		return
	}
	h.stopped = true
	for mut c in h.conns {
		if c.fd >= 0 {
			c.tcp.close() or {}
			c.fd = -1
		}
	}
	h.server.shutdown(h.grace_ms)
}

// drive is the one-shot form: start → fire → stop, with the Outcome's server
// counters sampled AFTER the shutdown drain.
pub fn drive(config server.ServerConfig, scripts []Script) !Outcome {
	mut h := start(config)!
	o := h.fire(scripts)!
	h.stop()
	return Outcome{
		group:          o.group
		conns:          o.conns
		inflight_after: h.inflight_sum()
		active_after:   stdatomic.load_i64(&h.server.active_conns.n)
	}
}

// repeat clones one script n times — the storm builder.
pub fn repeat(n int, s Script) []Script {
	mut out := []Script{cap: n}
	for _ in 0 .. n {
		out << s
	}
	return out
}

// ==================== reactor ====================

// pump drives the group until every connection is terminal. One poll(-1) loop:
// the same readiness-loop shape the server's own backends use, pointed the
// other way. No deadline: see the module header for the liveness contract.
fn (mut h Harness) pump(group Group) {
	mut buf := []u8{len: 65536}
	for {
		// Progress sweep first: writes are attempted and predicates evaluated
		// before blocking, so expectations satisfiable on already-received bytes
		// (wait() over a warm acc) terminate without needing another event.
		mut pfds := []C.pollfd{cap: group.len}
		mut idxs := []int{cap: group.len}
		for gi in group {
			h.conns[gi].write_some()
			h.conns[gi].progress()
			c := &h.conns[gi]
			if c.done {
				continue
			}
			mut ev := pollin
			if c.round < c.rounds.len && c.sent < c.rounds[c.round].send.len {
				ev |= pollout
			}
			pfds << mk_pollfd(c.fd, ev)
			idxs << gi
		}
		if pfds.len == 0 {
			return
		}
		nr := vpoll(mut pfds)
		if nr <= 0 {
			continue // EINTR — just rebuild and re-enter
		}
		for k, pf in pfds {
			rev := int(pf.revents)
			if rev == 0 {
				continue
			}
			gi := idxs[k]
			if rev & (pollin | pollhup | pollerr) != 0 {
				h.conns[gi].read_burst(mut buf, rev)
			}
			h.conns[gi].write_some()
			h.conns[gi].progress()
		}
	}
}

// write_some pushes as much of the current round's send as the socket accepts.
fn (mut c HConn) write_some() {
	if c.done || c.round >= c.rounds.len {
		return
	}
	r := c.rounds[c.round]
	if c.sent >= r.send.len {
		return
	}
	n := C.send(c.fd, unsafe { &r.send[c.sent] }, usize(r.send.len - c.sent), 0)
	if n > 0 {
		c.sent += n
	}
}

// read_burst drains the socket into acc until EAGAIN or EOF.
fn (mut c HConn) read_burst(mut buf []u8, rev int) {
	if c.done {
		return
	}
	for {
		n := C.recv(c.fd, unsafe { &buf[0] }, usize(buf.len), 0)
		if n > 0 {
			c.acc << buf[..n]
			continue
		}
		if n == 0 {
			c.eof = true // orderly close from the server
		} else if rev & (pollerr | pollhup) != 0 {
			c.eof = true // reset counts as close for test purposes
		}
		break
	}
}

// arm_round accounts the entering round's `want` into the cumulative target
// (predicates always run against the connection's full acc).
fn (mut c HConn) arm_round() {
	if c.round < c.rounds.len {
		r := c.rounds[c.round]
		if r.until == unsafe { nil } {
			c.cum_want += r.want
		}
	}
}

// progress advances rounds whose send is flushed and whose expectation holds,
// then settles the terminal state.
fn (mut c HConn) progress() {
	if c.done {
		return
	}
	for c.round < c.rounds.len {
		r := c.rounds[c.round]
		if c.sent < r.send.len {
			if c.eof {
				break // peer is gone; nothing more will flush
			}
			return
		}
		if c.shut_wr && !c.half_closed && c.round == c.rounds.len - 1 {
			// Final round's bytes are out: half-close NOW, before waiting for
			// the response — that is the RFC 9112 §9.6 scenario.
			socket.shutdown_write(c.fd)
			c.half_closed = true
		}
		met := if r.until != unsafe { nil } {
			r.until(c.acc)
		} else {
			count_frames(c.acc) >= c.cum_want
		}
		if !met {
			if c.eof {
				break
			}
			return
		}
		c.round++
		c.sent = 0
		c.arm_round()
	}
	if c.round >= c.rounds.len {
		if c.then_eof && !c.eof {
			return
		}
		c.done = true
		return
	}
	// EOF with rounds pending: terminal, expectations unmet.
	if c.eof {
		c.unmet = true
		c.done = true
	}
}

fn (mut h Harness) results(group Group) Outcome {
	mut out := []ConnResult{cap: group.len}
	for gi in group {
		c := &h.conns[gi]
		out << ConnResult{
			frames:      extract_frames(c.acc)
			raw:         seg(c.acc, 0, c.acc.len)
			eof:         c.eof
			unmet:       c.unmet
			connect_err: c.connect_err
		}
	}
	return Outcome{
		group:          group
		conns:          out
		inflight_after: h.inflight_sum()
		active_after:   stdatomic.load_i64(&h.server.active_conns.n)
	}
}

fn (h &Harness) inflight_sum() i64 {
	mut sum := i64(0)
	for c in h.server.inflight {
		sum += stdatomic.load_i64(&c.n)
	}
	return sum
}

// ==================== framing (pure fns over bytes) ====================

const head_end = '\r\n\r\n'.bytes()
const cl_marker = 'Content-Length: '.bytes()

// frames packages the common expectation: n complete framed responses.
pub fn frames(n int) fn (acc []u8) bool {
	return fn [n] (acc []u8) bool {
		return count_frames(acc) >= n
	}
}

// headers_seen holds once the first response head is complete — the SSE
// subscription ack, an interim 100, etc.
pub fn headers_seen(acc []u8) bool {
	return index_of(acc, 0, acc.len, head_end) >= 0
}

// count packages "the needle appeared n times" (SSE events, keep-alive markers).
pub fn count(needle string, n int) fn (acc []u8) bool {
	nb := needle.bytes()
	return fn [nb, n] (acc []u8) bool {
		return count_occurrences(acc, nb) >= n
	}
}

// next_frame_len returns the length of the complete framed response starting at
// off, or -1 while incomplete. A response head with no Content-Length is a
// headers-only frame (interim 100, some errors) ending at the blank line — the
// server always frames keep-alive bodies with Content-Length, and streams
// (SSE) are asserted with until-predicates, never with frame counts.
fn next_frame_len(acc []u8, off int) int {
	he := index_of(acc, off, acc.len, head_end)
	if he < 0 {
		return -1
	}
	head_len := he + head_end.len - off
	cl := index_of(acc, off, he + head_end.len, cl_marker)
	if cl < 0 {
		return head_len
	}
	mut v := 0
	mut i := cl + cl_marker.len
	for i < he && acc[i] >= `0` && acc[i] <= `9` {
		v = v * 10 + int(acc[i] - `0`)
		i++
	}
	total := head_len + v
	if acc.len - off < total {
		return -1
	}
	return total
}

fn count_frames(acc []u8) int {
	mut n := 0
	mut off := 0
	for off < acc.len {
		l := next_frame_len(acc, off)
		if l < 0 {
			break
		}
		n++
		off += l
	}
	return n
}

fn extract_frames(acc []u8) [][]u8 {
	mut out := [][]u8{}
	mut off := 0
	for off < acc.len {
		l := next_frame_len(acc, off)
		if l < 0 {
			break
		}
		out << seg(acc, off, l)
		off += l
	}
	return out
}

// index_of finds needle in acc[from..to), returning its absolute start or -1.
fn index_of(acc []u8, from int, to int, needle []u8) int {
	if needle.len == 0 || to - from < needle.len {
		return -1
	}
	for i := from; i <= to - needle.len; i++ {
		mut hit := true
		for j in 0 .. needle.len {
			if acc[i + j] != needle[j] {
				hit = false
				break
			}
		}
		if hit {
			return i
		}
	}
	return -1
}

fn count_occurrences(acc []u8, needle []u8) int {
	mut n := 0
	mut off := 0
	for {
		i := index_of(acc, off, acc.len, needle)
		if i < 0 {
			return n
		}
		n++
		off = i + needle.len
	}
	return n
}

// seg copies acc[off .. off+len] without slice-marking the (still growing)
// source buffer.
fn seg(acc []u8, off int, len int) []u8 {
	mut out := []u8{len: len}
	if len > 0 {
		unsafe { vmemcpy(out.data, &acc[off], len) }
	}
	return out
}
