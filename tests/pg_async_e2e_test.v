// vtest build: linux
// pg_async parked on vanilla's epoll reactor, end to end, against the fake
// PostgreSQL (pg_async/testdata/fake_pg.py, python3 + stdlib): two workers,
// two pooled connections each, many clients each pipelining several requests,
// every query pipelined on a shared connection (acquire_pipelined). Each
// response must carry its OWN query's result — the FIFO-alignment invariant
// (reactor queue[k] <-> conn.inflight[k], pg_async/PIPELINING_DESIGN.md) — and
// a failing query must fail only its own request. Skipped without python3
// (unless VANILLA_REQUIRE_FAKE_PG is set); runs under -race in pg_async.yml.
//
// Built with -d vanilla_tls it runs again over TLS (vanilla#196): verify_full
// against a test CA, a 20000-row result spanning many TLS records, and a TLS
// 1.3 NewSessionTicket in front of every reply — under edge-triggered epoll a
// read that stopped at a ticket would strand the reply behind it and hang.
import os
import strconv
import sync.stdatomic
import time
import server
import core
import pg_async
import testkit
import transport
import vtest

const resp_500 = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n'.bytes()

const resp_503 = 'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n'.bytes()

// A 200's head, around its Content-Length.
const resp_200_head = 'HTTP/1.1 200 OK\r\nContent-Length: '.bytes()

const resp_200_sep = '\r\n\r\n'.bytes()

struct PgE2eState {
mut:
	pool   &pg_async.PgPool
	params []?[]u8 // one reused slot: no parameter array per request
}

fn pg_e2e_state() voidptr {
	ca := os.getenv('PG_E2E_CA') // set by the TLS test
	cfg := pg_async.ConnConfig{
		host:          if ca != '' { 'localhost' } else { '127.0.0.1' }
		port:          os.getenv('PG_E2E_FAKE_PORT').int()
		user:          'vanilla'
		password:      'secret'
		database:      'vanilla'
		ssl_mode:      if ca != '' {
			pg_async.SslMode.verify_full
		} else {
			pg_async.SslMode.disable
		}
		ssl_root_cert: ca
	}
	pool := pg_async.new_pool(cfg, 2) or { panic('pool bring-up failed: ${err}') }
	return voidptr(&PgE2eState{
		pool:   pool
		params: []?[]u8{len: 1}
	})
}

// GET /q/<n> runs `select $1::int4` with n and answers n; GET /err runs a
// failing query and answers 500; GET /big runs a 20000-row query and answers
// the row count once every row checked out. The handler pattern of a real app:
// views and appends, no allocation per request.
fn pg_e2e_handler(req []u8, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &PgE2eState(worker_state) }
	idx := st.pool.acquire_pipelined() or {
		out << resp_503
		return .done
	}
	mut conn := st.pool.conn(idx)
	// "GET /q/<digits> ": the digits are a view into the request.
	mut end := 7
	for end < req.len && req[end] != ` ` {
		end++
	}
	big := req.len > 8 && req[5] == `b`
	ok := if req.len > 8 && req[5] == `e` {
		conn.async_submit('select 1/0', []?[]u8{})
	} else if big {
		conn.async_submit('select g from generate_series(1, 20000) g', []?[]u8{})
	} else {
		st.params[0] = ?[]u8(unsafe { (&req[7]).vbytes(end - 7) })
		conn.async_submit(r'select $1::int4', st.params)
	}
	if !ok {
		out << resp_503
		return .done
	}
	// The query is queued: park for its outcome whatever the flush did (a
	// failed flush breaks the connection and async_on_readable reports it).
	conn.async_flush() or {}
	payload := u64(idx) | if big { big_flag } else { u64(0) }
	event_loop.watch_fd_persistent(st.pool.fd(idx), .readable, pg_e2e_ready, voidptr(payload))
	return .suspend
}

// big_flag in the watch payload marks a /big request.
const big_flag = u64(1) << 32

