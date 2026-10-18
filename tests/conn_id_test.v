// vtest build: linux
// A connection identity for plain HTTP/1.1 handlers (vanilla#350):
// event_loop.conn_id() names the connection a handler or continuation
// serves, so what belongs to the connection (peer credentials read once, the
// peer's address) can be cached under it rather than under client_fd, whose
// number the next connection gets once this one closes.
//
// The checks follow the issue's list: connections in a row that get the same
// fd number get different ids, with accept-time births off and on; a
// keep-alive connection keeps one id across its requests, pipelined ones
// too, and their continuations (a resumed park, a timed-out park, a streamed
// upload's head), and a taken-over connection keeps its upgrade request's id
// in its ConnHandler and wake fn, .closed included; two requests parked on
// one shared fd and resumed from one edge each get their own; and no two
// connections share an id, across two workers or two servers in one
// process. The id is 0, unknown, where there is no connection (on_worker_start,
// a tombstone's run) and off the epoll worker (io_uring here). Takeover is
// inert under tcc (#173): run with gcc.
import server
import core
import sync.stdatomic
import time
import transport
import vtest

#include <sys/socket.h>
#include <fcntl.h>

fn C.send(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.recv(__fd int, __buf voidptr, __n usize, __flags int) int
fn C.pipe(fds &i32) int
fn C.write(fd int, buf voidptr, count usize) int
fn C.read(fd int, buf voidptr, count usize) int
fn C.close(fd int) int
fn C.fcntl(fd int, cmd int, arg int) int

const ci_head = 'HTTP/1.1 200 OK\r\nContent-Length: '

const ci_101 = 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: lines\r\nConnection: Upgrade\r\n\r\n'

// POST /big's body: larger than backend_epoll's sm_stream_body_above (1
// MiB), so it is streamed (drained) and its handler sees the head alone.
const ci_big_len = 2 * 1024 * 1024

// CiWorker is one worker's state: its index (ci_state).
struct CiWorker {
	idx int
}

// CiShared is what the handlers, hooks and the test thread share: atomics.
struct CiShared {
mut:
	next_worker i64
	parked      i64 // requests parked on the shared pipe (GET /queue, GET /orphan)
	pipe_r      i64 = -1 // the shared pipe: its read end, which those park on
	pipe_w      i64 = -1 // and its write end, the test's
	start_runs  i64 // on_worker_start calls
	start_id    i64 = -1 // conn_id() in the last of them
	closed_runs i64 // .closed wakes
	closed_id   i64 = -1 // conn_id() in the last of them
	dead_runs   i64 // runs of GET /orphan's continuation
	dead_id     i64 = -1 // conn_id() in the last of them
}

const ci = &CiShared{}

fn ci_state() voidptr {
	mut s := unsafe { ci }
	return voidptr(&CiWorker{
		idx: int(stdatomic.add_i64(&s.next_worker, 1) - 1)
	})
}

// ci_reset numbers the next server's workers from 0 and clears what the
// hooks recorded.
fn ci_reset() {
	mut s := unsafe { ci }
	stdatomic.store_i64(&s.next_worker, 0)
	stdatomic.store_i64(&s.parked, 0)
	stdatomic.store_i64(&s.start_runs, 0)
	stdatomic.store_i64(&s.start_id, -1)
	stdatomic.store_i64(&s.closed_runs, 0)
	stdatomic.store_i64(&s.closed_id, -1)
	stdatomic.store_i64(&s.dead_runs, 0)
	stdatomic.store_i64(&s.dead_id, -1)
}

// ci_until waits until the counter at p reaches want, for at most ms, and
// returns it.
fn ci_until(p &i64, want i64, ms int) i64 {
	for _ in 0 .. ms {
		if stdatomic.load_i64(p) >= want {
			break
		}
		time.sleep(time.millisecond)
	}
	return stdatomic.load_i64(p)
}

fn ci_prefix(b []u8, p string) bool {
	if b.len < p.len {
		return false
	}
	for i in 0 .. p.len {
		if b[i] != p[i] {
			return false
		}
	}
	return true
}

// ci_dec appends n's decimal digits.
fn ci_dec(mut out []u8, n u64) {
	if n >= 10 {
		ci_dec(mut out, n / 10)
	}
	out << u8(`0` + n % 10)
}

// ci_report appends a response whose body is `<label> id=<id> fd=<fd>
// w=<worker>#`; .close (with Connection: close) when `close`.
fn ci_report(mut out []u8, label string, id u64, fd int, worker int, close bool) core.Step {
	mut body := []u8{cap: 64}
	core.append_str(mut body, label)
	core.append_str(mut body, ' id=')
	ci_dec(mut body, id)
	if fd >= 0 {
		core.append_str(mut body, ' fd=')
		ci_dec(mut body, u64(fd))
		core.append_str(mut body, ' w=')
		ci_dec(mut body, u64(worker))
	}
	body << `#`
	core.append_str(mut out, ci_head)
	ci_dec(mut out, u64(body.len))
	core.append_str(mut out, if close { '\r\nConnection: close\r\n\r\n' } else { '\r\n\r\n' })
	out << body
	return if close { .close } else { .done }
}

fn ci_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	w := unsafe { &CiWorker(worker_state) }
	if ci_prefix(req, 'GET /park ') {
		// A pipe that is readable at once: the continuation runs on the
		// worker's next pass.
		mut fds := [2]i32{}
		C.pipe(&fds[0])
		one := u8(1)
		C.write(int(fds[1]), &one, 1)
		C.close(int(fds[1]))
		event_loop.watch_fd(int(fds[0]), .readable, ci_resumed, unsafe { nil })
		return .suspend
	}
	if ci_prefix(req, 'GET /slow ') {
		// A pipe nobody writes: the park's deadline ends it. The continuation
		// closes both ends (the write end comes as its payload).
		mut fds := [2]i32{}
		C.pipe(&fds[0])
		event_loop.watch_fd_deadline(int(fds[0]), .readable, ci_timed_out, voidptr(isize(fds[1])),
			20)
		return .suspend
	}
	if ci_prefix(req, 'GET /queue ') || ci_prefix(req, 'GET /orphan ') {
		// Park on the shared pipe, as requests share a pooled connection
		// (watch_fd_persistent): a second park on it queues behind the first.
		mut s := unsafe { ci }
		cont := if ci_prefix(req, 'GET /queue ') { ci_queued } else { ci_orphaned }
		event_loop.watch_fd_persistent(int(stdatomic.load_i64(&s.pipe_r)), .readable, cont,
			unsafe { nil })
		stdatomic.add_i64(&s.parked, 1)
		return .suspend
	}
	if ci_prefix(req, 'GET /up ') {
		if !core.queue_takeover(ci_lines, unsafe { nil }) {
			core.append_str(mut out, 'HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n')
			return .close
		}
		event_loop.subscribe(ci_wake, unsafe { nil })
		core.append_str(mut out, ci_101)
		core.append_str(mut out, 'up id=')
		ci_dec(mut out, event_loop.conn_id())
		core.append_str(mut out, '#\n')
		return .done
	}
	// GET /id, GET /bye (answered, then closed) and POST /big: `big` only when
	// the handler saw the head alone, its body to be drained after it returns.
	label := if !ci_prefix(req, 'POST ') {
		'handler'
	} else if req.len < ci_big_len {
		'big'
	} else {
		'buffered'
	}
	return ci_report(mut out, label, event_loop.conn_id(), client_fd, w.idx, ci_prefix(req,
		'GET /bye '))
}

