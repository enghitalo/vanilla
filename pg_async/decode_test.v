// vtest build: !windows
// The pg_async module is a POSIX-socket native driver (conn.v includes
// <sys/socket.h>/<netdb.h>), so every _test.v in it compiles on Linux/macOS only.
module pg_async

// The binary decoders (#198), RowDescription, and their treatment of
// untrusted bytes: the exact vectors a live Aurora DSQL cluster returned
// (issue #198), then every malformed shape each decoder must reject.

// hex decodes a hex string (spaces ignored) for the vectors below.
fn hex(s string) []u8 {
	mut out := []u8{}
	clean := s.replace(' ', '')
	for i := 0; i < clean.len; i += 2 {
		out << u8(clean[i..i + 2].parse_uint(16, 8) or { panic(err) })
	}
	return out
}

// data_row builds a DataRow payload from column values (none = SQL NULL).
fn data_row(cols []?[]u8) []u8 {
	mut p := []u8{}
	put_u16(mut p, u16(cols.len))
	for c in cols {
		if v := c {
			put_u32(mut p, u32(v.len))
			p << v
		} else {
			put_u32(mut p, 0xFFFF_FFFF)
		}
	}
	return p
}

fn test_the_aurora_dsql_vectors_decode() {
	// uuid 2950
	u := hex('c7e5b8ff8279457ca557cba06320423b')
	mut text := []u8{}
	uuid_into(u, mut text)!
	assert text.bytestr() == 'c7e5b8ff-8279-457c-a557-cba06320423b'
	ub := decode_uuid(u)!
	assert ub[0] == 0xc7
	// timestamptz 1184: 844204349346865 µs since 2000-01-01
	ts_us := decode_timestamp_us(hex('0002ffcca45c5431'))!
	assert ts_us == 844204349346865
	t := timestamp_time(ts_us)!
	assert t.year == 2026 && t.month == 10 && t.day == 1
	assert t.hour == 21 && t.minute == 12 && t.second == 29
	assert t.nanosecond == 346_865_000
	// date 1082: 9770 days since 2000-01-01
	days := decode_date_days(hex('0000262a'))!
	assert days == 9770
	d := date_time(days)!
	assert d.year == 2026 && d.month == 10 && d.day == 1 && d.hour == 0
	// numeric 1700: ndigits 2, weight 0, +, dscale 2, digits [123, 4500]
	num := hex('0002 0000 0000 0002 007b 1194')
	mut ntext := []u8{}
	numeric_text_into(num, mut ntext)!
	assert ntext.bytestr() == '123.45'
	assert decode_numeric_i64_scaled(num, 2)! == 12345
	assert decode_numeric_i64_scaled(num, 4)! == 1234500
	// float4 700
	assert decode_float4(hex('40200000'))! == f32(2.5)
	// text[] 1009: ndim 1, no NULL, elem 25, dim 2, lbound 1
	mut it := decode_array(hex('00000001 00000000 00000019 00000002 00000001 00000001 61 00000001 62'))!
	assert it.elem_oid == oid_text
	assert it.len == 2 && it.lower_bound == 1
	mut elems := []string{}
	for {
		v := it.next() or { break }
		assert !v.is_null
		elems << v.bytes.bytestr()
	}
	assert elems == ['a', 'b']
}

fn test_timestamps_and_dates_keep_infinity_and_the_past() {
	assert decode_timestamp_us(hex('7fffffffffffffff'))! == timestamp_infinity
	assert decode_timestamp_us(hex('8000000000000000'))! == timestamp_neg_infinity
	if _ := timestamp_time(timestamp_infinity) {
		assert false, 'time of infinity' + ': must be rejected'
	}
	if _ := timestamp_time(timestamp_neg_infinity) {
		assert false, 'time of -infinity' + ': must be rejected'
	}
	assert decode_date_days(hex('7fffffff'))! == date_infinity
	assert decode_date_days(hex('80000000'))! == date_neg_infinity
	if _ := date_time(date_infinity) {
		assert false, 'date of infinity' + ': must be rejected'
	}
	// Before 1970, with a fraction: 1969-12-31T23:59:59.5Z is
	// (-0.5 s - 946684800 s) after the PostgreSQL epoch.
	t := timestamp_time(-946_684_800_500_000)!
	assert t.year == 1969 && t.month == 12 && t.day == 31
	assert t.hour == 23 && t.minute == 59 && t.second == 59
	assert t.nanosecond == 500_000_000
	d := date_time(-1)! // 1999-12-31
	assert d.year == 1999 && d.month == 12 && d.day == 31
}