fn pg_e2e_ready(mut out []u8, ready_fd int, _ bool, watch_payload voidptr, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	mut st := unsafe { &PgE2eState(worker_state) }
	mut conn := st.pool.conn(int(u64(watch_payload) & 0xffff_ffff))
	if conn.async_wants_write() {
		conn.async_flush() or {}
	}
	poll := conn.async_on_readable() or {
		out << resp_500
		return .done
	}
	if !poll.ready {
		// Even on ready_fd_error: a broken connection never reports not-ready.
		event_loop.watch_fd_persistent(ready_fd, .readable, pg_e2e_ready, watch_payload)
		return .suspend
	}
	mut it := poll.result.rows()
	row := it.next() or {
		out << resp_500
		return .done
	}
	mut value := row.int4(0) or { -1 }
	if u64(watch_payload) & big_flag != 0 {
		// The row count, when every row is 1, 2, 3, ... in order.
		mut rows := 1
		for value == rows {
			r := it.next() or { break }
			rows++
			value = r.int4(0) or { -1 }
		}
		value = if value == rows && rows == 20000 { rows } else { -1 }
	}
	mut body := [24]u8{}
	mut body_view := unsafe { (&body[0]).vbytes(body.len) }
	n := strconv.write_dec(value, mut body_view)
	mut len := [4]u8{}
	mut len_view := unsafe { (&len[0]).vbytes(len.len) }
	ln := strconv.write_dec(n, mut len_view)
	out << resp_200_head
	unsafe { out.push_many(&len[0], ln) }
	out << resp_200_sep
	unsafe { out.push_many(&body[0], n) }
	return .done
}

fn q(n int) []u8 {
	return 'GET /q/${n} HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
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
	drive_pipelined(false)!
	assert fake.stat('authenticated') == 4
}

// The same over TLS (verify_full): every reply comes behind a TLS 1.3
// NewSessionTicket, and some are 20000 rows (~300 KB, dozens of TLS records).
fn test_pg_async_pipelined_queries_over_tls() ! {
	$if !vanilla_tls ? {
		return
	}
	if !testkit.fake_pg_available() || !testkit.test_certs_available() {
		eprintln('skipping: python3 or openssl not found')
		return
	}
	certs := testkit.test_certs()!
	defer {
		os.rmdir_all(certs) or {}
	}
	mut fake := testkit.start_fake_pg(['--ssl', 'tls', '--require-ssl', '--cert',
		os.join_path(certs, 'server.crt'), '--key', os.join_path(certs, 'server.key'),
		'--tickets-per-query', '1'])!
	defer {
		fake.stop()
	}
	os.setenv('PG_E2E_FAKE_PORT', fake.port.str(), true)
	os.setenv('PG_E2E_CA', os.join_path(certs, 'ca.crt'), true)
	defer {
		os.unsetenv('PG_E2E_CA')
	}
	drive_pipelined(true)!
	assert fake.stat('tls_handshakes') == 4
	assert fake.stat('authenticated') == 4
	assert fake.stat('tickets') == fake.stat('queries')
}

// drive_pipelined: 24 connections x 6 pipelined requests, every 7th one
// failing (and, with `big`, every 11th one a 20000-row result): far more
// requests than the 4 pooled connections, so queries from different clients
// interleave on each connection's pipeline. Accept spreads the 24
// round-robin, 12 per worker: within a worker's 2 x max_inflight (16)
// pipeline slots, so nothing is shed (503) and every answer is exact.
fn drive_pipelined(big bool) ! {
	mut scripts := []vtest.Script{}
	for c in 0 .. 24 {
		mut send := []u8{}
		for k in 0 .. 6 {
			id := c * 6 + k
			if id % 7 == 3 {
				send << 'GET /err HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
			} else if big && id % 11 == 5 {
				send << 'GET /big HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
			} else {
				send << q(id)
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
			} else if big && id % 11 == 5 {
				assert got.starts_with('HTTP/1.1 200'), 'request ${id}: ${got}'
				assert got.all_after('\r\n\r\n') == '20000', 'request ${id} got ${got.all_after('\r\n\r\n')}'
			} else {
				assert got.starts_with('HTTP/1.1 200'), 'request ${id}: ${got}'
				assert got.all_after('\r\n\r\n') == id.str(), 'request ${id} got ${got.all_after('\r\n\r\n')}'
			}
		}
	}
}

