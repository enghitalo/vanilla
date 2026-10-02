module pg_async

import encoding.binary
import math
import time

// Binary (network byte order) decoders for PostgreSQL result columns.
//
// The client Binds every column with result-format-code 1, so DataRow values
// arrive in BINARY — no text int/float parsing on the hot path (this is one of
// the reasons a native client beats a text-format libpq round-trip). Each
// decoder takes the raw column bytes already split out of the DataRow by
// Row.col(); the slice borrows the connection recv buffer and is valid only for
// the duration of the resume callback.
//
// The bytes come from the server: every decoder checks every width and header
// field before it indexes, and rejects what PostgreSQL never sends. Nothing
// allocates, errors included (they are constants): the *_into decoders append
// into a buffer the caller owns and reuses.

// Type OIDs (pg_type.oid) of the built-in types the decoders read — compare
// them with Columns.type_oid.
pub const oid_bool = u32(16)
pub const oid_bytea = u32(17)
pub const oid_int8 = u32(20)
pub const oid_int2 = u32(21)
pub const oid_int4 = u32(23)
pub const oid_text = u32(25)
pub const oid_float4 = u32(700)
pub const oid_float8 = u32(701)
pub const oid_name = u32(19)
pub const oid_bpchar = u32(1042)
pub const oid_varchar = u32(1043)
pub const oid_date = u32(1082)
pub const oid_timestamp = u32(1114)
pub const oid_timestamptz = u32(1184)
pub const oid_numeric = u32(1700)
pub const oid_uuid = u32(2950)
pub const oid_jsonb = u32(3802)
pub const oid_int4_array = u32(1007)
pub const oid_text_array = u32(1009)
pub const oid_int8_array = u32(1016)

// The ±infinity sentinels of timestamp / timestamptz (decode_timestamp_us) and
// date (decode_date_days): PostgreSQL's own encoding of 'infinity' and
// '-infinity'.
pub const timestamp_infinity = max_i64
pub const timestamp_neg_infinity = min_i64
pub const date_infinity = max_i32
pub const date_neg_infinity = min_i32

// pg_epoch_unix_s is 2000-01-01T00:00:00Z, PostgreSQL's date/time epoch, as
// Unix seconds.
const pg_epoch_unix_s = i64(946_684_800)

const pg_epoch_unix_days = i64(10_957)

const err_int2_width = error('pg: int2: expected 2 bytes')
const err_int4_width = error('pg: int4: expected 4 bytes')
const err_int8_width = error('pg: int8: expected 8 bytes')
const err_bool_width = error('pg: bool: expected 1 byte')
const err_float4_width = error('pg: float4: expected 4 bytes')
const err_float8_width = error('pg: float8: expected 8 bytes')
const err_uuid_width = error('pg: uuid: expected 16 bytes')
const err_timestamp_width = error('pg: timestamp: expected 8 bytes')
const err_timestamp_infinite = error('pg: timestamp: ±infinity has no time.Time (read decode_timestamp_us)')
const err_timestamp_range = error('pg: timestamp: out of time.Time range')
const err_date_width = error('pg: date: expected 4 bytes')
const err_date_infinite = error('pg: date: ±infinity has no time.Time (read decode_date_days)')
const err_numeric_malformed = error('pg: numeric: malformed value')
const err_numeric_special = error('pg: numeric: NaN or ±Infinity has no integer value')
const err_numeric_precision = error('pg: numeric: more fractional digits than the scale keeps')
const err_numeric_range = error('pg: numeric: out of i64 range at this scale')
const err_array_malformed = error('pg: array: malformed value')
const err_array_dims = error('pg: array: only one-dimensional arrays are supported')
const err_array_null = error('pg: array: NULL element (read it with Row.array_iter)')
const err_array_elem_type = error('pg: array: element type does not match the accessor')

@[inline]
pub fn decode_int2(b []u8) !i16 {
	if b.len != 2 {
		return err_int2_width
	}
	return i16(binary.big_endian_u16(b))
}

@[inline]
pub fn decode_int4(b []u8) !i32 {
	if b.len != 4 {
		return err_int4_width
	}
	return i32(binary.big_endian_u32(b))
}

@[inline]
pub fn decode_int8(b []u8) !i64 {
	if b.len != 8 {
		return err_int8_width
	}
	return i64(binary.big_endian_u64(b))
}

@[inline]
pub fn decode_bool(b []u8) !bool {
	if b.len != 1 {
		return err_bool_width
	}
	return b[0] != 0
}