// ci_resumed is GET /park's continuation.
fn ci_resumed(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut b := u8(0)
	C.read(ready_fd, &b, 1)
	C.close(ready_fd) // the request owns it
	return ci_report(mut out, 'resumed', event_loop.conn_id(), -1, 0, false)
}

// ci_timed_out is GET /slow's continuation, run by its park's deadline.
fn ci_timed_out(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	C.close(ready_fd)
	C.close(int(isize(watch_payload)))
	return ci_report(mut out, if event_loop.timed_out() { 'timeout' } else { 'ready' },
		event_loop.conn_id(), -1, 0, false)
}

// ci_take reads one byte of the shared pipe: a parked request's reply.
fn ci_take(fd int) bool {
	mut b := u8(0)
	return C.read(fd, &b, 1) == 1
}

// ci_queued is GET /queue's continuation: it takes its byte and reports.
fn ci_queued(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !ci_take(ready_fd) {
		event_loop.watch_fd_persistent(ready_fd, .readable, ci_queued, unsafe { nil })
		return .suspend
	}
	return ci_report(mut out, 'queued', event_loop.conn_id(), -1, 0, false)
}

// ci_orphaned is GET /orphan's continuation. Its client leaves while it is
// parked, so it runs as a tombstone, to take its byte: it records its id.
fn ci_orphaned(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if !ci_take(ready_fd) {
		event_loop.watch_fd_persistent(ready_fd, .readable, ci_orphaned, unsafe { nil })
		return .suspend
	}
	mut s := unsafe { ci }
	stdatomic.store_i64(&s.dead_id, i64(event_loop.conn_id()))
	stdatomic.add_i64(&s.dead_runs, 1)
	return ci_report(mut out, 'orphaned', event_loop.conn_id(), -1, 0, false)
}