// SlowLookup is a scripted ConnConfig.resolve: 127.0.0.1 at `port`, after
// slow_ms; `calls` counts its calls.
@[heap]
struct SlowLookup {
mut:
	port    i64 // atomic
	slow_ms i64 // atomic
	calls   i64 // atomic
}

fn pg_e2e_maintenance(worker_state voidptr, mut event_loop core.EventLoop) {
	mut st := unsafe { &PgE2eState(worker_state) }
	st.pool.start_maintenance(mut event_loop) or { panic(err) }
}

// A pool that follows a transport.Resolver re-dials without resolving on the
// worker (vanilla#351). The fake closes each connection after its first
// query, so nearly every request meets a lost connection and starts or
// advances a re-dial, while each lookup the Resolver makes takes 2 s on its
// thread. Every request still answers within milliseconds: 200, or 503 while
// both connections are re-dialing, and the re-dials keep completing.
fn test_pg_async_redial_does_not_wait_for_the_resolver() ! {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--close', 'immediate'])!
	defer {
		fake.stop()
	}
	l := &SlowLookup{
		port: fake.port
	}
	cfg := pg_async.ConnConfig{
		host:     'db.test' // only l resolves it
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
		resolve:  fn [l] (host string, port int) []transport.Addr {
			stdatomic.add_i64(&l.calls, 1)
			slow := stdatomic.load_i64(&l.slow_ms)
			if slow > 0 {
				time.sleep(time.Duration(slow) * time.millisecond)
			}
			a := transport.ip_addr('127.0.0.1', int(stdatomic.load_i64(&l.port))) or { return [] }
			return [a]
		}
	}
	mut r := transport.Resolver.new(50)!
	r.start()
	defer {
		r.stop() // waits for the lookup in flight
	}
	rr := r
	mut h := vtest.start(server.ServerConfig{
		handler:         pg_e2e_handler
		make_state:      fn [cfg, rr] () voidptr {
			mut pool := pg_async.new_pool(cfg, 2) or { panic('pool bring-up failed: ${err}') }
			mut res := unsafe { rr }
			pool.follow(mut res) or { panic(err) }
			return voidptr(&PgE2eState{
				pool:   pool
				params: []?[]u8{len: 1}
			})
		}
		on_worker_start: pg_e2e_maintenance
		workers:         1
		io_multiplexing: .epoll
	})!
	defer {
		h.stop()
	}
	// The worker serves once make_state's lookups (2 bring-ups and follow,
	// blocking at startup by design) are done; only then do lookups turn slow.
	first := h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: q(1000)
		}]
	}])!
	assert first.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200')
	booted := stdatomic.load_i64(&l.calls)
	stdatomic.store_i64(&l.slow_ms, 2000)
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 2000 && stdatomic.load_i64(&l.calls) == booted {
		time.sleep(time.millisecond)
	}
	assert stdatomic.load_i64(&l.calls) > booted, 'the resolver thread never looked up'
	mut worst := i64(0)
	mut ok := 0
	for k in 0 .. 40 {
		t := time.new_stopwatch()
		o := h.fire([vtest.Script{
			rounds: [vtest.Round{
				send: q(k)
			}]
		}])!
		ms := t.elapsed().milliseconds()
		if ms > worst {
			worst = ms
		}
		got := o.conns[0].frames[0].bytestr()
		if got.starts_with('HTTP/1.1 200') {
			assert got.all_after('\r\n\r\n') == k.str(), 'request ${k}: ${got}'
			ok++
		} else {
			// 503: both connections are re-dialing. 500: the query went out on a
			// connection whose FIN had not arrived yet (it costs that query).
			assert got.starts_with('HTTP/1.1 503') || got.starts_with('HTTP/1.1 500'), 'request ${k}: ${got}'
		}
		time.sleep(5 * time.millisecond)
	}
	eprintln('40 requests over re-dials: ${ok} answered 200, the slowest in ${worst} ms, while each lookup takes 2000 ms')
	assert worst < 500, 'a request waited ${worst} ms: the worker resolved'
	assert ok >= 10, 'the re-dials did not complete'
	assert fake.stat('authenticated') >= ok // every query had a connection of its own
}
