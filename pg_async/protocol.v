module pg_async

import encoding.binary
import time

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
		payload: unsafe { (&u8(it.buf.data) + it.pos + 5).vbytes(total - 5) }
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
// are binary (Bind requests result-format-code 1 for every column). To read a
// column by name, look its index up once per result (Result.columns()).
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

const err_row_short = error('pg: datarow: short payload')
const err_row_range = error('pg: datarow: column index out of range')
const err_row_truncated = error('pg: datarow: truncated value')
const err_row_null = error('pg: unexpected NULL (read a nullable column with Row.col)')

// col returns column i: error on malformed/out-of-range, is_null set for SQL
// NULL, else the borrowed column bytes.
@[direct_array_access]
pub fn (r Row) col(i int) !DataValue {
	if r.payload.len < 2 {
		return err_row_short
	}
	ncols := int(i16(binary.big_endian_u16_at(r.payload, 0)))
	if i < 0 || i >= ncols {
		return err_row_range
	}
	mut pos := 2
	for idx in 0 .. ncols {
		if pos + 4 > r.payload.len {
			return err_row_truncated
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
		if clen > r.payload.len - pos {
			return err_row_truncated
		}
		if idx == i {
			return DataValue{
				bytes: unsafe { (&u8(r.payload.data) + pos).vbytes(clen) }
			}
		}
		pos += clen
	}
	return err_row_range
}

fn (r Row) require(i int) ![]u8 {
	dv := r.col(i)!
	if dv.is_null {
		return err_row_null
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

pub fn (r Row) float4(i int) !f32 {
	return decode_float4(r.require(i)!)
}

pub fn (r Row) float8(i int) !f64 {
	return decode_float8(r.require(i)!)
}

pub fn (r Row) text(i int) ![]u8 {
	return decode_text(r.require(i)!)
}

// uuid returns a uuid column's 16 bytes.
pub fn (r Row) uuid(i int) ![16]u8 {
	return decode_uuid(r.require(i)!)
}

// uuid_into appends a uuid column's canonical text (36 characters) to `out`.
pub fn (r Row) uuid_into(i int, mut out []u8) ! {
	uuid_into(r.require(i)!, mut out)!
}

// timestamp_us returns a timestamp / timestamptz column as microseconds since
// 2000-01-01 (or timestamp_infinity / timestamp_neg_infinity).
pub fn (r Row) timestamp_us(i int) !i64 {
	return decode_timestamp_us(r.require(i)!)
}

// time returns a timestamp / timestamptz column as a time.Time (UTC); ±infinity
// is an error (read timestamp_us).
pub fn (r Row) time(i int) !time.Time {
	return timestamp_time(decode_timestamp_us(r.require(i)!)!)
}

// date_days returns a date column as days since 2000-01-01 (or date_infinity /
// date_neg_infinity).
pub fn (r Row) date_days(i int) !i32 {
	return decode_date_days(r.require(i)!)
}

// date returns a date column as a time.Time at midnight UTC; ±infinity is an
// error (read date_days).
pub fn (r Row) date(i int) !time.Time {
	return date_time(decode_date_days(r.require(i)!)!)
}

// numeric_text_into appends a numeric column's exact decimal text to `out`.
pub fn (r Row) numeric_text_into(i int, mut out []u8) ! {
	numeric_text_into(r.require(i)!, mut out)!
}

// numeric_i64_scaled returns a numeric column as a count of 10^-scale units
// (decode_numeric_i64_scaled): exact, or an error.
pub fn (r Row) numeric_i64_scaled(i int, scale int) !i64 {
	return decode_numeric_i64_scaled(r.require(i)!, scale)
}

// array_iter returns an iterator over a one-dimensional array column.
pub fn (r Row) array_iter(i int) !ArrayIter {
	return decode_array(r.require(i)!)
}

// int4_array_into appends an int4[] column's elements to `out`. A NULL
// element, or another element type, is an error, and then nothing is appended
// (walk such arrays with array_iter).
@[direct_array_access]
pub fn (r Row) int4_array_into(i int, mut out []i32) ! {
	arr := r.array_iter(i)!
	if arr.elem_oid != oid_int4 {
		return err_array_elem_type
	}
	// A walk over the checked elements, not arr.next(): appending what a `mut`
	// iterator yields makes V move the iterator to the heap on every call.
	start := out.len
	mut pos := arr.pos
	for _ in 0 .. arr.left {
		n := int(i32(binary.big_endian_u32_at(arr.buf, pos)))
		pos += 4
		if n != 4 {
			out.trim(start)
			return if n < 0 { err_array_null } else { err_int4_width }
		}
		out << i32(binary.big_endian_u32_at(arr.buf, pos))
		pos += 4
	}
}

// text_array_into appends a text[] (or varchar[], bpchar[], name[]) column's
// elements to `out`, as views that borrow the receive buffer. A NULL element,
// or another element type, is an error, and then nothing is appended (walk
// such arrays with array_iter).
@[direct_array_access]
pub fn (r Row) text_array_into(i int, mut out [][]u8) ! {
	arr := r.array_iter(i)!
	if arr.elem_oid != oid_text && arr.elem_oid != oid_varchar && arr.elem_oid != oid_bpchar
		&& arr.elem_oid != oid_name {
		return err_array_elem_type
	}
	start := out.len
	mut pos := arr.pos
	for _ in 0 .. arr.left {
		n := int(i32(binary.big_endian_u32_at(arr.buf, pos)))
		pos += 4
		if n < 0 {
			out.trim(start)
			return err_array_null
		}
		view := unsafe { (&u8(arr.buf.data) + pos).vbytes(n) }
		// push_many, not `out << view`: appending an array element clones it.
		unsafe { out.push_many(&view, 1) }
		pos += n
	}
}

// col_by_name returns the column named `name`, per the result's
// RowDescription. It searches the names on every call: in a loop over rows,
// look the index up once with Columns.index.
pub fn (r Row) col_by_name(cols Columns, name string) !DataValue {
	i := cols.index(name) or { return err_columns_no_such }
	return r.col(i)
}

// ── RowDescription ──────────────────────────────────────────────────────────

const err_columns_malformed = error('pg: rowdescription: malformed message')
const err_columns_range = error('pg: rowdescription: column index out of range')
const err_columns_no_such = error('pg: rowdescription: no column by that name')

// Columns is a result's RowDescription: each column's name and type OID, read
// from the borrowed message on demand. Nothing is parsed unless asked, so
// index-based row access never pays for it.
pub struct Columns {
mut:
	n       int
	payload []u8
}

// len is the number of columns.
pub fn (c Columns) len() int {
	return c.n
}

// columns returns the result's RowDescription (an empty Columns for a
// statement that returns no rows, e.g. an INSERT without RETURNING).
@[direct_array_access]
pub fn (res &Result) columns() !Columns {
	// next_message_at, not a FrameIter: a `mut` iterator whose bytes the
	// result borrows is moved to the heap by V's escape analysis, one
	// allocation per call.
	mut pos := 0
	for {
		hdr := next_message_at(res.frames, pos) or { break }
		if hdr.typ == bt_row_description {
			return columns_from(unsafe { (&u8(res.frames.data) + pos + 5).vbytes(hdr.total - 5) })
		}
		if hdr.typ == bt_data_row {
			break // RowDescription precedes the rows
		}
		pos += hdr.total
	}
	return Columns{}
}

// columns_from checks a RowDescription payload: every field complete.
@[direct_array_access]
fn columns_from(payload []u8) !Columns {
	if payload.len < 2 {
		return err_columns_malformed
	}
	n := int(i16(binary.big_endian_u16_at(payload, 0)))
	if n < 0 {
		return err_columns_malformed
	}
	mut pos := 2
	for _ in 0 .. n {
		pos = field_end(payload, pos)
		if pos < 0 {
			return err_columns_malformed
		}
	}
	if pos != payload.len {
		return err_columns_malformed
	}
	return Columns{
		n:       n
		payload: payload
	}
}

// field_end is where the field at pos ends: its NUL-terminated name, then 18
// bytes (table OID, column number, type OID, type size, modifier, format);
// -1 when it does not fit.
@[direct_array_access]
fn field_end(p []u8, pos int) int {
	mut i := pos
	for i < p.len && p[i] != 0 {
		i++
	}
	if i >= p.len || p.len - (i + 1) < 18 {
		return -1
	}
	return i + 1 + 18
}

// field_start is the offset of field i (columns_from checked them all).
@[direct_array_access]
fn (c Columns) field_start(i int) int {
	mut pos := 2
	for _ in 0 .. i {
		pos = field_end(c.payload, pos)
	}
	return pos
}

// name returns column i's name, as a view of the message.
@[direct_array_access]
pub fn (c Columns) name(i int) ![]u8 {
	if i < 0 || i >= c.n {
		return err_columns_range
	}
	start := c.field_start(i)
	// field_end is past the name's NUL and the 18 bytes after it.
	return unsafe { (&u8(c.payload.data) + start).vbytes(field_end(c.payload, start) - 19 - start) }
}

// type_oid returns column i's type OID (oid_int4, oid_uuid, ...). It walks
// the fields before column i: checking a few columns once per result is cheap,
// checking all of them costs O(n²) field steps.
@[direct_array_access]
pub fn (c Columns) type_oid(i int) !u32 {
	if i < 0 || i >= c.n {
		return err_columns_range
	}
	end := field_end(c.payload, c.field_start(i))
	// The type OID sits 12 bytes before the field's end: 4 (type OID) + 2
	// (type size) + 4 (modifier) + 2 (format).
	return binary.big_endian_u32_at(c.payload, end - 12)
}

// index returns the index of the first column named `name`, or none. It
// compares bytes in place: no allocation.
@[direct_array_access]
pub fn (c Columns) index(name string) ?int {
	mut pos := 2
	for i in 0 .. c.n {
		end := field_end(c.payload, pos)
		name_len := end - 19 - pos
		if name_len == name.len
			&& unsafe { vmemcmp(&u8(c.payload.data) + pos, name.str, name.len) } == 0 {
			return i
		}
		pos = end
	}
	return none
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

// PgError is a server-reported error (an ErrorResponse) as a typed V error, so a
// caller branches on the SQLSTATE instead of matching the message text:
//
//   poll := conn.async_on_readable() or {
//       if err is pg_async.PgError && err.sqlstate == '40001' {
//           // serialization failure: retry the whole transaction
//       }
//       ...
//   }
//
// msg() is the same text these errors always carried ("pg: query failed:
// <message> (SQLSTATE <code>)"); code() stays 0 (a SQLSTATE is alphanumeric,
// e.g. 57P01, so it has no faithful int form). A FATAL or PANIC severity means
// the server also ended the session: the connection is then broken (see
// PgConn.is_broken) and its pool re-dials it.
pub struct PgError {
	Error
pub:
	severity string // non-localized severity: ERROR, FATAL or PANIC
	sqlstate string // the five-character SQLSTATE, e.g. 23505, 40001, 57P01
	message  string // the primary human-readable message
}

pub fn (e PgError) msg() string {
	return 'pg: query failed: ${e.message} (SQLSTATE ${e.sqlstate})'
}

// ends_session reports whether an ErrorResponse severity terminates the session
// (FATAL / PANIC): the server closes the connection right after sending it, so
// no ReadyForQuery follows.
fn ends_session(severity []u8) bool {
	if severity.len != 5 {
		return false
	}
	s := unsafe { tos(severity.data, severity.len) } // a view: compared, never kept
	return s == 'FATAL' || s == 'PANIC'
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
// byte-identical: the same bytes followed by a NUL. Not core.append_str: its win is
// a const string whose copy gcc folds, and with these runtime strings it measured
// ~4% slower on the submit bench (vanilla#220).
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