fn numeric_text(b []u8) string {
	mut out := []u8{}
	numeric_text_into(b, mut out) or { return 'error: ${err.msg()}' }
	return out.bytestr()
}

fn test_numeric_text_matches_postgres() {
	// -123.45
	assert numeric_text(hex('0002 0000 4000 0002 007b 1194')) == '-123.45'
	// 0.00 (zero: no digits)
	assert numeric_text(hex('0000 0000 0000 0002')) == '0.00'
	// 0 (no scale)
	assert numeric_text(hex('0000 0000 0000 0000')) == '0'
	// 10000 (weight 1, digits [1], the zero group implied)
	assert numeric_text(hex('0001 0001 0000 0000 0001')) == '10000'
	// 12345678.9 (digits [1234, 5678, 9000], weight 1, dscale 1)
	assert numeric_text(hex('0003 0001 0000 0001 04d2 162e 2328')) == '12345678.9'
	// 0.00001234 (weight -2: one implied zero group before the digits)
	assert numeric_text(hex('0001 fffe 0000 0008 04d2')) == '0.00001234'
	// 1.5 shown with dscale 4: trailing zeros kept
	assert numeric_text(hex('0002 0000 0000 0004 0001 1388')) == '1.5000'
	assert numeric_text(hex('0000 0000 c000 0000')) == 'NaN'
	assert numeric_text(hex('0000 0000 d000 0000')) == 'Infinity'
	assert numeric_text(hex('0000 0000 f000 0000')) == '-Infinity'
}

fn test_numeric_scaled_is_exact_or_an_error() {
	one_and_half := hex('0002 0000 0000 0001 0001 1388') // 1.5
	assert decode_numeric_i64_scaled(one_and_half, 1)! == 15
	assert decode_numeric_i64_scaled(one_and_half, 3)! == 1500
	if _ := decode_numeric_i64_scaled(one_and_half, 0) {
		assert false, '1.5 at scale 0 (would round)' + ': must be rejected'
	}
	assert decode_numeric_i64_scaled(hex('0002 0000 4000 0002 007b 1194'), 2)! == -12345
	assert decode_numeric_i64_scaled(hex('0001 fffe 0000 0008 04d2'), 8)! == 1234
	if _ := decode_numeric_i64_scaled(hex('0001 fffe 0000 0008 04d2'), 6) {
		assert false, '0.00001234 at scale 6' + ': must be rejected'
	}
	assert decode_numeric_i64_scaled(hex('0000 0000 0000 0002'), 2)! == 0
	if _ := decode_numeric_i64_scaled(hex('0000 0000 c000 0000'), 0) {
		assert false, 'NaN' + ': must be rejected'
	}
	if _ := decode_numeric_i64_scaled(hex('0000 0000 d000 0000'), 0) {
		assert false, 'Infinity' + ': must be rejected'
	}
	// i64 bounds: 9223372036854775807 = digits [922, 3372, 0368, 5477, 5807],
	// weight 4; one more is out of range; -9223372036854775808 is in.
	max := hex('0005 0004 0000 0000 039a 0d2c 0170 1565 16af')
	assert decode_numeric_i64_scaled(max, 0)! == max_i64
	if _ := decode_numeric_i64_scaled(max, 1) {
		assert false, 'i64 max at scale 1' + ': must be rejected'
	}
	over := hex('0005 0004 0000 0000 039a 0d2c 0170 1565 16b0')
	if _ := decode_numeric_i64_scaled(over, 0) {
		assert false, 'i64 max + 1' + ': must be rejected'
	}
	min := hex('0005 0004 4000 0000 039a 0d2c 0170 1565 16b0')
	assert decode_numeric_i64_scaled(min, 0)! == min_i64
	if _ := decode_numeric_i64_scaled(one_and_half, -1) {
		assert false, 'negative scale' + ': must be rejected'
	}
}

