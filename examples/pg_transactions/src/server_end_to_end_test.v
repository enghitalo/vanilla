module main

// End-to-end: the example's handler, continuation and make_state against the
// fake PostgreSQL (pg_async/testdata/fake_pg.py, python3 + stdlib), which
// fails the first N writes with SQLSTATE 40001 (--conflicts N) as a
// conflicting concurrent transaction would: the batch is run again until it
// commits, or answered 409 once the attempts are used up — also when the
// client is gone. Linux-only (epoll backend); skipped without python3.
import os
import time
import server
import testkit
import transport
import vtest

const transfer_req = 'POST /transfer HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n'.bytes()

// transfer_with runs `n` POST /transfer one after another on one connection,
// against a fake started with `args`, and returns the responses and the fake's
// conflict count.
fn transfer_with(args []string, n int) !([]string, int) {
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
		make_state: build_state
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
		// Two conflicts: the first transfer commits on its third attempt, the
		// second on its first.
		got, conflicts := transfer_with(['--conflicts', '2'], 2) or {
			assert false, err.msg()
			return
		}
		assert got.len == 2
		assert got[0].starts_with('HTTP/1.1 200'), got[0]
		assert got[0].ends_with('\r\n\r\n{"attempts":3}'), got[0]
		assert got[0].contains('Content-Length: 14\r\n'), got[0]
		assert got[1].ends_with('\r\n\r\n{"attempts":1}'), got[1]
		assert conflicts == 2
	}
}

fn test_a_transfer_that_keeps_conflicting_gives_up_with_409() {
	$if linux {
		if !testkit.fake_pg_available() {
			return
		}
		got, conflicts := transfer_with(['--conflicts', '100'], 1) or {
			assert false, err.msg()
			return
		}
		assert got.len == 1
		assert got[0].starts_with('HTTP/1.1 409'), got[0]
		assert conflicts == policy.max_attempts, 'one conflict per attempt'
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

// point_at sets the PG* variables build_state reads to the fake server.
fn point_at(fake testkit.FakePg) {
	os.setenv('PGHOST', '127.0.0.1', true)
	os.setenv('PGPORT', fake.port.str(), true)
	os.setenv('PGUSER', 'vanilla', true)
	os.setenv('PGPASSWORD', 'secret', true)
	os.setenv('PGDATABASE', 'vanilla', true)
}

// A client that hangs up mid-transfer: its request is dropped, but the runtime
// still runs its continuation for every reply on the pooled connection (the
// connection must stay in step). The retries it makes there are counted in
// the worker state, so they stop at max_attempts — every attempt conflicts
// here — and the connection goes back to the pool: afterwards every
// connection serves a transfer at once.
fn test_a_client_gone_mid_retry_still_frees_its_connection() {
	$if linux {
		if !testkit.fake_pg_available() {
			return
		}
		// Every reply takes 100 ms; the first max_attempts writes conflict.
		mut fake := testkit.start_fake_pg(['--conflicts', policy.max_attempts.str(), '--delay-ms',
			'100'])!
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
		fd := transport.dial_tcp('127.0.0.1', h.port())!
		assert testkit.fd_write_all(fd, transfer_req, 2000)
		for _ in 0 .. 200 {
			if fake.stat('queries') >= 1 {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		transport.close_fd(fd) // parked on its first attempt
		// Its continuation runs on, attempt after attempt, until it gives up.
		for _ in 0 .. 600 {
			if fake.stat('queries') >= policy.max_attempts {
				break
			}
			time.sleep(5 * time.millisecond)
		}
		time.sleep(300 * time.millisecond) // the last reply; no further attempt
		assert fake.stat('queries') == policy.max_attempts
		assert fake.stat('conflicts') == policy.max_attempts
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
		assert fake.stat('queries') == policy.max_attempts + pool_size
	}
}
