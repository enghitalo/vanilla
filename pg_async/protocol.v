module pg_async

import encoding.binary

// PostgreSQL frontend/backend wire protocol v3 — framing, message builders, and
// result iteration. Pure and I/O-free: builders append bytes to a caller-owned
// buffer, parsers read borrowed slices. The connection state machine (client.v)
// and the async integration sit on top of this layer.
//
// Message format: every message is type(1 byte) + length(Int32, big-endian,
// INCLUDES the 4 length bytes but NOT the type byte) + payload. The only
// exception is StartupMessage / SSLRequest, which have no type byte.

// Backend message type bytes — the first byte of each backend message. (Module
// constants rather than an enum: V enum values must be integer literals, and
// these read most clearly as their wire characters.)
pub const bt_authentication = u8(`R`)
pub const bt_backend_key_data = u8(`K`)
pub const bt_bind_complete = u8(`2`)
pub const bt_close_complete = u8(`3`)
pub const bt_command_complete = u8(`C`)
pub const bt_data_row = u8(`D`)
pub const bt_empty_query_response = u8(`I`)
pub const bt_error_response = u8(`E`)
pub const bt_no_data = u8(`n`)
pub const bt_notice_response = u8(`N`)
pub const bt_notification_response = u8(`A`)
pub const bt_parameter_description = u8(`t`)
pub const bt_parameter_status = u8(`S`)
pub const bt_parse_complete = u8(`1`)
pub const bt_portal_suspended = u8(`s`)
pub const bt_ready_for_query = u8(`Z`)
pub const bt_row_description = u8(`T`)

// AuthType is the Int32 sub-code carried by an Authentication ('R') message.
pub enum AuthType as u32 {
	ok                 = 0
	cleartext_password = 3
	md5_password       = 5
	sasl               = 10
	sasl_continue      = 11
	sasl_final         = 12
}

// auth_subtype reads the sub-code of an Authentication payload (0xFFFFFFFF on a
// truncated payload).
pub fn auth_subtype(payload []u8) u32 {
	if payload.len < 4 {
		return 0xFFFF_FFFF
	}
	return binary.big_endian_u32_at(payload, 0)
}

// ── backend framing ─────────────────────────────────────────────────────────

// MsgHeader describes the first complete message in a buffer.
pub struct MsgHeader {
pub:
	typ   u8
	total int // bytes to consume for this message: 1 + length
}

// next_message returns the header of the first COMPLETE backend message in buf,
// or none if a full message is not buffered yet. The connection read loop uses
// it to frame messages off the recv buffer without copying. A length < 4 is a
// protocol violation; the caller drops the connection.
pub fn next_message(buf []u8) ?MsgHeader {
	if buf.len < 5 {
		return none
	}
	msg_len := int(binary.big_endian_u32_at(buf, 1))
	if msg_len < 4 {
		return none
	}
	total := 1 + msg_len
	if buf.len < total {
		return none
	}
	return MsgHeader{
		typ:   buf[0]
		total: total
	}
}

// next_message_at is next_message starting at offset `pos` — for an advancing read
// cursor over a buffer appended-to at the tail and consumed from the front WITHOUT
// memmove per message. Returns none if a full message is not buffered at pos.
@[direct_array_access]
pub fn next_message_at(buf []u8, pos int) ?MsgHeader {
	if buf.len - pos < 5 {
		return none
	}
	msg_len := int(binary.big_endian_u32_at(buf, pos + 1))
	if msg_len < 4 {
		return none
	}
	total := 1 + msg_len
	if buf.len - pos < total {
		return none
	}
	return MsgHeader{
		typ:   buf[pos]
		total: total
	}
}

// Frame is one parsed backend message (type + borrowed payload).
pub struct Frame {
pub:
	typ     u8
	payload []u8
}

// FrameIter walks complete backend messages in a region (e.g. one op's frames
// from ParseComplete through CommandComplete).
pub struct FrameIter {
	buf []u8
mut:
	pos int
}

