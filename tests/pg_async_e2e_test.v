// vtest build: linux
// pg_async parked on vanilla's epoll reactor, end to end, against the fake
// PostgreSQL (pg_async/testdata/fake_pg.py, python3 + stdlib): many clients
// each pipelining several requests over a small per-worker pool. Each response
// must carry its OWN query's result — the FIFO-alignment invariant (reactor
// queue[k] <-> conn.inflight[k], pg_async/PIPELINING_DESIGN.md) — a failing
// query must fail only its own request, and connections the server closes
// must cost at most the requests in flight on them, then be re-dialed by the
// pool's maintenance timer; a re-dialed socket that takes the dead one's fd
// number gets its own replies (no stale reactor entry for the number).
// Skipped without python3 (unless VANILLA_REQUIRE_FAKE_PG is set); runs under
// -race in pg_async.yml.
import os
import strconv
import time
import server
import core
import pg_async
import testkit
import vtest

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n'.bytes()

const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n'.bytes()

// /r's answers: did slot 0's new socket take the dead one's fd number?
const resp_reused = 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nreused'.bytes()

const resp_moved = 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nmoved'.bytes()

// A 200's head, around its Content-Length.
const resp_200_head = 'HTTP/1.1 200 OK\r\nContent-Length: '.bytes()

const resp_200_sep = '\r\n\r\n'.bytes()

// The slot was taken with acquire() (exclusive): release it when done.
const exclusive_flag = u64(1) << 32

struct PgE2eState {
mut:
	pool &pg_async.PgPool
}

fn pg_e2e_state() voidptr {
	cfg := pg_async.ConnConfig{
		host:              '127.0.0.1'
		port:              os.getenv('PG_E2E_FAKE_PORT').int()
		user:              'vanilla'
		password:          'secret'
		database:          'vanilla'
		redial_backoff_ms: 10
	}
	pool := pg_async.new_pool(cfg, 2) or { panic('pool bring-up failed: ${err}') }
	return voidptr(&PgE2eState{
		pool: pool
	})
}

fn pg_e2e_start(worker_state voidptr, mut event_loop core.EventLoop) {
	mut st := unsafe { &PgE2eState(worker_state) }
	st.pool.start_maintenance(mut event_loop) or { panic(err) }
}

// GET /q/<n> runs `select $1::int4` with n on a shared (pipelined) connection
// and answers n; GET /x/<n> the same on an exclusively held one; GET /err a
// failing query (500). A lost connection answers 503. The handler pattern of
// a real app: views and appends, no allocation per request. Test hooks: GET
// /h answers how many pooled connections are healthy; GET /r breaks slot 0
// (idle, nothing in flight) and calls maintain(), which closes the socket and
// starts the re-dial at once.
fn pg_e2e_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &PgE2eState(worker_state) }
	if req.len > 6 && req[5] == `h` {
		out << resp_200_head
		out << `1`
		out << resp_200_sep
		out << u8(`0` + st.pool.healthy())
		return .done
	}
	if req.len > 6 && req[5] == `r` {
		old := st.pool.fd(0)
		st.pool.conn(0).mark_broken()
		st.pool.maintain()
		out << if st.pool.fd(0) == old { resp_reused } else { resp_moved }
		return .done
	}
	exclusive := req.len > 6 && req[5] == `x`
	slot := if exclusive { st.pool.acquire() } else { st.pool.acquire_pipelined() }
	idx := slot or {
		out << resp_503
		return .done
	}
	mut conn := st.pool.conn(idx)
	// "GET /q/<digits> ": the digits are a view into the request.
	mut end := 7
	for end < req.len && req[end] != ` ` {
		end++
	}
	queued := if req.len > 8 && req[5] == `e` {
		conn.submit('select 1/0', []?[]u8{})
	} else {
		conn.submit(r'select $1::int4', [?[]u8(unsafe { (&req[7]).vbytes(end - 7) })])
	} or { false } // broken: nothing was sent
	if !queued {
		if exclusive {
			st.pool.release(idx)
		}
		out << resp_503
		return .done
	}
	// Queued: park for its outcome even if this flush fails (the continuation
	// then gets the error) — every submitted query needs its parked request.
	conn.async_flush() or {}
	payload := u64(idx) | if exclusive { exclusive_flag } else { u64(0) }
	event_loop.watch_fd_persistent(st.pool.fd(idx), interest(conn), pg_e2e_ready, voidptr(payload))
	return .suspend
}

fn interest(conn &pg_async.PgConn) core.WatchInterest {
	return if conn.async_wants_write() { .writable } else { .readable }
}

