module pg_async

import os

// Live-Postgres integration tests. Skipped unless PGHOST is set, so CI without a
// database stays green. Run against a local container, e.g.:
//
//   docker run -d --name pgtest -p 55432:5432 \
//     -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=benchpw -e POSTGRES_DB=bench \
//     -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 postgres:18.3-alpine
//   PGHOST=127.0.0.1 PGPORT=55432 PGUSER=bench PGPASSWORD=benchpw PGDATABASE=bench \
//     v test pg_async/

fn pg_test_cfg() ?ConnConfig {
	host := os.getenv('PGHOST')
	if host == '' {
		eprintln('pg_async: skipping live test (set PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE)')
		return none
	}
	port_env := os.getenv('PGPORT')
	return ConnConfig{
		host:     host
		port:     if port_env != '' { port_env.int() } else { 5432 }
		user:     os.getenv('PGUSER')
		password: os.getenv('PGPASSWORD')
		database: os.getenv('PGDATABASE')
	}
}

// Binary scalar decoding, a text-format parameter round-trip, multiple rows,
// and a SQL NULL in the middle of a result set.
fn test_live_scalars_params_and_null() {
	cfg := pg_test_cfg() or { return }
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}

	res := c.query(r'select 1::int4, 2::int8, true, $1::text', [?[]u8('hi'.bytes())])!
	mut it := res.rows()
	row := it.next() or { panic('expected a row') }
	assert row.int4(0)! == 1
	assert row.int8(1)! == 2
	assert row.boolean(2)! == true
	assert row.text(3)!.bytestr() == 'hi'
	if _ := it.next() {
		assert false, 'expected exactly one row'
	}

	res2 := c.query(r'select g, (case when g = 2 then null else g end)::int4 from generate_series(1,3) g order by 1',
		[]?[]u8{})!
	mut it2 := res2.rows()
	mut ids := []int{}
	mut null_count := 0
	for {
		r := it2.next() or { break }
		ids << r.int4(0)!
		if r.col(1)!.is_null {
			null_count++
		}
	}
	assert ids == [1, 2, 3]
	assert null_count == 1
}

// The exact HttpArena async-db workload: an items table with every column type
// the benchmark reads (incl. jsonb), the real range-scan query, a buffer-spanning
// large result, the empty-range anti-cheat, and error recovery. A test-specific
// table name avoids clobbering a real `items` table if PGHOST points at a bench DB.
fn test_async_db_workload() {
	cfg := pg_test_cfg() or { return }
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}

	c.query('drop table if exists pg_async_test_items', []?[]u8{})!
	c.query('create table pg_async_test_items (id int4 primary key, name text, category text,
		price int4, quantity int4, active bool, tags jsonb, rating_score int4, rating_count int4)',
		[]?[]u8{})!
	c.query("insert into pg_async_test_items
		select g, 'item' || g, 'cat' || (g % 5), g, g * 2, (g % 2 = 0),
		       jsonb_build_array('a', 'b', g), g % 100, g
		from generate_series(1, 500) g",
		[]?[]u8{})!

	// The real async-db query shape: price range + limit, all nine columns.
	res := c.query(r'select id, name, category, price, quantity, active, tags, rating_score, rating_count
		from pg_async_test_items where price between $1 and $2 limit $3', [
		?[]u8('10'.bytes()),
		?[]u8('60'.bytes()),
		?[]u8('50'.bytes()),
	])!
	mut it := res.rows()
	mut n := 0
	for {
		row := it.next() or { break }
		id := row.int4(0)!
		assert id >= 10 && id <= 60
		assert row.text(1)!.len > 0 // name
		assert row.text(2)!.len > 0 // category
		assert row.int4(3)! == id // price == g == id
		assert row.int4(4)! == id * 2 // quantity
		assert row.boolean(5)! == (id % 2 == 0) // active
		// jsonb arrives binary: a 0x01 version byte + JSON text. Strip it and the
		// remainder is a real JSON array.
		tags := jsonb_text(row.text(6)!)
		assert tags.len > 0 && tags[0] == `[`
		assert row.int4(7)! == id % 100 // rating_score
		assert row.int4(8)! == id // rating_count
		n++
	}
	assert n == 50 // 51 ids in [10,60], capped by limit 50

	// Large result: 500 rows exceed the 16 KiB read buffer, so this exercises
	// message framing across multiple reads (the same next_message path the
	// async worker relies on).
	big := c.query('select id, name, tags from pg_async_test_items', []?[]u8{})!
	mut bit := big.rows()
	mut total := 0
	for {
		bit.next() or { break }
		total++
	}
	assert total == 500

	// Empty range (the async-db anti-cheat): zero matching rows, clean iteration.
	empty := c.query(r'select id from pg_async_test_items where price between $1 and $2', [
		?[]u8('900000'.bytes()),
		?[]u8('999999'.bytes()),
	])!
	mut eit := empty.rows()
	if _ := eit.next() {
		assert false, 'expected zero rows for an out-of-range price window'
	}

	// A query error surfaces as an error (not a crash), and the connection stays
	// usable afterwards — query() drains through ReadyForQuery even on error.
	if _ := c.query('select * from no_such_table_xyz', []?[]u8{}) {
		assert false, 'expected an error for a missing table'
	}
	recovered := c.query(r'select 42::int4', []?[]u8{})!
	mut rit := recovered.rows()
	rr := rit.next() or { panic('connection unusable after a query error') }
	assert rr.int4(0)! == 42

	c.query('drop table if exists pg_async_test_items', []?[]u8{})!
}

// Per-worker pool: bring-up of N connections, acquire/release bookkeeping
// (including exhaustion), and running a query through a pooled connection via
// the non-blocking pump.
fn test_pool_acquire_release_and_query() {
	cfg := pg_test_cfg() or { return }
	mut pool := PgPool.connect(cfg, 2)!
	defer {
		pool.close()
	}
	assert pool.size() == 2

	// Acquire both, confirm exhaustion, release one, re-acquire the same slot.
	a := pool.acquire() or { panic('acquire 0') }
	b := pool.acquire() or { panic('acquire 1') }
	assert a != b
	if _ := pool.acquire() {
		assert false, 'pool should be exhausted with both connections busy'
	}
	pool.release(a)
	got := pool.acquire() or { panic('re-acquire after release') }
	assert got == a

	// Run a query through the pooled connection via the non-blocking pump.
	mut conn := pool.conn(got)
	conn.async_submit(r'select $1::int4', [?[]u8('123'.bytes())])
	mut sent := false
	for _ in 0 .. 10000 {
		if conn.async_flush()! {
			sent = true
			break
		}
	}
	assert sent
	mut result := ?Result(none)
	for _ in 0 .. 200000 {
		poll := conn.async_on_readable()!
		if poll.ready {
			result = poll.result
			break
		}
	}
	res := result or { panic('pooled query did not complete') }
	mut it := res.rows()
	row := it.next() or { panic('expected a row') }
	assert row.int4(0)! == 123
	pool.release(got)
}