pub fn FrameIter.new(buf []u8) FrameIter {
	return FrameIter{
		buf: buf
	}
}

// next returns the next complete message, or none at end / on a truncated
// trailer.
pub fn (mut it FrameIter) next() ?Frame {
	if it.pos + 5 > it.buf.len {
		return none
	}
	msg_len := int(binary.big_endian_u32_at(it.buf, it.pos + 1))
	if msg_len < 4 {
		return none
	}
	total := 1 + msg_len
	if it.pos + total > it.buf.len {
		return none
	}
	frame := Frame{
		typ:     it.buf[it.pos]
		payload: it.buf[it.pos + 5..it.pos + total]
	}
	it.pos += total
	return frame
}

// ── result rows ─────────────────────────────────────────────────────────────

// Result is one completed query's frames (ParseComplete..CommandComplete) plus
// the rows-affected count parsed from the CommandComplete tag. Rows borrow the
// recv buffer and are valid only inside the resume callback.
pub struct Result {
pub:
	frames        []u8
	rows_affected u64
}

pub fn (res &Result) rows() RowIter {
	return RowIter{
		frames: FrameIter.new(res.frames)
	}
}

// RowIter yields the DataRow frames in a result, skipping everything else.
pub struct RowIter {
mut:
	frames FrameIter
}

pub fn (mut it RowIter) next() ?Row {
	for {
		frame := it.frames.next() or { return none }
		if frame.typ == bt_data_row {
			return Row{
				payload: frame.payload
			}
		}
	}
	return none
}

// Row is one DataRow payload. Columns are read by index; the payload is walked
// each access (columns are few, so O(n) is fine at handler scale). All values
// are binary (Bind requests result-format-code 1 for every column).
pub struct Row {
pub:
	payload []u8
}

// DataValue is one column's value: either SQL NULL, or the borrowed binary
// bytes (V has no `!?T`, so NULL is a flag rather than an Option).
pub struct DataValue {
pub:
	is_null bool
	bytes   []u8
}

// col returns column i: error on malformed/out-of-range, is_null set for SQL
// NULL, else the borrowed column bytes.
pub fn (r Row) col(i int) !DataValue {
	if r.payload.len < 2 {
		return error('datarow: short payload')
	}
	ncols := int(i16(binary.big_endian_u16_at(r.payload, 0)))
	if i < 0 || i >= ncols {
		return error('datarow: col ${i} out of range (${ncols} cols)')
	}
	mut pos := 2
	for idx in 0 .. ncols {
		if pos + 4 > r.payload.len {
			return error('datarow: truncated length')
		}
		// read the 4-byte length at offset WITHOUT slicing the payload — the slice
		// (array descriptor alloc) per length-read dominated the row-decode CPU
		// (~31% of the async-db per-request profile, O(ncols) per col access).
		clen := int(i32(binary.big_endian_u32_at(r.payload, pos)))
		pos += 4
		if clen < 0 {
			if idx == i {
				return DataValue{
					is_null: true
				} // SQL NULL
			}
			continue
		}
		if pos + clen > r.payload.len {
			return error('datarow: truncated value')
		}
		if idx == i {
			return DataValue{
				bytes: r.payload[pos..pos + clen]
			}
		}
		pos += clen
	}
	return error('datarow: col not found')
}

fn (r Row) require(i int) ![]u8 {
	dv := r.col(i)!
	if dv.is_null {
		return error('unexpected NULL at col ${i}')
	}
	return dv.bytes
}

pub fn (r Row) int2(i int) !i16 {
	return decode_int2(r.require(i)!)
}

pub fn (r Row) int4(i int) !i32 {
	return decode_int4(r.require(i)!)
}

pub fn (r Row) int8(i int) !i64 {
	return decode_int8(r.require(i)!)
}

pub fn (r Row) boolean(i int) !bool {
	return decode_bool(r.require(i)!)
}

pub fn (r Row) float8(i int) !f64 {
	return decode_float8(r.require(i)!)
}

pub fn (r Row) text(i int) ![]u8 {
	return decode_text(r.require(i)!)
}