fn pg_e2e_ready(mut out []u8, ready_fd int, ready_fd_error bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &PgE2eState(worker_state) }
	idx := int(u64(watch_payload) & 0xffff_ffff)
	exclusive := u64(watch_payload) & exclusive_flag != 0
	mut conn := st.pool.conn(idx)
	if conn.async_wants_write() {
		conn.async_flush() or {}
	}
	mut poll := conn.async_on_readable() or { return pg_e2e_failed(mut st, idx, exclusive, err, mut out) }
	if !poll.ready && ready_fd_error {
		// A dead socket the read did not notice: give up on it, which ends
		// this query (unknown) — never re-arm a dead level-triggered fd.
		conn.mark_broken()
		poll = conn.async_on_readable() or { return pg_e2e_failed(mut st, idx, exclusive, err, mut out) }
	}
	if !poll.ready {
		event_loop.watch_fd_persistent(ready_fd, interest(conn), pg_e2e_ready, watch_payload)
		return .suspend
	}
	if exclusive {
		st.pool.release(idx)
	}
	mut it := poll.result.rows()
	row := it.next() or {
		out << resp_500
		return .done
	}
	mut body := [24]u8{}
	mut body_view := unsafe { (&body[0]).vbytes(body.len) }
	n := strconv.write_dec(row.int4(0) or { -1 }, mut body_view)
	mut len := [4]u8{}
	mut len_view := unsafe { (&len[0]).vbytes(len.len) }
	ln := strconv.write_dec(n, mut len_view)
	out << resp_200_head
	unsafe { out.push_many(&len[0], ln) }
	out << resp_200_sep
	unsafe { out.push_many(&body[0], n) }
	return .done
}

// pg_e2e_failed answers a query that ended in an error: 500 for a statement
// the server failed, 503 for a lost connection (its outcome is unknown).
fn pg_e2e_failed(mut st PgE2eState, idx int, exclusive bool, err IError, mut out []u8) core.Step {
	if exclusive {
		st.pool.release(idx)
	}
	if err is pg_async.PgError && err.kind == .server {
		out << resp_500
	} else {
		out << resp_503
	}
	return .done
}

fn get(path string, n int) []u8 {
	return 'GET /${path}/${n} HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
}