fn test_malformed_numerics_are_rejected() {
	mut out := []u8{}
	for b in [
		hex('0002 0000 0000'), // truncated header
		hex('0002 0000 0000 0002 007b'), // fewer digits than ndigits
		hex('0001 0000 0000 0002 007b 1194'), // more bytes than ndigits
		hex('ffff 0000 0000 0000'), // negative ndigits
		hex('0001 0000 0000 0000 2710'), // digit 10000
		hex('0001 0000 1234 0000 0001'), // unknown sign
		hex('0001 0000 c000 0000 0001'), // NaN with digits
		hex('0000 0000 0000 4000'), // dscale past 14 bits
	] {
		if _ := numeric_text_into(b, mut out) {
			assert false, 'numeric ${b.hex()}' + ': must be rejected'
		}
		if _ := decode_numeric_i64_scaled(b, 2) {
			assert false, 'numeric scaled ${b.hex()}' + ': must be rejected'
		}
	}
	assert out.len == 0, 'nothing is written for a rejected value'
}

fn test_arrays_are_checked_before_they_are_walked() {
	// Empty array: no dimension.
	mut empty := decode_array(hex('00000000 00000000 00000017'))!
	assert empty.len == 0 && empty.elem_oid == oid_int4
	if _ := empty.next() {
		assert false, 'an empty array has no element'
	}
	// int4[] {1, NULL, 3} with lower bound 0.
	mut it := decode_array(hex('00000001 00000001 00000017 00000003 00000000 00000004 00000001 ffffffff 00000004 00000003'))!
	assert it.len == 3 && it.lower_bound == 0
	a := it.next() or { panic('element 0') }
	assert decode_int4(a.bytes)! == 1
	b := it.next() or { panic('element 1') }
	assert b.is_null
	c := it.next() or { panic('element 2') }
	assert decode_int4(c.bytes)! == 3
	if _ := it.next() {
		assert false, 'three elements only'
	}
	for bad in [
		hex('00000001 00000000 00000019'), // a dimension missing
		hex('00000002 00000000 00000019 00000001 00000001 00000001 00000001 00000004 00000001'), // 2-D
		hex('ffffffff 00000000 00000019'), // negative ndim
		hex('00000001 00000002 00000019 00000000 00000001'), // has-null flag 2
		hex('00000001 00000000 00000019 00000002 00000001 00000001 61'), // second element missing
		hex('00000001 00000000 00000019 00000001 00000001 00000005 61'), // element past the end
		hex('00000001 00000000 00000019 00000001 00000001 00000001 61 ff'), // trailing byte
		hex('00000001 00000000 00000019 7fffffff 00000001'), // count the bytes cannot hold
		hex('00000001 00000000 00000019 00000001 00000001 ffffffff'), // NULL without the flag
		hex('00000001 00000000 00000019 00000001 00000001 fffffffe'), // length -2
		hex('00000000 00000000 00000019 00'), // empty array with trailing bytes
	] {
		if _ := decode_array(bad) {
			assert false, 'array ${bad.hex()}' + ': must be rejected'
		}
	}
}

fn test_short_values_are_rejected_by_every_decoder() {
	if _ := decode_uuid([]u8{len: 15}) {
		assert false, 'uuid of 15 bytes' + ': must be rejected'
	}
	mut out := []u8{}
	if _ := uuid_into([]u8{len: 17}, mut out) {
		assert false, 'uuid text of 17 bytes' + ': must be rejected'
	}
	assert out.len == 0
	if _ := decode_timestamp_us([]u8{len: 7}) {
		assert false, 'timestamp of 7 bytes' + ': must be rejected'
	}
	if _ := decode_date_days([]u8{len: 3}) {
		assert false, 'date of 3 bytes' + ': must be rejected'
	}
	if _ := decode_float4([]u8{len: 8}) {
		assert false, 'float4 of 8 bytes' + ': must be rejected'
	}
	if _ := decode_float8([]u8{len: 4}) {
		assert false, 'float8 of 4 bytes' + ': must be rejected'
	}
	if _ := decode_int2([]u8{len: 4}) {
		assert false, 'int2 of 4 bytes' + ': must be rejected'
	}
}

// row_with builds a DataRow payload from column values (none = SQL NULL).
fn row_with(cols []?[]u8) Row {
	return Row{
		payload: data_row(cols)
	}
}