// ci_on_start records the id on_worker_start sees: it has no client.
fn ci_on_start(worker_state voidptr, mut event_loop core.EventLoop) {
	mut s := unsafe { ci }
	stdatomic.store_i64(&s.start_id, i64(event_loop.conn_id()))
	stdatomic.add_i64(&s.start_runs, 1)
}

// ci_lines is GET /up's protocol: `wait` arms wake_after (its wake fn
// answers `wake id=<id>#`), any other line is answered `lines id=<id>#`.
fn ci_lines(buf []u8, mut out []u8, client_fd int, takeover_state voidptr, worker_state voidptr, mut event_loop core.EventLoop) (int, core.Step) {
	mut consumed := 0
	for {
		mut end := consumed
		for end < buf.len && buf[end] != `\n` {
			end++
		}
		if end == buf.len {
			break // partial line
		}
		line := unsafe { (&buf[consumed]).vbytes(end - consumed) }
		consumed = end + 1
		if line.len == 4 && ci_prefix(line, 'wait') {
			core.append_str(mut out, if event_loop.wake_after(5) { 'armed\n' } else { 'unarmed\n' })
		} else {
			core.append_str(mut out, 'lines id=')
			ci_dec(mut out, event_loop.conn_id())
			core.append_str(mut out, '#\n')
		}
	}
	return consumed, core.Step.done
}

// ci_wake is the subscription's wake fn: its wake_after timer reports the
// id, and .closed records it.
fn ci_wake(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if event_loop.reason() == .timeout {
		core.append_str(mut out, 'wake id=')
		ci_dec(mut out, event_loop.conn_id())
		core.append_str(mut out, '#\n')
	} else if event_loop.reason() == .closed {
		mut s := unsafe { ci }
		stdatomic.store_i64(&s.closed_id, i64(event_loop.conn_id()))
		stdatomic.add_i64(&s.closed_runs, 1)
	}
	return .done
}

fn ci_config(backend server.IOBackend, workers int, limits server.Limits) server.ServerConfig {
	cfg := server.ServerConfig{
		io_multiplexing: backend
		workers:         workers
		handler:         ci_handler
		make_state:      ci_state
		limits:          limits
	}
	if backend != .epoll {
		return cfg // on_worker_start is the epoll worker's
	}
	return server.ServerConfig{
		...cfg
		on_worker_start: ci_on_start
	}
}

// CiClient is a raw client connection that accumulates what it reads.
struct CiClient {
	fd int
mut:
	acc []u8
}

fn ci_dial(port int) !CiClient {
	return CiClient{
		fd: transport.dial_tcp('127.0.0.1', port)!
	}
}

// send writes all of s, waiting out a connect still in flight and a full
// socket buffer (POST /big's body), for at most 10 s.
fn (mut c CiClient) send(s string) ! {
	deadline := time.sys_mono_now() + 10 * u64(time.second)
	mut off := 0
	for off < s.len {
		n := C.send(c.fd, unsafe { s.str + off }, usize(s.len - off), C.MSG_NOSIGNAL)
		if n > 0 {
			off += n
			continue
		}
		if time.sys_mono_now() > deadline {
			return error('send stalled after ${off} of ${s.len} bytes')
		}
		time.sleep(time.millisecond)
	}
}