fn test_pg_async_pipelined_queries_answer_their_own_requests() ! {
	if !testkit.fake_pg_available() {
		eprintln('skipping: python3 not found (the fake PostgreSQL needs it)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	os.setenv('PG_E2E_FAKE_PORT', fake.port.str(), true)
	// 24 connections x 6 pipelined requests, every 7th one failing: far more
	// requests than the 4 pooled connections, so queries from different
	// clients interleave on each connection's pipeline. Accept spreads the 24
	// round-robin, 12 per worker: within a worker's 2 x max_inflight (16)
	// pipeline slots, so nothing is shed (503) and every answer is exact.
	mut scripts := []vtest.Script{}
	for c in 0 .. 24 {
		mut send := []u8{}
		for k in 0 .. 6 {
			id := c * 6 + k
			if id % 7 == 3 {
				send << 'GET /err HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
			} else {
				send << get('q', id)
			}
		}
		scripts << vtest.Script{
			rounds: [vtest.Round{
				send: send
				want: 6
			}]
		}
	}
	out := vtest.drive(server.ServerConfig{
		handler:         pg_e2e_handler
		make_state:      pg_e2e_state
		workers:         2
		io_multiplexing: .epoll
	}, scripts)!
	assert out.conns.len == 24
	for c, conn in out.conns {
		assert conn.connect_err == '', conn.connect_err
		assert conn.frames.len == 6, 'connection ${c}: ${conn.frames.len} responses'
		for k, f in conn.frames {
			id := c * 6 + k
			got := f.bytestr()
			if id % 7 == 3 {
				assert got.starts_with('HTTP/1.1 500'), 'request ${id}: ${got}'
			} else {
				assert got.starts_with('HTTP/1.1 200'), 'request ${id}: ${got}'
				assert got.all_after('\r\n\r\n') == id.str(), 'request ${id} got ${got.all_after('\r\n\r\n')}'
			}
		}
	}
	assert fake.stat('authenticated') == 4
}

fn test_pg_async_connections_closed_by_the_server_are_redialed() ! {
	if !testkit.fake_pg_available() {
		return
	}
	// Every connection answers 3 queries, then the server closes it together
	// with the 3rd reply.
	mut fake := testkit.start_fake_pg(['--close', 'immediate', '--close-after', '3'])!
	defer {
		fake.stop()
	}
	os.setenv('PG_E2E_FAKE_PORT', fake.port.str(), true)
	mut h := vtest.start(server.ServerConfig{
		handler:         pg_e2e_handler
		make_state:      pg_e2e_state
		on_worker_start: pg_e2e_start
		workers:         1
		io_multiplexing: .epoll
	})!
	defer {
		h.stop()
	}
	mut ok := 0
	mut lost := 0
	for round in 0 .. 12 {
		// Exclusive: one query per connection at a time. A connection dies
		// right after a reply (a success), so none is lost there; the slot is
		// skipped until maintenance re-dials it.
		mut scripts := []vtest.Script{}
		for c in 0 .. 2 {
			scripts << vtest.Script{
				rounds: [vtest.Round{
					send: get('x', round * 10 + c)
					want: 1
				}]
			}
		}
		out := h.fire(scripts)!
		for s, conn in out.conns {
			assert conn.connect_err == '', conn.connect_err
			assert conn.frames.len == 1
			id := round * 10 + s
			got := conn.frames[0].bytestr()
			assert got.starts_with('HTTP/1.1 200'), 'request ${id}: ${got}'
			assert got.all_after('\r\n\r\n') == id.str(), 'request ${id} got ${got.all_after('\r\n\r\n')}'
			ok++
		}
		pg_e2e_await_redials(mut h, 'round ${round}, exclusive')!
		// Pipelined: queries share a connection; those queued behind the reply
		// the server closed the connection with are lost — each answers 503
		// exactly once — and no 200 ever carries another query's value.
		mut pipelined := []u8{}
		for k in 0 .. 3 {
			pipelined << get('q', round * 10 + 5 + k)
		}
		pout := h.fire([
			vtest.Script{
				rounds: [vtest.Round{
					send: pipelined
					want: 3
				}]
			},
		])!
		conn := pout.conns[0]
		assert conn.connect_err == '', conn.connect_err
		assert conn.frames.len == 3
		for k, f in conn.frames {
			id := round * 10 + 5 + k
			got := f.bytestr()
			if got.starts_with('HTTP/1.1 200') {
				assert got.all_after('\r\n\r\n') == id.str(), 'request ${id} got ${got.all_after('\r\n\r\n')}'
				ok++
			} else {
				assert got.starts_with('HTTP/1.1 503'), 'request ${id}: ${got}'
				lost++
			}
		}
		pg_e2e_await_redials(mut h, 'round ${round}, pipelined')!
	}
	closes := fake.stat('server_closes')
	assert closes >= 10, 'the server closed only ${closes} connections'
	// Only queries already queued behind a closing reply are lost: at most 2
	// per closed connection (3 pipelined, the first of them answered).
	assert lost <= 2 * closes, 'lost ${lost} requests for ${closes} closed connections'
	assert ok + lost == 12 * 5
}

// pg_e2e_await_redials waits until the worker reports both pooled
// connections healthy again: every one the server closed was re-dialed.
fn pg_e2e_await_redials(mut h vtest.Harness, what string) ! {
	for _ in 0 .. 400 {
		o := h.fire([
			vtest.Script{
				rounds: [vtest.Round{
					send: 'GET /h HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
					want: 1
				}]
			},
		])!
		if o.conns[0].frames.len == 1 && o.conns[0].frames[0].bytestr().ends_with('\r\n\r\n2') {
			return
		}
		time.sleep(5 * time.millisecond)
	}
	assert false, '${what}: not re-dialed'
}

fn test_pg_async_a_redialed_socket_on_the_dead_ones_fd_number_gets_its_own_replies() ! {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	os.setenv('PG_E2E_FAKE_PORT', fake.port.str(), true)
	mut h := vtest.start(server.ServerConfig{
		handler:         pg_e2e_handler
		make_state:      pg_e2e_state
		on_worker_start: pg_e2e_start
		workers:         1
		io_multiplexing: .epoll
	})!
	defer {
		h.stop()
	}
	for round in 0 .. 3 {
		// Requests park on slot 0's socket (and slot 1's) and get their replies.
		mut pipelined := []u8{}
		for k in 0 .. 6 {
			pipelined << get('q', round * 10 + k)
		}
		before := h.fire([
			vtest.Script{
				rounds: [vtest.Round{
					send: pipelined
					want: 6
				}]
			},
		])!
		for k, f in before.conns[0].frames {
			assert f.bytestr().all_after('\r\n\r\n') == (round * 10 + k).str()
		}
		// Slot 0 is closed and re-dialed. The harness thread is blocked in
		// fire() and the server has one worker, so nothing else in the process
		// takes the freed number: the new socket gets it.
		r := h.fire([
			vtest.Script{
				rounds: [vtest.Round{
					send: 'GET /r HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
					want: 1
				}]
			},
		])!
		assert r.conns[0].frames[0] == resp_reused, r.conns[0].frames[0].bytestr()
		for _ in 0 .. 400 {
			if fake.stat('authenticated') >= 3 + round {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		assert fake.stat('authenticated') == 3 + round, 'round ${round}: not re-dialed'
		// Requests parked on the new socket, same number: each gets its own
		// reply, none hangs.
		mut again := []u8{}
		for k in 0 .. 6 {
			again << get('q', round * 10 + 100 + k)
		}
		after := h.fire([
			vtest.Script{
				rounds: [vtest.Round{
					send: again
					want: 6
				}]
			},
		])!
		assert after.conns[0].frames.len == 6
		for k, f in after.conns[0].frames {
			got := f.bytestr()
			assert got.starts_with('HTTP/1.1 200'), got
			assert got.all_after('\r\n\r\n') == (round * 10 + 100 + k).str()
		}
	}
	assert fake.stat('server_closes') == 0
}