fn test_row_accessors_read_the_new_types() {
	r := row_with([?[]u8(hex('c7e5b8ff8279457ca557cba06320423b')), ?[]u8(hex('0002ffcca45c5431')),
		?[]u8(hex('0000262a')), ?[]u8(hex('0002 0000 0000 0002 007b 1194')), ?[]u8(hex('40200000')),
		?[]u8(hex('00000001 00000000 00000017 00000002 00000001 00000004 00000007 00000004 00000009')),
		?[]u8(hex('00000001 00000000 00000019 00000002 00000001 00000001 61 00000001 62')), ?[]u8(none)])
	mut text := []u8{}
	r.uuid_into(0, mut text)!
	assert text.bytestr() == 'c7e5b8ff-8279-457c-a557-cba06320423b'
	ru := r.uuid(0)!
	assert ru[15] == 0x3b
	assert r.timestamp_us(1)! == 844204349346865
	assert r.time(1)!.second == 29
	assert r.date_days(2)! == 9770
	assert r.date(2)!.day == 1
	text.clear()
	r.numeric_text_into(3, mut text)!
	assert text.bytestr() == '123.45'
	assert r.numeric_i64_scaled(3, 2)! == 12345
	assert r.float4(4)! == f32(2.5)
	mut ints := []i32{}
	r.int4_array_into(5, mut ints)!
	assert ints == [i32(7), 9]
	mut strs := [][]u8{}
	r.text_array_into(6, mut strs)!
	assert strs.len == 2 && strs[0].bytestr() == 'a' && strs[1].bytestr() == 'b'
	// SQL NULL: col() says so; a typed accessor errors (without allocating).
	assert r.col(7)!.is_null
	if _ := r.time(7) {
		assert false, 'time of NULL' + ': must be rejected'
	}
	if _ := r.uuid(7) {
		assert false, 'uuid of NULL' + ': must be rejected'
	}
	if _ := r.int4(5) { // the width check
		assert false, 'int4 of an array column: must be rejected'
	}
}

fn test_an_array_with_a_null_needs_array_iter() {
	r := row_with([?[]u8(hex('00000001 00000001 00000017 00000002 00000001 ffffffff 00000004 00000001'))])
	mut ints := []i32{}
	if _ := r.int4_array_into(0, mut ints) {
		assert false, 'int4[] with a NULL' + ': must be rejected'
	}
	mut it := r.array_iter(0)!
	first := it.next() or { panic('element 0') }
	assert first.is_null
	second := it.next() or { panic('element 1') }
	assert decode_int4(second.bytes)! == 1
}

// row_description builds a RowDescription payload for (name, type OID) pairs.
fn row_description(fields []string, oids []u32) []u8 {
	mut p := []u8{}
	put_u16(mut p, u16(fields.len))
	for i, name in fields {
		p << name.bytes()
		p << 0
		put_u32(mut p, 0) // table OID
		put_u16(mut p, 0) // column number
		put_u32(mut p, oids[i])
		put_u16(mut p, 4) // type size
		put_u32(mut p, 0xFFFF_FFFF) // type modifier
		put_u16(mut p, 1) // binary
	}
	return p
}

// backend_msg wraps a payload in a backend message.
fn backend_msg(typ u8, payload []u8) []u8 {
	mut m := [typ]
	put_u32(mut m, u32(payload.len + 4))
	m << payload
	return m
}

fn test_row_description_gives_names_and_type_oids() {
	// select 1 as a, 'x' as b
	mut frames := backend_msg(bt_parse_complete, []u8{})
	frames << backend_msg(bt_bind_complete, []u8{})
	frames << backend_msg(bt_row_description, row_description(['a', 'b'], [oid_int4, oid_text]))
	frames << backend_msg(bt_data_row, data_row([?[]u8(hex('00000001')), ?[]u8('x'.bytes())]))
	frames << backend_msg(bt_command_complete, 'SELECT 1\0'.bytes())
	res := Result{
		frames: frames
	}
	cols := res.columns()!
	assert cols.len() == 2
	assert cols.name(0)!.bytestr() == 'a'
	assert cols.name(1)!.bytestr() == 'b'
	assert cols.type_oid(0)! == oid_int4
	assert cols.type_oid(1)! == oid_text
	assert cols.index('b') or { -1 } == 1
	if _ := cols.index('c') {
		assert false, 'there is no column c'
	}
	if _ := cols.index('') {
		assert false, 'there is no empty name'
	}
	if _ := cols.name(2) {
		assert false, 'column 2 of 2' + ': must be rejected'
	}
	mut it := res.rows()
	row := it.next() or { panic('one row') }
	assert row.col_by_name(cols, 'b')!.bytes.bytestr() == 'x'
	if _ := row.col_by_name(cols, 'nope') {
		assert false, 'unknown column name' + ': must be rejected'
	}
	ia := cols.index('a') or { panic('column a') }
	assert row.int4(ia)! == 1
	// A wrong-type accessor errors on the width: b is text 'x'.
	if _ := row.int4(1) {
		assert false, 'int4 of a 1-byte text' + ': must be rejected'
	}
	// A statement without rows has no RowDescription.
	no_rows := Result{
		frames: backend_msg(bt_command_complete, 'INSERT 0 1\0'.bytes())
	}
	assert no_rows.columns()!.len() == 0
}