// ── backend message details ─────────────────────────────────────────────────

// ErrorInfo is the parsed fields of an ErrorResponse / NoticeResponse.
pub struct ErrorInfo {
pub:
	severity []u8 // field 'S' (or 'V' for the non-localized severity)
	code     []u8 // field 'C' — SQLSTATE
	message  []u8 // field 'M'
}

// parse_error_response walks the field list: (field-type byte, NUL-terminated
// value)*, terminated by a 0 byte.
pub fn parse_error_response(payload []u8) ErrorInfo {
	mut severity := []u8{}
	mut code := []u8{}
	mut message := []u8{}
	mut pos := 0
	for pos < payload.len {
		ft := payload[pos]
		pos++
		if ft == 0 {
			break
		}
		start := pos
		for pos < payload.len && payload[pos] != 0 {
			pos++
		}
		val := payload[start..pos]
		if pos < payload.len {
			pos++ // skip NUL
		}
		// Borrow the payload (the ErrorInfo is valid only while the recv buffer
		// is — the error path doesn't need a copy).
		match ft {
			`S`, `V` {
				unsafe {
					severity = val
				}
			}
			`C` {
				unsafe {
					code = val
				}
			}
			`M` {
				unsafe {
					message = val
				}
			}
			else {}
		}
	}
	return ErrorInfo{
		severity: severity
		code:     code
		message:  message
	}
}

// parse_command_complete extracts rows-affected from a CommandComplete tag
// ("SELECT 5", "INSERT 0 3", "UPDATE 2"): the LAST integer token (0 if none).
pub fn parse_command_complete(payload []u8) u64 {
	mut last := u64(0)
	mut cur := u64(0)
	mut seen := false
	for c in payload {
		if c >= `0` && c <= `9` {
			cur = cur * 10 + u64(c - `0`)
			seen = true
		} else {
			if seen {
				last = cur
			}
			cur = 0
			seen = false
		}
	}
	if seen {
		last = cur
	}
	return last
}

// ── frontend message builders ───────────────────────────────────────────────
//
// All builders APPEND to a caller-owned buffer so multiple messages (a full
// Parse/Bind/Describe/Execute/Sync pipeline) batch into one write.

fn begin_msg(mut buf []u8, typ u8) int {
	buf << typ
	lenpos := buf.len
	// 4-byte length placeholder, backpatched by finish_msg. Appended a byte at a
	// time on purpose: the literal `[u8(0), 0, 0, 0]` heap-allocates a temporary
	// array on every call (4 per query — P/B/D/E), which leaks under `-gc none`.
	buf << u8(0)
	buf << u8(0)
	buf << u8(0)
	buf << u8(0)
	return lenpos
}

fn finish_msg(mut buf []u8, lenpos int) {
	msg_len := u32(buf.len - lenpos) // includes the 4 length bytes, excludes the type byte
	buf[lenpos] = u8(msg_len >> 24)
	buf[lenpos + 1] = u8(msg_len >> 16)
	buf[lenpos + 2] = u8(msg_len >> 8)
	buf[lenpos + 3] = u8(msg_len)
}

fn put_u16(mut buf []u8, v u16) {
	buf << u8(v >> 8)
	buf << u8(v)
}

fn put_u32(mut buf []u8, v u32) {
	buf << u8(v >> 24)
	buf << u8(v >> 16)
	buf << u8(v >> 8)
	buf << u8(v)
}

// put_cstr_s appends a NUL-terminated C string by copying the string's bytes
// DIRECTLY (push_many from s.str/s.len), never `s.bytes()` — `.bytes()` allocates a
// throwaway []u8 copy on every call, which leaks under `-gc none` (the SQL text + the
// empty portal/stmt names are serialized on every async_submit). Wire output is
// byte-identical: the same bytes followed by a NUL.
@[direct_array_access]
fn put_cstr_s(mut buf []u8, s string) {
	unsafe { buf.push_many(s.str, s.len) }
	buf << u8(0)
}

