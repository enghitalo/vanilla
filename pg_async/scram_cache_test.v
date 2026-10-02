// vtest build: !windows
module pg_async

import time
import testkit

// ScramCache: a pool derives SaltedPassword (PBKDF2) once, and its other
// connections and every re-dial reuse it.

const rfc_server_first = r'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096'
const rfc_client_final = r'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ='

// The cached path produces the RFC 7677 messages, derives once for the same
// (salt, i), and the cached answer is still the RFC one.
fn test_cached_exchange_matches_rfc7677_and_derives_once() {
	mut cache := &ScramCache{}
	for round in 0 .. 3 {
		mut c := ScramClient.with_nonce('user', 'pencil', 'rOprNGfwEbeRWgbNEkqO')
		c.cache = cache
		c.client_first()
		assert c.handle_server_first(rfc_server_first.bytes())!.bytestr() == rfc_client_final, 'round ${round}'
		c.handle_server_final('v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4='.bytes())!
		assert c.is_done()
	}
	assert cache.derived == 1
}

// A different salt or iteration count (the role's password changed) derives
// again instead of answering with stale keys.
fn test_a_new_salt_or_count_derives_again() {
	mut cache := &ScramCache{}
	a1, _ := cache.keys('pencil', 'salt-a'.bytes(), 4096)!
	a2, _ := cache.keys('pencil', 'salt-a'.bytes(), 4096)!
	assert a1 == a2
	assert cache.derived == 1
	b, _ := cache.keys('pencil', 'salt-b'.bytes(), 4096)!
	assert cache.derived == 2
	assert b != a1
	c, _ := cache.keys('pencil', 'salt-b'.bytes(), 1024)!
	assert cache.derived == 3
	assert c != b
	expected, _ := derive_keys('pencil', 'salt-b'.bytes(), 1024)!
	assert c == expected
}

// pump_query flushes, then pumps readable until the front query completes.
fn pump_query(mut c PgConn) !Result {
	for _ in 0 .. 10000 {
		if c.async_flush()! {
			break
		}
	}
	for _ in 0 .. 2_000_000 {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
	}
	return error('query did not complete')
}

fn test_pool_derives_once_for_every_connection_and_redial() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping ScramCache pool test (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg(['--close', 'delayed', '--close-after', '1'])!
	defer {
		fake.stop()
	}
	cfg := ConnConfig{
		host:     '127.0.0.1'
		port:     fake.port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}
	mut pool := new_pool(cfg, 3)!
	defer {
		pool.close()
	}
	assert fake.stat('authenticated') == 3
	assert pool.scram.derived == 1, 'bring-up of 3 connections must derive once'
	// One query on connection 0: the fake answers it, then closes it.
	idx := pool.acquire() or { panic('expected an idle connection') }
	mut c := pool.conn(idx)
	assert c.async_submit('select 1', []?[]u8{})
	res := pump_query(mut c)!
	mut it := res.rows()
	assert (it.next() or { panic('expected a row') }).int4(0)! == 1
	pool.release(idx)
	// Drive the loss and the re-dial: acquire() advances it one step per call.
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 5000 && fake.stat('authenticated') < 4 {
		pool.conns[idx].async_on_readable() or {} // observe the server's close
		if j := pool.acquire() {
			pool.release(j)
		}
		time.sleep(5 * time.millisecond)
	}
	for sw.elapsed().milliseconds() < 5000 && pool.conns[idx].state != .ready {
		if j := pool.acquire() {
			pool.release(j)
		}
		time.sleep(5 * time.millisecond)
	}
	assert fake.stat('authenticated') == 4, 'connection 0 was re-dialed and re-authenticated'
	assert pool.conns[idx].state == .ready
	assert pool.scram.derived == 1, 're-dial must reuse the derivation'
}