// reports reads until `n` reports (`#`-terminated) arrived, the server
// closes, or `ms` pass, and returns the ids in them, in order.
fn (mut c CiClient) reports(n int, ms int) []u64 {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	mut buf := [4096]u8{}
	for c.acc.bytestr().count('#') < n {
		k := C.recv(c.fd, &buf[0], 4096, C.MSG_DONTWAIT)
		if k > 0 {
			unsafe { c.acc.push_many(&buf[0], k) }
			continue
		}
		if k == 0 || time.sys_mono_now() > deadline {
			break
		}
		time.sleep(time.millisecond)
	}
	return ci_fields(c.acc.bytestr(), ' id=')
}

// eof reads until the server closes (true) or `ms` pass.
fn (mut c CiClient) eof(ms int) bool {
	deadline := time.sys_mono_now() + u64(ms) * 1_000_000
	mut buf := [4096]u8{}
	for time.sys_mono_now() < deadline {
		k := C.recv(c.fd, &buf[0], 4096, C.MSG_DONTWAIT)
		if k > 0 {
			unsafe { c.acc.push_many(&buf[0], k) }
			continue
		}
		if k == 0 || (k < 0 && C.errno != C.EAGAIN) {
			return true
		}
		time.sleep(time.millisecond)
	}
	return false
}

fn (mut c CiClient) close() {
	transport.close_fd(c.fd)
}

// ci_fields returns the decimal values that follow each `key` in s.
fn ci_fields(s string, key string) []u64 {
	mut vals := []u64{}
	mut i := 0
	for i + key.len <= s.len {
		if s.substr(i, i + key.len) != key {
			i++
			continue
		}
		mut v := u64(0)
		i += key.len
		for i < s.len && s[i] >= `0` && s[i] <= `9` {
			v = v * 10 + u64(s[i] - `0`)
			i++
		}
		vals << v
	}
	return vals
}

fn ci_get(path string) string {
	return 'GET ' + path + ' HTTP/1.1\r\nHost: x\r\n\r\n'
}

// CiConn is what one connection reported: its id, the server's fd for it
// and the worker that served it.
struct CiConn {
	id     u64
	fd     int
	worker int
}

// ci_once opens a connection, asks GET /bye, reads to the server's close and
// closes its own end. The server closed its fd before the client saw the
// EOF, and the client's own number is free again: the next connection gets
// the same two numbers, unless something else took one meanwhile.
fn ci_once(port int) !CiConn {
	mut c := ci_dial(port)!
	defer {
		c.close()
	}
	c.send(ci_get('/bye'))!
	if !c.eof(3000) {
		return error('the server did not close: ${c.acc.bytestr()}')
	}
	s := c.acc.bytestr()
	ids := ci_fields(s, ' id=')
	fds := ci_fields(s, ' fd=')
	ws := ci_fields(s, ' w=')
	if ids.len != 1 || fds.len != 1 || ws.len != 1 {
		return error('no report: ${s}')
	}
	return CiConn{
		id:     ids[0]
		fd:     int(fds[0])
		worker: int(ws[0])
	}
}

// Connections one after another on one worker: the kernel hands each the
// number the previous one freed, and each gets an id of its own, never 0.
// With accept-time births on (a read timeout) a connection's state is made
// from the birth queue rather than at its first event: the same rule.
fn test_epoll_conn_id_differs_on_a_reused_fd() ! {
	for limits in [server.Limits{}, server.Limits{
		read_timeout_ms: 5000
	}] {
		ci_reset()
		mut h := vtest.start(ci_config(.epoll, 1, limits))!
		mut seen := map[u64]int{}
		mut reused := 0
		mut prev := -1
		for _ in 0 .. 8 {
			c := ci_once(h.port())!
			assert c.id != 0, 'the epoll worker knows its connections (read_timeout_ms ${limits.read_timeout_ms})'
			assert c.id !in seen, 'id ${c.id} named the connection on fd ${seen[c.id]} before fd ${c.fd} (read_timeout_ms ${limits.read_timeout_ms})'
			seen[c.id] = c.fd
			if c.fd == prev {
				reused++
			}
			prev = c.fd
		}
		h.stop()
		assert reused > 0, 'no connection got the fd number of the one before it: nothing was checked'
	}
}

