module pg_async

fn test_binary_decoders() {
	assert decode_int2([u8(0), 5])! == 5
	assert decode_int4([u8(0), 0, 0, 7])! == 7
	assert decode_int8([u8(0), 0, 0, 0, 0, 0, 0, 9])! == 9
	assert decode_bool([u8(1)])! == true
	assert decode_bool([u8(0)])! == false
	assert decode_text('hi'.bytes()).bytestr() == 'hi'
	// negative int4 (two's complement, big-endian): 0xFFFFFFFF == -1
	assert decode_int4([u8(0xFF), 0xFF, 0xFF, 0xFF])! == -1
	if _ := decode_int4([u8(0), 0, 7]) {
		assert false, 'short int4 must error'
	}
}

fn test_jsonb_text_strips_version_prefix() {
	body := '[1,2,3]'.bytes()
	mut wire := [u8(0x01)]
	wire << body
	assert jsonb_text(wire).bytestr() == '[1,2,3]'
	assert jsonb_text(body).bytestr() == '[1,2,3]' // no prefix → unchanged
}

fn build_data_row(cols []?[]u8) []u8 {
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

fn test_row_column_access() {
	// columns: int4 7, SQL NULL, text "hi"
	payload := build_data_row([?[]u8([u8(0), 0, 0, 7]), ?[]u8(none), ?[]u8('hi'.bytes())])
	r := Row{
		payload: payload
	}
	assert r.int4(0)! == 7
	assert r.text(2)!.bytestr() == 'hi'
	// col(1) is SQL NULL
	col1 := r.col(1)!
	assert col1.is_null
	// a typed read of a NULL column errors
	if _ := r.int4(1) {
		assert false, 'int4 of NULL must error'
	}
	// out-of-range column errors
	if _ := r.col(3) {
		assert false, 'col 3 out of range must error'
	}
}

fn append_msg(mut buf []u8, typ u8, payload []u8) {
	buf << typ
	put_u32(mut buf, u32(4 + payload.len))
	buf << payload
}

fn test_frame_iter_and_result_rows() {
	mut frames := []u8{}
	append_msg(mut frames, bt_parse_complete, [])
	append_msg(mut frames, bt_bind_complete, [])
	append_msg(mut frames, bt_data_row, build_data_row([
		?[]u8([u8(0), 0, 0, 42]),
	]))
	append_msg(mut frames, bt_data_row, build_data_row([
		?[]u8([u8(0), 0, 0, 43]),
	]))
	tag := 'SELECT 2\0'.bytes()
	append_msg(mut frames, bt_command_complete, tag)

	res := Result{
		frames:        frames
		rows_affected: parse_command_complete(tag)
	}
	mut it := res.rows()
	r0 := it.next() or { panic('expected row 0') }
	assert r0.int4(0)! == 42
	r1 := it.next() or { panic('expected row 1') }
	assert r1.int4(0)! == 43
	if _ := it.next() {
		assert false, 'expected end of rows'
	}
	assert res.rows_affected == 2
}

fn test_next_message_framing() {
	mut buf := []u8{}
	append_msg(mut buf, bt_ready_for_query, [u8(`I`)]) // idle
	// a partial trailing message: header says more bytes than present
	buf << bt_data_row
	put_u32(mut buf, 100)
	hdr := next_message(buf) or { panic('expected a complete first message') }
	assert hdr.typ == bt_ready_for_query
	rest := unsafe { buf[hdr.total..] }
	if _ := next_message(rest) {
		assert false, 'partial second message must not frame'
	}
}

fn test_parse_error_response() {
	mut p := []u8{}
	p << u8(`S`)
	p << 'ERROR\0'.bytes()
	p << u8(`C`)
	p << '23505\0'.bytes()
	p << u8(`M`)
	p << 'duplicate key value'.bytes()
	p << u8(0)
	p << u8(0) // field-list terminator
	info := parse_error_response(p)
	assert info.severity.bytestr() == 'ERROR'
	assert info.code.bytestr() == '23505'
	assert info.message.bytestr() == 'duplicate key value'
}

fn test_extended_query_pipeline_builds() {
	mut buf := []u8{}
	write_parse(mut buf, '', 'select id from items')
	write_bind(mut buf, '', '', []?[]u8{})
	write_describe_portal(mut buf, '')
	write_execute(mut buf, '', 0)
	write_sync(mut buf)

	// First framed message is Parse, and every message frames cleanly back to
	// back through the whole pipeline.
	mut rest := buf.clone()
	mut types := []u8{}
	for {
		hdr := next_message(rest) or { break }
		types << hdr.typ
		rest = unsafe { rest[hdr.total..] }
	}
	assert types == [u8(`P`), `B`, `D`, `E`, `S`]
	assert rest.len == 0
}

// Framing must be correct when bytes arrive one at a time — exactly the
// partial-read regime the non-blocking async worker runs in. next_message must
// return none until a whole message is buffered, then frame it precisely.
fn test_framing_under_byte_by_byte_fragmentation() {
	mut full := []u8{}
	append_msg(mut full, bt_data_row, build_data_row([?[]u8([u8(0), 0, 0, 7])]))
	append_msg(mut full, bt_command_complete, 'SELECT 1\0'.bytes())
	append_msg(mut full, bt_ready_for_query, [u8(`I`)])

	mut buf := []u8{}
	mut framed := []u8{} // the message type of each framed message, in order
	for i in 0 .. full.len {
		buf << full[i]
		for {
			hdr := next_message(buf) or { break }
			framed << hdr.typ
			buf.delete_many(0, hdr.total)
		}
	}
	assert framed == [bt_data_row, bt_command_complete, bt_ready_for_query]
	assert buf.len == 0 // every byte consumed, nothing left dangling
}

fn test_startup_message_has_no_type_byte_and_self_lengths() {
	mut buf := []u8{}
	write_startup(mut buf, 'bench', 'bench')
	// length field covers the whole message
	len := int(u32(buf[0]) << 24 | u32(buf[1]) << 16 | u32(buf[2]) << 8 | u32(buf[3]))
	assert len == buf.len
	// protocol version 3.0
	assert buf[4] == 0 && buf[5] == 3 && buf[6] == 0 && buf[7] == 0
}