@[inline]
pub fn decode_float4(b []u8) !f32 {
	if b.len != 4 {
		return err_float4_width
	}
	return math.f32_from_bits(binary.big_endian_u32(b))
}

@[inline]
pub fn decode_float8(b []u8) !f64 {
	if b.len != 8 {
		return err_float8_width
	}
	return math.f64_from_bits(binary.big_endian_u64(b))
}

// decode_text returns the bytes as-is (PG text / varchar / numeric-as-text, and
// the body of a JSONB value once its 1-byte version prefix is stripped). The
// slice borrows the recv buffer — copy it if it must outlive the continuation.
@[inline]
pub fn decode_text(b []u8) []u8 {
	return b
}

// jsonb_text strips the JSONB binary version header (a leading 0x01) so the
// remainder is valid JSON text that re-encodes as a real array/object rather
// than an escaped string. Like decode_text, it borrows `raw`'s bytes.
@[direct_array_access; inline]
pub fn jsonb_text(raw []u8) []u8 {
	if raw.len > 0 && raw[0] == 0x01 {
		// A view, not raw[1..]: slicing marks the source buffer on every call.
		return unsafe { (&u8(raw.data) + 1).vbytes(raw.len - 1) }
	}
	return raw
}

// decode_uuid returns a uuid's 16 bytes.
pub fn decode_uuid(b []u8) ![16]u8 {
	if b.len != 16 {
		return err_uuid_width
	}
	mut u := [16]u8{}
	unsafe { vmemcpy(&u[0], b.data, 16) }
	return u
}

const hex_lower = '0123456789abcdef'

// uuid_into appends a uuid's canonical text form (36 characters, lowercase:
// c7e5b8ff-8279-457c-a557-cba06320423b) to `out`.
@[direct_array_access]
pub fn uuid_into(b []u8, mut out []u8) ! {
	if b.len != 16 {
		return err_uuid_width
	}
	// One capacity check, then the characters written in place: a push per
	// character is a call each.
	mut pos := out.len
	unsafe { out.grow_len(36) }
	for i in 0 .. 16 {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[pos] = `-`
			pos++
		}
		out[pos] = hex_lower[b[i] >> 4]
		out[pos + 1] = hex_lower[b[i] & 0x0f]
		pos += 2
	}
}

// decode_timestamp_us returns a timestamp / timestamptz as microseconds since
// 2000-01-01 00:00:00 (UTC for timestamptz; the wall-clock time for a
// timestamp without time zone), or timestamp_infinity /
// timestamp_neg_infinity. (integer_datetimes: on since PostgreSQL 10.)
@[inline]
pub fn decode_timestamp_us(b []u8) !i64 {
	if b.len != 8 {
		return err_timestamp_width
	}
	return i64(binary.big_endian_u64(b))
}

// timestamp_time is a decoded timestamp as a time.Time (UTC). ±infinity has
// none: an error.
pub fn timestamp_time(us i64) !time.Time {
	if us == timestamp_infinity || us == timestamp_neg_infinity {
		return err_timestamp_infinite
	}
	offset := pg_epoch_unix_s * 1_000_000
	if us > max_i64 - offset {
		return err_timestamp_range
	}
	// Floor division: before 1970 the microseconds stay non-negative
	// (time.unix_micro truncates toward zero).
	unix_us := us + offset
	mut secs := unix_us / 1_000_000
	mut rem := unix_us % 1_000_000
	if rem < 0 {
		secs--
		rem += 1_000_000
	}
	return time.unix_nanosecond(secs, int(rem) * 1000)
}

// decode_date_days returns a date as days since 2000-01-01, or date_infinity /
// date_neg_infinity.
@[inline]
pub fn decode_date_days(b []u8) !i32 {
	if b.len != 4 {
		return err_date_width
	}
	return i32(binary.big_endian_u32(b))
}

// date_time is a decoded date as a time.Time at midnight UTC. ±infinity has
// none: an error.
pub fn date_time(days i32) !time.Time {
	if days == date_infinity || days == date_neg_infinity {
		return err_date_infinite
	}
	return time.unix((i64(days) + pg_epoch_unix_days) * 86_400)
}

// numeric's sign word (NUMERIC_POS / NEG / NAN / PINF / NINF).
const numeric_pos = u16(0x0000)
const numeric_neg = u16(0x4000)
const numeric_nan = u16(0xC000)
const numeric_pinf = u16(0xD000)
const numeric_ninf = u16(0xF000)

// NumericHeader is a binary numeric's header, checked against its length:
// ndigits base-10000 digits follow, the first worth 10000^weight.
struct NumericHeader {
	ndigits int
	weight  int
	sign    u16
	dscale  int
}