// One keep-alive connection, one id: its requests one at a time and two
// pipelined in one write, a park resumed by its fd and one ended by its
// deadline (their continuations), a streamed upload's head, and a request
// after all of them. A connection that upgrades keeps its upgrade request's
// id in its ConnHandler and its wake fn, .closed included, and it is not the
// first one's.
fn test_epoll_conn_id_is_one_per_keep_alive_connection() ! {
	ci_reset()
	mut h := vtest.start(ci_config(.epoll, 1, server.Limits{}))!
	defer {
		h.stop()
	}
	mut c := ci_dial(h.port())!
	defer {
		c.close()
	}
	c.send(ci_get('/id'))!
	assert c.reports(1, 3000).len == 1, c.acc.bytestr()
	c.send(ci_get('/id') + ci_get('/id'))!
	assert c.reports(3, 3000).len == 3, c.acc.bytestr()
	c.send(ci_get('/park'))!
	assert c.reports(4, 3000).len == 4, c.acc.bytestr()
	c.send(ci_get('/slow'))!
	assert c.reports(5, 3000).len == 5, c.acc.bytestr()
	c.send('POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: ' + ci_big_len.str() + '\r\n\r\n')!
	c.send('b'.repeat(ci_big_len))!
	assert c.reports(6, 5000).len == 6, c.acc.bytestr()
	c.send(ci_get('/id'))!
	ids := c.reports(7, 3000)
	got := c.acc.bytestr()
	assert ids.len == 7, got
	for label in ['resumed id=', 'timeout id=', 'big id='] {
		assert got.contains(label), 'no `${label}` report: ${got}'
	}
	assert ids[0] != 0, got
	for id in ids {
		assert id == ids[0], 'one connection, two ids: ${got}'
	}
	$if tinyc {
		eprintln('[test] takeover is inert under tcc; skipping its half')
		return
	}
	mut u := ci_dial(h.port())!
	u.send(ci_get('/up'))!
	assert u.reports(1, 3000).len == 1, u.acc.bytestr()
	u.send('id\n')!
	assert u.reports(2, 3000).len == 2, u.acc.bytestr()
	u.send('wait\n')!
	ups := u.reports(3, 3000)
	up := u.acc.bytestr()
	assert ups.len == 3, up
	assert up.contains('lines id=') && up.contains('wake id='), up
	assert ups[0] != 0, up
	for id in ups {
		assert id == ups[0], 'one taken-over connection, two ids: ${up}'
	}
	assert ups[0] != ids[0], 'two connections, one id: ${got} / ${up}'
	// Its last call names it too: drop what is kept under the id there.
	u.close()
	s := unsafe { ci }
	assert ci_until(&s.closed_runs, 1, 3000) == 1, 'no .closed'
	assert u64(stdatomic.load_i64(&s.closed_id)) == ups[0], '.closed names the connection that closed'
}