fn test_malformed_row_descriptions_are_rejected() {
	good := row_description(['id'], [oid_int4])
	if _ := columns_from(good[..good.len - 1]) {
		assert false, 'a field cut short' + ': must be rejected'
	}
	mut no_nul := good.clone()
	no_nul.trim(4) // the name, without its NUL
	if _ := columns_from(no_nul) {
		assert false, 'a name without its NUL' + ': must be rejected'
	}
	mut extra := good.clone()
	extra << 0
	if _ := columns_from(extra) {
		assert false, 'a trailing byte' + ': must be rejected'
	}
	if _ := columns_from([u8(0xFF), 0xFF]) {
		assert false, 'a negative field count' + ': must be rejected'
	}
	if _ := columns_from([u8(0)]) {
		assert false, 'a short payload' + ': must be rejected'
	}
}

// The decoders and the RowDescription lookups allocate nothing, errors
// included (they are constants).
fn test_decoding_allocates_nothing() {
	u := hex('c7e5b8ff8279457ca557cba06320423b')
	num := hex('0003 0001 4000 0004 04d2 162e 2328')
	arr := hex('00000001 00000000 00000019 00000002 00000001 00000001 61 00000001 62')
	mut frames := backend_msg(bt_parse_complete, []u8{})
	frames << backend_msg(bt_row_description, row_description(['id', 'name', 'created_at'], [
		oid_int4,
		oid_text,
		oid_timestamptz,
	]))
	res := Result{
		frames: frames
	}
	no_rows := Result{
		frames: backend_msg(bt_command_complete, 'INSERT 0 1\0'.bytes())
	}
	short := []u8{len: 3}
	null_row := row_with([?[]u8(none)])
	mut out := []u8{cap: 256}
	mut sink := i64(0)
	before := gc_heap_usage().bytes_since_gc
	for _ in 0 .. 20_000 {
		unsafe {
			out.len = 0
		}
		uuid_into(u, mut out) or { panic(err) }
		numeric_text_into(num, mut out) or { panic(err) }
		sink += decode_numeric_i64_scaled(num, 4) or { 0 }
		mut it := decode_array(arr) or { panic(err) }
		for {
			v := it.next() or { break }
			sink += v.bytes.len
		}
		cols := res.columns() or { panic(err) }
		sink += cols.index('created_at') or { -1 }
		sink += i64(cols.type_oid(2) or { 0 })
		sink += (no_rows.columns() or { panic(err) }).len()
		sink += i64(timestamp_time(844204349346865) or { panic(err) }.second)
		sink += i64(date_time(9770) or { panic(err) }.day)
		bad := decode_uuid(short) or { [16]u8{} }
		sink += bad[0]
		sink += i64(null_row.int4(0) or { -1 })
		sink += decode_numeric_i64_scaled(num, 0) or { -1 }
	}
	after := gc_heap_usage().bytes_since_gc
	assert sink != 0
	assert after == before, '${after - before} bytes allocated'
}