@[direct_array_access]
fn numeric_header(b []u8) !NumericHeader {
	if b.len < 8 {
		return err_numeric_malformed
	}
	h := NumericHeader{
		ndigits: int(i16(binary.big_endian_u16_at(b, 0)))
		weight:  int(i16(binary.big_endian_u16_at(b, 2)))
		sign:    binary.big_endian_u16_at(b, 4)
		dscale:  int(binary.big_endian_u16_at(b, 6))
	}
	// dscale is 14 bits (NUMERIC_DSCALE_MASK); the digit count is exact.
	if h.ndigits < 0 || b.len != 8 + 2 * h.ndigits || h.dscale > 0x3FFF {
		return err_numeric_malformed
	}
	match h.sign {
		numeric_pos, numeric_neg {}
		numeric_nan, numeric_pinf, numeric_ninf {
			if h.ndigits != 0 {
				return err_numeric_malformed
			}
		}
		else {
			return err_numeric_malformed
		}
	}
	for k in 0 .. h.ndigits {
		if binary.big_endian_u16_at(b, 8 + 2 * k) > 9999 {
			return err_numeric_malformed
		}
	}
	return h
}

// numeric_digit is base-10000 digit k (0 outside the stored digits: the
// value's implicit zeros).
@[direct_array_access; inline]
fn numeric_digit(b []u8, h NumericHeader, k int) int {
	if k < 0 || k >= h.ndigits {
		return 0
	}
	return int(binary.big_endian_u16_at(b, 8 + 2 * k))
}

// numeric_text_into appends a numeric's exact decimal text to `out`, as
// PostgreSQL prints it: -123.4500 keeps its display scale; NaN, Infinity,
// -Infinity.
@[direct_array_access]
pub fn numeric_text_into(b []u8, mut out []u8) ! {
	h := numeric_header(b)!
	match h.sign {
		numeric_nan {
			unsafe { out.push_many(c'NaN', 3) }
			return
		}
		numeric_pinf {
			unsafe { out.push_many(c'Infinity', 8) }
			return
		}
		numeric_ninf {
			unsafe { out.push_many(c'-Infinity', 9) }
			return
		}
		else {}
	}
	// The length is known up front: one capacity check, then the digits
	// written in place (a push per digit is a call each).
	first := if h.weight < 0 { 0 } else { numeric_digit(b, h, 0) }
	mut n := if h.weight < 0 { 1 } else { group_width(first) + 4 * h.weight }
	if h.sign == numeric_neg {
		n++
	}
	if h.dscale > 0 {
		n += 1 + h.dscale
	}
	mut pos := out.len
	unsafe { out.grow_len(n) }
	if h.sign == numeric_neg {
		out[pos] = `-`
		pos++
	}
	// The integer part: digits 0..=weight, the first without leading zeros.
	if h.weight < 0 {
		out[pos] = `0`
		pos++
	} else {
		pos = put_digits(mut out, pos, first, group_width(first))
		for k in 1 .. h.weight + 1 {
			pos = put_digits(mut out, pos, numeric_digit(b, h, k), 4)
		}
	}
	// The fraction: dscale decimal digits, from digit weight+1 on; the last
	// group contributes only its leading digits.
	if h.dscale > 0 {
		out[pos] = `.`
		pos++
		mut left := h.dscale
		mut k := h.weight + 1
		for left > 0 {
			w := if left < 4 { left } else { 4 }
			pos = put_digits(mut out, pos, numeric_digit(b, h, k) / group_div[4 - w], w)
			left -= w
			k++
		}
	}
}

// group_div[i] is 10^i: the divisor that keeps the first 4 - i digits of a
// base-10000 digit.
const group_div = [1, 10, 100, 1000]!

// group_width is the number of decimal digits of a base-10000 digit printed
// without leading zeros (at least one).
@[inline]
fn group_width(d int) int {
	return if d >= 1000 {
		4
	} else if d >= 100 {
		3
	} else if d >= 10 {
		2
	} else {
		1
	}
}

// put_digits writes v as exactly w decimal digits (zero-padded) at out[pos..]
// and returns the position after them.
@[direct_array_access; inline]
fn put_digits(mut out []u8, pos int, v int, w int) int {
	mut x := v
	for i := w - 1; i >= 0; i-- {
		out[pos + i] = u8(`0` + x % 10)
		x /= 10
	}
	return pos + w
}

