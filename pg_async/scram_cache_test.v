// vtest build: !windows
module pg_async

import os
import time
import testkit

// ScramCache: a pool derives SaltedPassword (PBKDF2) once, and its other
// connections and every re-dial reuse it, for as long as the password and
// the server's salt and count stay the same.

const rfc_server_first = r'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096'
const rfc_client_final = r'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ='
const rfc_server_final = 'v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4='

// The cached path produces the RFC 7677 messages, derives once for the same
// (salt, i), and the cached answer is still the RFC one.
fn test_cached_exchange_matches_rfc7677_and_derives_once() {
	mut cache := &ScramCache{}
	for round in 0 .. 3 {
		mut c := ScramClient.with_nonce('user', 'pencil', 'rOprNGfwEbeRWgbNEkqO')
		c.cache = cache
		c.client_first()
		assert c.handle_server_first(rfc_server_first.bytes())!.bytestr() == rfc_client_final, 'round ${round}'
		c.handle_server_final(rfc_server_final.bytes())!
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

// A new password derives again as well (vanilla#379: password_fn may answer
// another one on any attempt), and the cache keeps one entry: back to the
// first password, it derives once more.
fn test_a_new_password_derives_again() {
	mut cache := &ScramCache{}
	a, _ := cache.keys('pencil', 'salt-a'.bytes(), 4096)!
	b, _ := cache.keys('other', 'salt-a'.bytes(), 4096)!
	assert cache.derived == 2
	assert b != a
	expected, _ := derive_keys('other', 'salt-a'.bytes(), 4096)!
	assert b == expected
	c, _ := cache.keys('pencil', 'salt-a'.bytes(), 4096)!
	assert cache.derived == 3
	assert c == a
}

// A hit allocates nothing: the password's digest goes to a stack array, so a
// re-dial that reuses the keys adds nothing to the heap (under -gc none, a
// leak). Only a derivation allocates.
fn test_a_cache_hit_allocates_nothing() {
	mut cache := &ScramCache{}
	salt := 'salt-a'.bytes()
	mut sink := 0
	for round in 0 .. 2 {
		before := gc_heap_usage().bytes_since_gc
		for _ in 0 .. 1000 {
			client_key, _ := cache.keys('pencil', salt, 4096) or { panic(err) }
			sink += client_key.len
		}
		grown := gc_heap_usage().bytes_since_gc - before
		if round == 1 {
			assert grown == 0, 'cache hits allocated ${grown} bytes over 1000 calls'
		}
	}
	assert cache.derived == 1
	assert sink == 2000 * 32
}

// The RFC 7677 exchange with a cache that holds 'pencil''s keys, answered by
// a client with another password: it sends that password's own proof, and
// refuses the server's signature, which proves 'pencil'. With the cache keyed
// on (salt, count) alone, it sent 'pencil''s proof and accepted the server,
// so a wrong password logged in (vanilla#379).
fn test_a_cached_password_never_answers_for_another() {
	mut cache := &ScramCache{}
	mut good := ScramClient.with_nonce('user', 'pencil', 'rOprNGfwEbeRWgbNEkqO')
	good.cache = cache
	good.client_first()
	assert good.handle_server_first(rfc_server_first.bytes())!.bytestr() == rfc_client_final
	mut bad := ScramClient.with_nonce('user', 'wrong', 'rOprNGfwEbeRWgbNEkqO')
	bad.cache = cache
	bad.client_first()
	assert bad.handle_server_first(rfc_server_first.bytes())!.bytestr() != rfc_client_final
	mut refused := false
	bad.handle_server_final(rfc_server_final.bytes()) or { refused = true }
	assert refused && !bad.is_done()
	assert cache.derived == 2
}

// The other order: a cache first filled for a wrong password answers the
// right one with its own keys, the RFC exchange. Keyed on (salt, count)
// alone, it sent the wrong password's proof for as long as the salt stayed.
fn test_a_wrong_password_never_poisons_the_cache() {
	mut cache := &ScramCache{}
	mut bad := ScramClient.with_nonce('user', 'wrong', 'rOprNGfwEbeRWgbNEkqO')
	bad.cache = cache
	bad.client_first()
	bad.handle_server_first(rfc_server_first.bytes())!
	mut good := ScramClient.with_nonce('user', 'pencil', 'rOprNGfwEbeRWgbNEkqO')
	good.cache = cache
	good.client_first()
	assert good.handle_server_first(rfc_server_first.bytes())!.bytestr() == rfc_client_final
	good.handle_server_final(rfc_server_final.bytes())!
	assert good.is_done()
	assert cache.derived == 2
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

// Secret is what a pool's password_fn answers, which a test changes between
// re-dials (on the heap, so the closure holds it).
@[heap]
struct Secret {
mut:
	pw    string
	calls int
}

fn secret_pool(port int, mut secret Secret) !&PgPool {
	return new_pool(ConnConfig{
		host:        '127.0.0.1'
		port:        port
		user:        'vanilla'
		database:    'vanilla'
		password_fn: fn [mut secret] () !string {
			secret.calls++
			return secret.pw
		}
	}, 1)
}

// redial_drive runs the pool's maintenance, which re-dials its lost
// connection 0, until that connection is ready (want_ready), or else until
// the fake server refused `refused` logins in all, for at most `ms`.
fn redial_drive(mut pool PgPool, fake &testkit.FakePg, want_ready bool, refused int, ms int) {
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < ms {
		if want_ready && pool.conns[0].state == .ready {
			return
		}
		if !want_ready && fake.stat('auth_failures') >= refused {
			return
		}
		pool.maintain()
		time.sleep(5 * time.millisecond)
	}
}

// password_fn's answer turns wrong (a revoked secret, a typo): the re-dial
// is refused (28P01), as a fresh connection with it is. It used to log in
// with the keys the cache kept from the right password (vanilla#379). Back
// to the right answer, the next attempt logs in.
fn test_pool_redial_with_a_wrong_password_is_refused() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping ScramCache pool test (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut secret := &Secret{
		pw: 'secret'
	}
	mut pool := secret_pool(fake.port, mut secret)!
	defer {
		pool.close()
	}
	assert fake.stat('authenticated') == 1
	secret.pw = 'wrong'
	pool.conn(0).lose('test: connection lost')
	redial_drive(mut pool, fake, false, 1, 3000)
	eprintln('re-dial with password_fn -> "wrong": state=${pool.conns[0].state} logins=${fake.stat('authenticated')} refused=${fake.stat('auth_failures')} derived=${pool.scram.derived}')
	assert pool.conns[0].state != .ready, 'the re-dial logged in with a wrong password'
	assert fake.stat('authenticated') == 1
	assert fake.stat('auth_failures') == 1
	secret.pw = 'secret'
	redial_drive(mut pool, fake, true, 0, 3000)
	assert pool.conns[0].state == .ready
	assert fake.stat('authenticated') == 2
	assert pool.scram.derived == 3 // secret, wrong, secret again: the cache keeps one
}

// The role's password changes on the server (a new salt) before password_fn
// answers the new one, as when a secret store rotates it: the re-dial with
// the stale password is refused, as it should be, and once password_fn
// answers the new one the next attempt logs in. It used to keep the keys of
// the stale password and the new salt, and send them for the new password
// too: refused at every attempt, for good (vanilla#379).
fn test_pool_redial_after_a_password_rotation() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping ScramCache pool test (no python3)')
		return
	}
	pw_file := os.join_path(os.vtmp_dir(), 'vanilla_scram_rotation_${os.getpid()}_${time.sys_mono_now()}')
	os.write_file(pw_file, 'pw-one')!
	defer {
		os.rm(pw_file) or {}
	}
	mut fake := testkit.start_fake_pg(['--password-file', pw_file])!
	defer {
		fake.stop()
	}
	mut secret := &Secret{
		pw: 'pw-one'
	}
	mut pool := secret_pool(fake.port, mut secret)!
	defer {
		pool.close()
	}
	assert fake.stat('authenticated') == 1
	os.write_file(pw_file, 'pw-two')! // ALTER ROLE ... PASSWORD: a new verifier, a new salt
	pool.conn(0).lose('test: connection lost')
	redial_drive(mut pool, fake, false, 1, 3000) // password_fn still answers pw-one
	assert pool.conns[0].state != .ready
	assert fake.stat('auth_failures') == 1
	secret.pw = 'pw-two' // the secret store caught up
	redial_drive(mut pool, fake, true, 0, 3000)
	eprintln('re-dial after the rotation: state=${pool.conns[0].state} logins=${fake.stat('authenticated')} refused=${fake.stat('auth_failures')} derived=${pool.scram.derived} password_fn calls=${secret.calls}')
	assert pool.conns[0].state == .ready, "locked out: the new password was answered with the stale one's keys"
	assert fake.stat('authenticated') == 2
	assert pool.scram.derived == 3 // pw-one, pw-one with the new salt, pw-two
}