// Requests parked on one shared fd, as on a pooled database connection
// (watch_fd_persistent): the worker resumes them in order from one readiness
// edge (drain_pipelined), and each continuation gets its own connection's id.
// A client that leaves while parked there still has its reply taken, by a
// tombstone's run, which has no connection: 0. And on_worker_start, with no
// client at all, sees 0.
fn test_epoll_conn_id_in_queued_and_tombstone_runs() ! {
	ci_reset()
	mut fds := [2]i32{}
	assert C.pipe(&fds[0]) == 0
	C.fcntl(int(fds[0]), C.F_SETFL, C.O_NONBLOCK) // a continuation that finds no byte re-parks
	mut s := unsafe { ci }
	stdatomic.store_i64(&s.pipe_r, i64(fds[0]))
	stdatomic.store_i64(&s.pipe_w, i64(fds[1]))
	mut h := vtest.start(ci_config(.epoll, 1, server.Limits{}))!
	defer {
		h.stop()
		C.close(int(fds[0]))
		C.close(int(fds[1]))
	}
	assert ci_until(&s.start_runs, 1, 3000) == 1
	assert stdatomic.load_i64(&s.start_id) == 0, 'on_worker_start has no connection'
	mut a := ci_dial(h.port())!
	defer {
		a.close()
	}
	mut b := ci_dial(h.port())!
	defer {
		b.close()
	}
	a.send(ci_get('/id'))!
	b.send(ci_get('/id'))!
	assert a.reports(1, 3000).len == 1, a.acc.bytestr()
	assert b.reports(1, 3000).len == 1, b.acc.bytestr()
	// a parks first, b queues behind it; one write is both replies.
	a.send(ci_get('/queue'))!
	assert ci_until(&s.parked, 1, 3000) == 1
	b.send(ci_get('/queue'))!
	assert ci_until(&s.parked, 2, 3000) == 2
	two := [u8(`a`), `b`]!
	assert C.write(int(fds[1]), &two[0], 2) == 2
	qa := a.reports(2, 3000)
	qb := b.reports(2, 3000)
	got := a.acc.bytestr() + ' / ' + b.acc.bytestr()
	assert qa.len == 2 && qb.len == 2 && got.count('queued id=') == 2, got
	assert qa[0] != 0 && qa[1] == qa[0], 'a queued continuation got another id: ${got}'
	assert qb[0] != 0 && qb[1] == qb[0], 'a queued continuation got another id: ${got}'
	assert qa[0] != qb[0], got
	// c parks on the pipe and leaves: its watch becomes a tombstone, which
	// runs when its reply comes.
	mut c := ci_dial(h.port())!
	c.send(ci_get('/orphan'))!
	assert ci_until(&s.parked, 3, 3000) == 3
	c.close()
	srv := h.server_ref()
	for _ in 0 .. 3000 {
		if stdatomic.load_i64(&srv.active_conns.n) <= 2 {
			break // c is closed, its watch a tombstone
		}
		time.sleep(time.millisecond)
	}
	assert stdatomic.load_i64(&srv.active_conns.n) == 2
	one := u8(`c`)
	assert C.write(int(fds[1]), &one, 1) == 1
	assert ci_until(&s.dead_runs, 1, 3000) == 1, 'the tombstone did not run'
	assert stdatomic.load_i64(&s.dead_id) == 0, 'a tombstone run has no connection'
}

// Two workers: accept round-robins, so a number one worker's connection
// freed goes to the next connection, on the other worker. The ids never
// repeat across them.
fn test_epoll_conn_id_unique_across_workers() ! {
	ci_reset()
	mut h := vtest.start(ci_config(.epoll, 2, server.Limits{}))!
	defer {
		h.stop()
	}
	mut seen := map[u64]int{}
	mut workers_of := map[int]int{} // fd -> the workers that served it, a bit each
	for _ in 0 .. 12 {
		c := ci_once(h.port())!
		assert c.id != 0
		assert c.id !in seen, 'id ${c.id} named the connection on fd ${seen[c.id]} before fd ${c.fd} on worker ${c.worker}'
		seen[c.id] = c.fd
		workers_of[c.fd] = workers_of[c.fd] | (1 << c.worker)
	}
	assert workers_of.values().any(it == 3), 'no fd number was served by both workers: nothing was checked (${workers_of})'
}

// Two servers in one process: the numbers one frees go to the other's next
// connection, and the ids still never repeat.
fn test_epoll_conn_id_unique_across_servers() ! {
	ci_reset()
	mut a := vtest.start(ci_config(.epoll, 1, server.Limits{}))!
	defer {
		a.stop()
	}
	mut b := vtest.start(ci_config(.epoll, 1, server.Limits{}))!
	defer {
		b.stop()
	}
	mut seen := map[u64]int{}
	mut servers_of := map[int]int{} // fd -> the servers that served it, a bit each
	for i in 0 .. 8 {
		c := ci_once(if i % 2 == 0 { a.port() } else { b.port() })!
		assert c.id != 0
		assert c.id !in seen, 'id ${c.id} named the connection on fd ${seen[c.id]} before fd ${c.fd}'
		seen[c.id] = c.fd
		servers_of[c.fd] = servers_of[c.fd] | (1 << (i % 2))
	}
	assert servers_of.values().any(it == 3), 'no fd number was served by both servers: nothing was checked (${servers_of})'
}

// io_uring does not track connections: the id is 0, unknown, don't cache.
fn test_iouring_conn_id_is_unknown() ! {
	if !server.iou_backend_available() {
		eprintln('[test] io_uring_setup blocked (sandboxed runner); skipping')
		return
	}
	ci_reset()
	mut h := vtest.start(ci_config(.io_uring, 1, server.Limits{}))!
	defer {
		h.stop()
	}
	c := ci_once(h.port())!
	assert c.id == 0
}