// decode_numeric_i64_scaled returns a numeric as an integer count of 10^-scale
// units — 123.45 at scale 2 is 12345 — for money and other fixed-point
// columns, without floating point. It errors rather than round: on NaN or
// ±Infinity, on a non-zero digit past `scale` decimals, and outside i64.
@[direct_array_access]
pub fn decode_numeric_i64_scaled(b []u8, scale int) !i64 {
	h := numeric_header(b)!
	if h.sign != numeric_pos && h.sign != numeric_neg {
		return err_numeric_special
	}
	if scale < 0 || scale > 18 {
		return err_numeric_range
	}
	// The magnitude, accumulated decimal digit by decimal digit: the integer
	// part, then `scale` fraction digits; the rest must be zero.
	limit := if h.sign == numeric_neg { u64(1) << 63 } else { u64(max_i64) }
	mut acc := u64(0)
	first := if h.weight < 0 { h.weight + 1 } else { 0 }
	last_int := h.weight // digits first..=weight are integer digits
	mut frac_left := scale
	mut k := first
	for {
		d := numeric_digit(b, h, k)
		mut div := 1000
		for div > 0 {
			digit := u64((d / div) % 10)
			div /= 10
			if k > last_int {
				if frac_left == 0 {
					if digit != 0 {
						return err_numeric_precision
					}
					continue
				}
				frac_left--
			}
			if acc > (limit - digit) / 10 {
				return err_numeric_range
			}
			acc = acc * 10 + digit
		}
		k++
		if k > last_int && frac_left == 0 && k >= h.ndigits {
			break
		}
	}
	return if h.sign == numeric_neg {
		if acc == u64(1) << 63 { min_i64 } else { -i64(acc) }
	} else {
		i64(acc)
	}
}

// ArrayIter walks a one-dimensional binary array's elements in order, as
// borrowed DataValues (is_null for a NULL element). decode_array checks the
// whole array first, so next() cannot fail.
pub struct ArrayIter {
pub:
	elem_oid    u32 // the element type's OID
	len         int // the number of elements
	lower_bound int // the first element's index (1 unless the array was built otherwise)
mut:
	buf  []u8
	pos  int
	left int
}

// decode_array checks a binary array (header, dimension, every element's
// length) and returns an iterator over its elements. An empty array has no
// dimension; a multi-dimensional one is an error.
@[direct_array_access]
pub fn decode_array(b []u8) !ArrayIter {
	if b.len < 12 {
		return err_array_malformed
	}
	ndim := int(i32(binary.big_endian_u32_at(b, 0)))
	has_null := binary.big_endian_u32_at(b, 4)
	elem_oid := binary.big_endian_u32_at(b, 8)
	if has_null > 1 {
		return err_array_malformed
	}
	if ndim == 0 {
		if b.len != 12 {
			return err_array_malformed
		}
		return ArrayIter{
			elem_oid: elem_oid
			buf:      b
			pos:      12
		}
	}
	if ndim < 0 || ndim > 6 {
		return err_array_malformed // PostgreSQL's MAXDIM is 6
	}
	if ndim > 1 {
		return err_array_dims
	}
	if b.len < 20 {
		return err_array_malformed
	}
	count := int(i32(binary.big_endian_u32_at(b, 12)))
	lbound := int(i32(binary.big_endian_u32_at(b, 16)))
	// Every element takes at least its 4-byte length: a count the bytes cannot
	// hold is rejected before walking it.
	if count < 0 || count > (b.len - 20) / 4 {
		return err_array_malformed
	}
	mut pos := 20
	mut saw_null := false
	for _ in 0 .. count {
		if b.len - pos < 4 {
			return err_array_malformed
		}
		elen := int(i32(binary.big_endian_u32_at(b, pos)))
		pos += 4
		if elen == -1 {
			saw_null = true
			continue
		}
		if elen < 0 || elen > b.len - pos {
			return err_array_malformed
		}
		pos += elen
	}
	if pos != b.len || (saw_null && has_null == 0) {
		return err_array_malformed
	}
	return ArrayIter{
		elem_oid:    elem_oid
		len:         count
		lower_bound: lbound
		buf:         b
		pos:         20
		left:        count
	}
}

// next returns the next element: its borrowed bytes, or is_null.
@[direct_array_access]
pub fn (mut it ArrayIter) next() ?DataValue {
	if it.left <= 0 {
		return none
	}
	it.left--
	elen := int(i32(binary.big_endian_u32_at(it.buf, it.pos)))
	it.pos += 4
	if elen < 0 {
		return DataValue{
			is_null: true
		}
	}
	start := it.pos
	it.pos += elen
	return DataValue{
		bytes: unsafe { (&u8(it.buf.data) + start).vbytes(elen) }
	}
}
