module main

// End-to-end: the example's handler, continuations and make_state against
// the fake PostgreSQL (pg_async/testdata/fake_pg.py, python3 + stdlib), which
// fails the first N writes with SQLSTATE 40001 (--conflicts N) as a
// conflicting concurrent transaction would: the batch is run again, after a
// wait on a timerfd with its connection released, until it commits, or
// answered 409 once the attempts are used up. A client that leaves
// mid-transfer stops it, and every timer is closed: the server runs in this
// process, so the tests count its timerfds in /proc/self/fd. Linux-only
// (epoll backend); skipped without python3.
import os
import time
import server
import pg_async
import testkit
import transport
import vtest

const transfer_req = 'POST /transfer HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes()

// short_waits waits up to 100 ms between attempts: long enough to be seen.
const short_waits = pg_async.TxRetry{
	max_attempts:    5
	base_backoff_ms: 100
	max_backoff_ms:  100
}

// long_waits waits up to an hour: a transfer that conflicts is still waiting
// when the test acts.
const long_waits = pg_async.TxRetry{
	max_attempts:    5
	base_backoff_ms: 3_600_000
	max_backoff_ms:  3_600_000
}

fn short_state() voidptr {
	return new_state(short_waits)
}

fn long_state() voidptr {
	return new_state(long_waits)
}

// transfer_with runs `n` POST /transfer one after another on one connection,
// against a fake started with `args`, and returns the responses and the fake's
// conflict count.
fn transfer_with(args []string, n int, make_state fn () voidptr) !([]string, int) {
	mut fake := testkit.start_fake_pg(args)!
	defer {
		fake.stop()
	}
	point_at(fake)
	mut rounds := []vtest.Round{}
	for _ in 0 .. n {
		rounds << vtest.Round{
			send: transfer_req
			want: 1
		}
	}
	out := vtest.drive(server.ServerConfig{
		handler:    handler
		make_state: make_state
		workers:    1
	}, [vtest.Script{
		rounds: rounds
	}])!
	mut got := []string{}
	for f in out.conns[0].frames {
		got << f.bytestr()
	}
	return got, fake.stat('conflicts')
}

fn test_a_conflicting_transfer_is_retried_until_it_commits() {
	$if linux {
		if !testkit.fake_pg_available() {
			eprintln('pg_transactions: skipping (no python3)')
			return
		}
		t0 := timerfds()
		// Two conflicts: the first transfer commits on its third attempt, the
		// second on its first.
		got, conflicts := transfer_with(['--conflicts', '2'], 2, build_state) or {
			assert false, err.msg()
			return
		}
		assert got.len == 2
		assert got[0].starts_with('HTTP/1.1 200'), got[0]
		assert got[0].ends_with('\r\n\r\n{"attempts":3}'), got[0]
		assert got[0].contains('Content-Length: 14\r\n'), got[0]
		assert got[1].ends_with('\r\n\r\n{"attempts":1}'), got[1]
		assert conflicts == 2
		assert timerfds() == t0, 'every wait closed its timer'
	}
}

// Every attempt conflicts: the transfer waits on a timer between attempts,
// one timer at a time, and gives up with 409 after max_attempts.
fn test_a_transfer_that_keeps_conflicting_gives_up_with_409() {
	$if linux {
		if !testkit.fake_pg_available() {
			return
		}
		t0 := timerfds()
		stop := chan bool{cap: 1}
		sampler := spawn peak_timerfds(stop)
		got, conflicts := transfer_with(['--conflicts', '100'], 1, short_state) or {
			stop <- true
			sampler.wait()
			assert false, err.msg()
			return
		}
		stop <- true
		peak := sampler.wait()
		assert got.len == 1
		assert got[0].starts_with('HTTP/1.1 409'), got[0]
		assert conflicts == short_waits.max_attempts, 'one conflict per attempt'
		assert peak == t0 + 1, 'it waited on a timer between attempts'
		assert timerfds() == t0, 'every wait closed its timer'
	}
}

fn test_other_paths_are_404() {
	$if linux {
		out := vtest.drive(server.ServerConfig{
			handler: handler
			workers: 1
		}, [vtest.Script{
			rounds: [vtest.Round{
				send: 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
			}]
		}]) or {
			assert false, err.msg()
			return
		}
		assert out.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 404')
	}
}

// A transfer waiting to run again holds no connection: meanwhile every
// pooled connection serves another transfer. Its client then hangs up: the
// runtime closes the timer, and the transfer never runs again.
fn test_a_transfer_waits_without_its_connection_and_a_client_gone_ends_the_wait() {
	$if linux {
		if !testkit.fake_pg_available() {
			return
		}
		mut fake := testkit.start_fake_pg(['--conflicts', '1'])!
		defer {
			fake.stop()
		}
		point_at(fake)
		mut h := vtest.start(server.ServerConfig{
			handler:    handler
			make_state: long_state
			workers:    1
		})!
		defer {
			h.stop()
		}
		t0 := timerfds()
		fd := transport.dial_tcp('127.0.0.1', h.port())!
		wrote := testkit.fd_write_all(fd, transfer_req, 2000)
		assert wrote
		// Its first attempt conflicts; it parks on a timer for up to an hour.
		waiting := wait_for_timerfds(t0 + 1, 5000)
		assert waiting, 'the transfer did not wait on a timer'
		assert fake.stat('queries') == 1
		mut scripts := []vtest.Script{}
		for _ in 0 .. pool_size {
			scripts << vtest.Script{
				rounds: [vtest.Round{
					send: transfer_req
				}]
			}
		}
		o := h.fire(scripts)!
		for c in o.conns {
			got := c.frames[0].bytestr()
			assert got.ends_with('{"attempts":1}'), got
		}
		transport.close_fd(fd)
		closed := wait_for_timerfds(t0, 2000)
		assert closed, 'the timer outlived its client'
		time.sleep(100 * time.millisecond)
		assert fake.stat('queries') == 1 + pool_size, 'no attempt after the client left'
	}
}

