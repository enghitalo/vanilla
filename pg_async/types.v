module pg_async

import encoding.binary

// Binary (network byte order) decoders for PostgreSQL result columns.
//
// The client Binds every column with result-format-code 1, so DataRow values
// arrive in BINARY — no text int/float parsing on the hot path (this is one of
// the reasons a native client beats a text-format libpq round-trip). Each
// decoder takes the raw column bytes already split out of the DataRow by
// Row.col(); the slice borrows the connection recv buffer and is valid only for
// the duration of the resume callback.

@[inline]
pub fn decode_int2(b []u8) !i16 {
	if b.len != 2 {
		return error('int2: bad width ${b.len}')
	}
	return i16(binary.big_endian_u16(b))
}

@[inline]
pub fn decode_int4(b []u8) !i32 {
	if b.len != 4 {
		return error('int4: bad width ${b.len}')
	}
	return i32(binary.big_endian_u32(b))
}

@[inline]
pub fn decode_int8(b []u8) !i64 {
	if b.len != 8 {
		return error('int8: bad width ${b.len}')
	}
	return i64(binary.big_endian_u64(b))
}

@[inline]
pub fn decode_bool(b []u8) !bool {
	if b.len != 1 {
		return error('bool: bad width ${b.len}')
	}
	return b[0] != 0
}

@[inline]
pub fn decode_float8(b []u8) !f64 {
	if b.len != 8 {
		return error('float8: bad width ${b.len}')
	}
	bits := binary.big_endian_u64(b)
	return unsafe { *(&f64(&bits)) }
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
// than an escaped string.
@[inline]
pub fn jsonb_text(raw []u8) []u8 {
	return if raw.len > 0 && raw[0] == 0x01 { raw[1..] } else { raw }
}
