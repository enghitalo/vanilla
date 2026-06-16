module pg_async

import os

// Live-Postgres integration test. Skipped unless PGHOST is set, so CI without a
// database stays green. Run it against a local container, e.g.:
//
//   docker run -d --name pgtest -p 5433:5432 \
//     -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=bench \
//     -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 postgres:16-alpine
//   PGHOST=localhost PGPORT=5433 PGUSER=bench PGPASSWORD=bench PGDATABASE=bench \
//     v test pg_async/
fn test_live_postgres_query() {
	host := os.getenv('PGHOST')
	if host == '' {
		eprintln('pg_async: skipping live test (set PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE)')
		return
	}
	port_env := os.getenv('PGPORT')
	cfg := ConnConfig{
		host:     host
		port:     if port_env != '' { port_env.int() } else { 5432 }
		user:     os.getenv('PGUSER')
		password: os.getenv('PGPASSWORD')
		database: os.getenv('PGDATABASE')
	}
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}

	// Binary scalar decoding + a text-format parameter round-trip. Raw string so
	// V does not interpolate the `$1` placeholder.
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

	// Multiple rows + a SQL NULL in the middle (g=2 → NULL).
	res2 := c.query(r'select g, (case when g = 2 then null else g end)::int4 from generate_series(1,3) g order by 1',
		[]?[]u8{})!
	mut it2 := res2.rows()
	mut ids := []int{}
	mut null_count := 0
	for {
		r := it2.next() or { break }
		ids << r.int4(0)!
		dv := r.col(1)!
		if dv.is_null {
			null_count++
		}
	}
	assert ids == [1, 2, 3]
	assert null_count == 1 // exactly the g=2 row was NULL
}