// decode_everything runs every decoder, RowDescription reader and Row
// accessor over `b`; each either decodes or returns an error.
fn decode_everything(b []u8, mut out []u8, mut ints []i32, mut texts [][]u8) i64 {
	mut sink := i64(0)
	unsafe {
		out.len = 0
	}
	sink += decode_int2(b) or { 0 }
	sink += decode_int4(b) or { 0 }
	sink += decode_int8(b) or { 0 }
	sink += if decode_bool(b) or { false } { 1 } else { 0 }
	sink += if decode_float4(b) or { 0 } > 1 { 1 } else { 0 }
	sink += if decode_float8(b) or { 0 } > 1 { 1 } else { 0 }
	sink += (decode_uuid(b) or { [16]u8{} })[3]
	uuid_into(b, mut out) or {}
	if t := timestamp_time(decode_timestamp_us(b) or { 0 }) {
		sink += t.second
	}
	if d := date_time(decode_date_days(b) or { 0 }) {
		sink += d.day
	}
	numeric_text_into(b, mut out) or {}
	sink += decode_numeric_i64_scaled(b, 0) or { 0 }
	sink += decode_numeric_i64_scaled(b, 2) or { 0 }
	sink += decode_numeric_i64_scaled(b, 18) or { 0 }
	mut it := decode_array(b) or { ArrayIter{} }
	for {
		v := it.next() or { break }
		sink += v.bytes.len
	}
	if cols := columns_from(b) {
		for i in 0 .. cols.len() {
			sink += (cols.name(i) or { []u8{} }).len
			sink += cols.type_oid(i) or { 0 }
		}
		sink += cols.index('name') or { -1 }
	}
	row := Row{
		payload: b
	}
	for i in 0 .. 3 {
		sink += if (row.col(i) or { DataValue{} }).is_null { 1 } else { 0 }
		sink += if row.float4(i) or { 0 } > 1 { 1 } else { 0 }
		sink += row.timestamp_us(i) or { 0 }
		sink += row.date_days(i) or { 0 }
		if t := row.time(i) {
			sink += t.second
		}
		if d := row.date(i) {
			sink += d.day
		}
		row.uuid_into(i, mut out) or {}
		row.numeric_text_into(i, mut out) or {}
		sink += row.numeric_i64_scaled(i, 4) or { 0 }
		ints.clear()
		row.int4_array_into(i, mut ints) or {}
		texts.clear()
		row.text_array_into(i, mut texts) or {}
		sink += ints.len + texts.len
	}
	return sink + jsonb_text(b).len + out.len
}

// Mutated valid encodings: whatever the bytes, every decoder decodes or
// errors, and reads only its input. Each case gets a buffer of exactly its
// length, so under AddressSanitizer a read past the end aborts the test
// (pg_async.yml: "The decoders under AddressSanitizer").
fn test_mutated_values_are_rejected_or_decoded_in_bounds() {
	seeds := [
		hex('c7e5b8ff8279457ca557cba06320423b'),
		hex('0002ffcca45c5431'),
		hex('0000262a'),
		hex('0003 0001 4000 0004 04d2 162e 2328'),
		hex('0002 fffe 0000 0006 0004 0bb8'),
		hex('00000001 00000000 00000019 00000002 00000001 00000001 61 00000001 62'),
		hex('00000001 00000001 00000017 00000003 00000001 00000004 00000001 ffffffff 00000004 00000003'),
		row_description(['id', 'name'], [oid_int4, oid_text]),
		data_row([?[]u8(hex('00000001')), none, ?[]u8(hex('0003 0001 4000 0004 04d2 162e 2328'))]),
	]
	mut x := u64(0x9e37_79b9_7f4a_7c15) // xorshift64: the same cases every run
	mut out := []u8{cap: 256}
	mut ints := []i32{cap: 16}
	mut texts := [][]u8{cap: 16}
	mut sink := i64(0)
	for round in 0 .. 40_000 {
		mut b := seeds[round % seeds.len].clone()
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		for _ in 0 .. 1 + int(x % 3) {
			x ^= x << 13
			x ^= x >> 7
			x ^= x << 17
			match x % 4 {
				0, 1 {
					if b.len > 0 {
						b[int((x >> 8) % u64(b.len))] = u8(x >> 32)
					}
				}
				2 {
					b.trim(int((x >> 8) % u64(b.len + 1)))
				}
				else {
					b << u8(x >> 24)
				}
			}
		}
		// A raw allocation of exactly b.len bytes: a V array keeps up to 15
		// bytes of slack after its data, where an overread goes unnoticed.
		raw := unsafe { &u8(C.malloc(usize(b.len))) }
		if b.len > 0 {
			unsafe { vmemcpy(raw, b.data, b.len) }
		}
		sink += decode_everything(unsafe { raw.vbytes(b.len) }, mut out, mut ints, mut texts)
		unsafe { C.free(raw) }
	}
	assert sink != 0
}