// write_startup appends a StartupMessage (protocol 3.0): no type byte, Int32
// length, Int32 protocol version, then user/database key-value pairs and a
// terminating 0 byte.
pub fn write_startup(mut buf []u8, user string, database string) {
	lenpos := buf.len
	buf << [u8(0), 0, 0, 0]
	put_u32(mut buf, 0x0003_0000)
	put_cstr_s(mut buf, 'user')
	put_cstr_s(mut buf, user)
	if database.len > 0 {
		put_cstr_s(mut buf, 'database')
		put_cstr_s(mut buf, database)
	}
	buf << u8(0) // end of parameters
	msg_len := u32(buf.len - lenpos)
	buf[lenpos] = u8(msg_len >> 24)
	buf[lenpos + 1] = u8(msg_len >> 16)
	buf[lenpos + 2] = u8(msg_len >> 8)
	buf[lenpos + 3] = u8(msg_len)
}

// write_parse appends a Parse ('P'): statement name, SQL, and 0 parameter type
// oids (let the server infer all parameter types).
pub fn write_parse(mut buf []u8, stmt_name string, query_text string) {
	lp := begin_msg(mut buf, `P`)
	put_cstr_s(mut buf, stmt_name)
	put_cstr_s(mut buf, query_text)
	put_u16(mut buf, 0)
	finish_msg(mut buf, lp)
}

// write_bind appends a Bind ('B'): text-format params in (null = length -1),
// binary-format results out (one result-format-code 1 applied to all columns).
pub fn write_bind(mut buf []u8, portal string, stmt_name string, params []?[]u8) {
	lp := begin_msg(mut buf, `B`)
	put_cstr_s(mut buf, portal)
	put_cstr_s(mut buf, stmt_name)
	put_u16(mut buf, 0) // 0 parameter format codes ⇒ all params are text
	put_u16(mut buf, u16(params.len))
	for p in params {
		if v := p {
			put_u32(mut buf, u32(v.len))
			buf << v
		} else {
			put_u32(mut buf, 0xFFFF_FFFF) // -1 ⇒ SQL NULL
		}
	}
	put_u16(mut buf, 1) // 1 result-format code...
	put_u16(mut buf, 1) // ...= binary, applied to every column
	finish_msg(mut buf, lp)
}

// write_describe_portal appends a Describe ('D') for a portal — its RowDescription
// is returned before the rows.
pub fn write_describe_portal(mut buf []u8, portal string) {
	lp := begin_msg(mut buf, `D`)
	buf << u8(`P`)
	put_cstr_s(mut buf, portal)
	finish_msg(mut buf, lp)
}

// write_execute appends an Execute ('E'): portal and a max-rows cap (0 = all).
pub fn write_execute(mut buf []u8, portal string, max_rows int) {
	lp := begin_msg(mut buf, `E`)
	put_cstr_s(mut buf, portal)
	put_u32(mut buf, u32(max_rows))
	finish_msg(mut buf, lp)
}

// write_sync appends a Sync ('S') — flushes the pipeline and asks for a
// ReadyForQuery.
pub fn write_sync(mut buf []u8) {
	buf << u8(`S`)
	put_u32(mut buf, 4)
}

// write_terminate appends a Terminate ('X').
pub fn write_terminate(mut buf []u8) {
	buf << u8(`X`)
	put_u32(mut buf, 4)
}

// write_sasl_initial appends a SASLInitialResponse ('p'): mechanism name, then
// the Int32-length-prefixed client-first message.
pub fn write_sasl_initial(mut buf []u8, mechanism string, client_first []u8) {
	lp := begin_msg(mut buf, `p`)
	put_cstr_s(mut buf, mechanism)
	put_u32(mut buf, u32(client_first.len))
	buf << client_first
	finish_msg(mut buf, lp)
}

// write_sasl_response appends a SASLResponse ('p'): the raw client-final bytes.
pub fn write_sasl_response(mut buf []u8, data []u8) {
	lp := begin_msg(mut buf, `p`)
	buf << data
	finish_msg(mut buf, lp)
}