// A client that hangs up while its attempt is in flight: its request is
// dropped, but the runtime still runs on_reply for the reply on the pooled
// connection (the connection must stay in step). That reply is a conflict:
// on_reply releases the connection and steps to a timer, which the runtime
// closes without resuming the request. So no attempt follows, no timer is
// left, and every pooled connection serves a transfer at once.
fn test_a_client_gone_mid_query_stops_retrying_and_frees_its_connection() {
	$if linux {
		if !testkit.fake_pg_available() {
			return
		}
		// Every reply takes 100 ms; the first write conflicts.
		mut fake := testkit.start_fake_pg(['--conflicts', '1', '--delay-ms', '100'])!
		defer {
			fake.stop()
		}
		point_at(fake)
		mut h := vtest.start(server.ServerConfig{
			handler:    handler
			make_state: build_state
			workers:    1
		})!
		defer {
			h.stop()
		}
		t0 := timerfds()
		fd := transport.dial_tcp('127.0.0.1', h.port())!
		wrote := testkit.fd_write_all(fd, transfer_req, 2000)
		assert wrote
		for _ in 0 .. 200 {
			if fake.stat('queries') >= 1 {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		transport.close_fd(fd) // parked on its first attempt
		for _ in 0 .. 200 {
			if fake.stat('conflicts') >= 1 {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		time.sleep(300 * time.millisecond) // a retry would have been sent by now
		assert fake.stat('conflicts') == 1
		assert fake.stat('queries') == 1, 'no attempt after the client left'
		assert timerfds() == t0
		// Every pooled connection is free again: pool_size transfers at once all
		// commit on their first attempt.
		mut scripts := []vtest.Script{}
		for _ in 0 .. pool_size {
			scripts << vtest.Script{
				rounds: [vtest.Round{
					send: transfer_req
				}]
			}
		}
		o := h.fire(scripts)!
		for c in o.conns {
			got := c.frames[0].bytestr()
			assert got.ends_with('{"attempts":1}'), got
		}
		assert fake.stat('queries') == 1 + pool_size
	}
}

// A client that hangs up while the attempt after a wait is in flight: the
// runtime runs on_reply for that reply, which closes the timer of the wait
// (on_backoff leaves it open, see there); that reply conflicts too, and its
// own timer is closed by the runtime. No timer is left.
fn test_a_client_gone_after_a_wait_leaves_no_timer() {
	$if linux {
		if !testkit.fake_pg_available() {
			return
		}
		mut fake := testkit.start_fake_pg(['--conflicts', '2', '--delay-ms', '100'])!
		defer {
			fake.stop()
		}
		point_at(fake)
		mut h := vtest.start(server.ServerConfig{
			handler:    handler
			make_state: build_state
			workers:    1
		})!
		defer {
			h.stop()
		}
		t0 := timerfds()
		fd := transport.dial_tcp('127.0.0.1', h.port())!
		wrote := testkit.fd_write_all(fd, transfer_req, 2000)
		assert wrote
		for _ in 0 .. 400 {
			if fake.stat('queries') >= 2 {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		assert fake.stat('queries') == 2, 'the second attempt, after a wait'
		transport.close_fd(fd)
		for _ in 0 .. 200 {
			if fake.stat('conflicts') >= 2 {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		time.sleep(200 * time.millisecond)
		assert fake.stat('conflicts') == 2
		assert fake.stat('queries') == 2, 'no attempt after the client left'
		assert timerfds() == t0
	}
}

// point_at sets the PG* variables new_state reads to the fake server.
fn point_at(fake testkit.FakePg) {
	os.setenv('PGHOST', '127.0.0.1', true)
	os.setenv('PGPORT', fake.port.str(), true)
	os.setenv('PGUSER', 'vanilla', true)
	os.setenv('PGPASSWORD', 'secret', true)
	os.setenv('PGDATABASE', 'vanilla', true)
}

// timerfds counts this process's open timerfds. The server runs in this
// process and arms no timer of its own here: they are the transfers' waits.
fn timerfds() int {
	mut n := 0
	for name in os.ls('/proc/self/fd') or { return -1 } {
		target := os.readlink('/proc/self/fd/' + name) or { continue }
		if target == 'anon_inode:[timerfd]' {
			n++
		}
	}
	return n
}

// wait_for_timerfds polls until `want` timerfds are open, for up to `ms`.
fn wait_for_timerfds(want int, ms int) bool {
	for _ in 0 .. ms {
		if timerfds() == want {
			return true
		}
		time.sleep(time.millisecond)
	}
	return false
}

// peak_timerfds counts the open timerfds again and again until `stop`
// receives, and returns the most it saw at once.
fn peak_timerfds(stop chan bool) int {
	mut peak := 0
	for {
		n := timerfds()
		if n > peak {
			peak = n
		}
		mut done := false
		if stop.try_pop(mut done) == .success {
			return peak
		}
		time.sleep(200 * time.microsecond)
	}
	return peak
}
