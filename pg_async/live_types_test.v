// vtest build: !windows
// The pg_async module is a POSIX-socket native driver (conn.v includes
// <sys/socket.h>/<netdb.h>), so every _test.v in it compiles on Linux/macOS only.
module pg_async

import os
import time

// The decoders (#198) against a live PostgreSQL: every type the issue lists,
// as the server encodes them in binary, and RowDescription. Skipped unless
// PGHOST is set (pg_async.yml runs it against PostgreSQL 16 and 18).

fn types_cfg() ?ConnConfig {
	host := os.getenv('PGHOST')
	if host == '' {
		eprintln('pg_async: skipping live type tests (no PGHOST)')
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

fn first_row(res Result) Row {
	mut it := res.rows()
	return it.next() or { panic('the query returned no row') }
}

fn test_live_every_new_type_decodes() {
	cfg := types_cfg() or { return }
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	res := c.query("select gen_random_uuid() as u, now() as ts, current_date as d, 123.45::numeric as num, 2.5::float4 as f4, array['a','b']::text[] as arr", []?[]u8{})!
	cols := res.columns()!
	assert cols.len() == 6
	for i, oid in [oid_uuid, oid_timestamptz, oid_date, oid_numeric, oid_float4, oid_text_array] {
		assert cols.type_oid(i)! == oid, 'column ${i}'
	}
	assert cols.index('num') or { -1 } == 3
	row := first_row(res)
	// The uuid's text form round-trips through $1::uuid.
	mut u := []u8{}
	row.uuid_into(0, mut u)!
	assert u.len == 36
	back := first_row(c.query(r'select $1::uuid::text', [?[]u8(u)])!)
	assert back.text(0)!.bytestr() == u.bytestr()
	// now() is within a few seconds of this machine's clock.
	skew := row.time(1)!.unix() - time.now().unix()
	assert skew > -10 && skew < 10, 'skew ${skew} s'
	d := row.date(2)!
	today := time.now() // current_date follows the session's TimeZone: allow a day
	assert d.unix() > today.unix() - 2 * 86_400 && d.unix() <= today.unix() + 86_400
	mut num := []u8{}
	row.numeric_text_into(3, mut num)!
	assert num.bytestr() == '123.45'
	assert row.float4(4)! == f32(2.5)
	mut arr := [][]u8{}
	row.text_array_into(5, mut arr)!
	assert arr.len == 2 && arr[0].bytestr() == 'a' && arr[1].bytestr() == 'b'
}

fn test_live_edge_values_decode() {
	cfg := types_cfg() or { return }
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	row := first_row(c.query("select '-0.000012'::numeric, 'NaN'::numeric, 'infinity'::timestamptz, '-infinity'::date, '1969-12-31 23:59:59.5+00'::timestamptz, '2026-10-01 21:12:29.346865'::timestamp, 1234.5::numeric(10,2), array[1,null,3]::int4[], '{}'::int4[], '{{1,2},{3,4}}'::int4[], null::uuid",
		[]?[]u8{})!)
	mut out := []u8{}
	row.numeric_text_into(0, mut out)!
	assert out.bytestr() == '-0.000012'
	out.clear()
	row.numeric_text_into(1, mut out)!
	assert out.bytestr() == 'NaN'
	assert row.timestamp_us(2)! == timestamp_infinity
	if _ := row.time(2) {
		assert false, 'infinity has no time.Time'
	}
	assert row.date_days(3)! == date_neg_infinity
	before_1970 := row.time(4)!
	assert before_1970.year == 1969 && before_1970.second == 59
	assert before_1970.nanosecond == 500_000_000
	wall := row.time(5)! // timestamp without time zone: its wall-clock fields
	assert wall.year == 2026 && wall.hour == 21 && wall.nanosecond == 346_865_000
	assert row.numeric_i64_scaled(6, 2)! == 123450
	mut it := row.array_iter(7)!
	assert it.len == 3 && it.elem_oid == oid_int4 && it.lower_bound == 1
	a := it.next() or { panic('element 0') }
	assert decode_int4(a.bytes)! == 1
	b := it.next() or { panic('element 1') }
	assert b.is_null
	mut ints := []i32{}
	if _ := row.int4_array_into(7, mut ints) {
		assert false, 'a NULL element needs array_iter'
	}
	empty := row.array_iter(8)!
	assert empty.len == 0
	if _ := row.array_iter(9) {
		assert false, 'two dimensions'
	}
	assert row.col(10)!.is_null
}

fn test_live_row_description_names_and_types() {
	cfg := types_cfg() or { return }
	mut c := PgConn.connect(cfg)!
	defer {
		c.close()
	}
	res := c.query("select 1 as a, 'x' as b", []?[]u8{})!
	cols := res.columns()!
	assert cols.len() == 2
	assert cols.name(0)!.bytestr() == 'a'
	assert cols.name(1)!.bytestr() == 'b'
	assert cols.type_oid(0)! == oid_int4
	assert cols.type_oid(1)! == oid_text
	row := first_row(res)
	assert row.col_by_name(cols, 'b')!.bytes.bytestr() == 'x'
	if _ := row.int4(1) {
		assert false, "int4 of the text 'x'"
	}
	// A query that returns no row still describes its columns.
	no_rows := c.query('select 1 as only where false', []?[]u8{})!
	assert no_rows.columns()!.len() == 1
	assert no_rows.columns()!.index('only') or { -1 } == 0
}
