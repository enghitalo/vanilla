module http2

// HPACK — RFC 7541 header compression for HTTP/2, the codec half the dormant
// module was missing (issue #122's http2 story). Pure functions + one decoder
// struct over bytes: no I/O, no vanilla imports — same discipline as the
// websocket codec.
//
// Decoding allocates (dynamic-table entries and Huffman output must outlive
// the wire bytes), which is fine: header decompression is per-request setup,
// not the per-byte hot path, and the h1 fast path is untouched.
//
// The encoder side is deliberately STATELESS: responses use indexed fields
// from the static table plus literals WITHOUT indexing (RFC 7541 §6.2.2), so
// no encoder dynamic table exists and no synchronization with the peer's
// decoder state is ever needed. That is spec-legal (indexing is optional) and
// keeps the server side allocation-free on the encode path.
//
// Decoder hardening: integer overflow caps, string/index bounds checks, EOS
// and padding validation in Huffman data, and a decoded-block size ceiling
// (`max_decoded_block`) so a compression bomb cannot balloon memory.

// A decoded header field. Name and value are owned copies — they outlive the
// wire buffer and the dynamic table references them.
pub struct HeaderField {
pub:
	name  string
	value string
}

// Ceiling on the decoded bytes of one header block (names + values). RFC 9113
// SETTINGS_MAX_HEADER_LIST_SIZE is advisory; this is the enforced local bound.
pub const max_decoded_block = 256 * 1024

// hpack_default_table_size is the protocol default for the decoder's dynamic
// table (RFC 7541 §4.2, RFC 9113 §6.5.2 SETTINGS_HEADER_TABLE_SIZE).
pub const hpack_default_table_size = 4096

// The static table (RFC 7541 Appendix A): indices 1..61, split into two
// parallel arrays so a lookup allocates nothing.
const static_name = [
	':authority',
	':method',
	':method',
	':path',
	':path',
	':scheme',
	':scheme',
	':status',
	':status',
	':status',
	':status',
	':status',
	':status',
	':status',
	'accept-charset',
	'accept-encoding',
	'accept-language',
	'accept-ranges',
	'accept',
	'access-control-allow-origin',
	'age',
	'allow',
	'authorization',
	'cache-control',
	'content-disposition',
	'content-encoding',
	'content-language',
	'content-length',
	'content-location',
	'content-range',
	'content-type',
	'cookie',
	'date',
	'etag',
	'expect',
	'expires',
	'from',
	'host',
	'if-match',
	'if-modified-since',
	'if-none-match',
	'if-range',
	'if-unmodified-since',
	'last-modified',
	'link',
	'location',
	'max-forwards',
	'proxy-authenticate',
	'proxy-authorization',
	'range',
	'referer',
	'refresh',
	'retry-after',
	'server',
	'set-cookie',
	'strict-transport-security',
	'transfer-encoding',
	'user-agent',
	'vary',
	'via',
	'www-authenticate',
]!

const static_value = [
	'',
	'GET',
	'POST',
	'/',
	'/index.html',
	'http',
	'https',
	'200',
	'204',
	'206',
	'304',
	'400',
	'404',
	'500',
	'',
	'gzip, deflate',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
	'',
]!

// Canonical-Huffman decode tables generated from the RFC 7541 Appendix B code
// table (the code is canonical: per bit-length, codes are consecutive).
// huff_len lists the bit-lengths that occur; per length i: huff_first[i] is
// the numerically first code, huff_count[i] how many symbols share the
// length, huff_base[i] their start in huff_symbol (symbols ordered by
// (length, code); 256 = EOS).
// vfmt off
const huff_len = [
	u8(5), 6, 7, 8, 10, 11, 12, 13, 14, 15, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 30,
]!

const huff_first = [
	u32(0x0), 0x14, 0x5c, 0xf8, 0x3f8, 0x7fa, 0xffa, 0x1ff8, 0x3ffc, 0x7ffc, 0x7fff0, 0xfffe6,
	0x1fffdc, 0x3fffd2, 0x7fffd8, 0xffffea, 0x1ffffec, 0x3ffffe0, 0x7ffffde, 0xfffffe2,
	0x3ffffffc,
]!

const huff_count = [
	u16(10), 26, 32, 6, 5, 3, 2, 6, 2, 3, 3, 8, 13, 26, 29, 12, 4, 15, 19, 29, 4,
]!

const huff_base = [
	u16(0), 10, 36, 68, 74, 79, 82, 84, 90, 92, 95, 98, 106, 119, 145, 174, 186, 190, 205, 224,
	253,
]!

const huff_symbol = [
	u16(48), 49, 50, 97, 99, 101, 105, 111, 115, 116, 32, 37, 45, 46, 47, 51, 52, 53, 54, 55, 56,
	57, 61, 65, 95, 98, 100, 102, 103, 104, 108, 109, 110, 112, 114, 117, 58, 66, 67, 68, 69, 70,
	71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 89, 106, 107, 113, 118,
	119, 120, 121, 122, 38, 42, 44, 59, 88, 90, 33, 34, 40, 41, 63, 39, 43, 124, 35, 62, 0, 36,
	64, 91, 93, 126, 94, 125, 60, 96, 123, 92, 195, 208, 128, 130, 131, 162, 184, 194, 224, 226,
	153, 161, 167, 172, 176, 177, 179, 209, 216, 217, 227, 229, 230, 129, 132, 133, 134, 136,
	146, 154, 156, 160, 163, 164, 169, 170, 173, 178, 181, 185, 186, 187, 189, 190, 196, 198,
	228, 232, 233, 1, 135, 137, 138, 139, 140, 141, 143, 147, 149, 150, 151, 152, 155, 157, 158,
	165, 166, 168, 174, 175, 180, 182, 183, 188, 191, 197, 231, 239, 9, 142, 144, 145, 148, 159,
	171, 206, 215, 225, 236, 237, 199, 207, 234, 235, 192, 193, 200, 201, 202, 205, 210, 213,
	218, 219, 238, 240, 242, 243, 255, 203, 204, 211, 212, 214, 221, 222, 223, 241, 244, 245,
	246, 247, 248, 250, 251, 252, 253, 254, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19,
	20, 21, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127, 220, 249, 10, 13, 22, 256,
]!
// vfmt on

// HpackDecoder holds the connection's receive-side dynamic table. One per
// connection, fed every header block in wire order (HPACK is stateful — a
// skipped block desynchronizes the table, so even discarded streams decode).
pub struct HpackDecoder {
mut:
	dyn      []HeaderField // newest entry first (index 62 = dyn[0])
	dyn_size int           // sum of entry sizes (name + value + 32, RFC 7541 §4.1)
	max_size int           // protocol ceiling (our SETTINGS_HEADER_TABLE_SIZE)
	cur_max  int           // current limit, lowered/raised by table-size updates
}

// new_decoder returns a decoder whose dynamic table is capped at `max_size`
// bytes (the value this server advertises in SETTINGS_HEADER_TABLE_SIZE).
pub fn new_decoder(max_size int) HpackDecoder {
	return HpackDecoder{
		max_size: max_size
		cur_max:  max_size
	}
}

// decode decompresses one complete header block (the concatenated fragments
// of HEADERS/CONTINUATION frames). Errors are connection-fatal per RFC 7541
// §5.3 / RFC 9113 §4.3: the caller must tear the connection down (GOAWAY
// COMPRESSION_ERROR) — the table state is unrecoverable after a bad block.
pub fn (mut d HpackDecoder) decode(block []u8) ![]HeaderField {
	mut out := []HeaderField{cap: 16}
	mut pos := 0
	mut decoded := 0
	mut fields_seen := false
	for pos < block.len {
		b := block[pos]
		if b & 0x80 != 0 {
			// Indexed header field (§6.1).
			idx, p := decode_int(block, pos, 7)!
			pos = p
			name, value := d.entry(idx)!
			decoded += name.len + value.len
			if decoded > max_decoded_block {
				return error('hpack: header block too large decoded')
			}
			fields_seen = true
			out << HeaderField{
				name:  name
				value: value
			}
		} else if b & 0xc0 == 0x40 {
			// Literal with incremental indexing (§6.2.1).
			idx, p := decode_int(block, pos, 6)!
			pos = p
			mut name := ''
			if idx > 0 {
				name, _ = d.entry(idx)!
			} else {
				name, pos = d.decode_str(block, pos)!
			}
			mut value := ''
			value, pos = d.decode_str(block, pos)!
			decoded += name.len + value.len
			if decoded > max_decoded_block {
				return error('hpack: header block too large decoded')
			}
			d.add(name, value)
			fields_seen = true
			out << HeaderField{
				name:  name
				value: value
			}
		} else if b & 0xe0 == 0x20 {
			// Dynamic table size update (§6.3) — only valid BEFORE the first
			// field of a block (RFC 7541 §4.2).
			if fields_seen {
				return error('hpack: table size update after a header field')
			}
			size, p := decode_int(block, pos, 5)!
			pos = p
			if int(size) > d.max_size {
				return error('hpack: table size update above SETTINGS limit')
			}
			d.cur_max = int(size)
			d.evict()
		} else {
			// Literal without indexing (§6.2.2) / never indexed (§6.2.3) —
			// identical on the decode side apart from the (unenforceable
			// here) re-encoding hint.
			idx, p := decode_int(block, pos, 4)!
			pos = p
			mut name := ''
			if idx > 0 {
				name, _ = d.entry(idx)!
			} else {
				name, pos = d.decode_str(block, pos)!
			}
			mut value := ''
			value, pos = d.decode_str(block, pos)!
			decoded += name.len + value.len
			if decoded > max_decoded_block {
				return error('hpack: header block too large decoded')
			}
			fields_seen = true
			out << HeaderField{
				name:  name
				value: value
			}
		}
	}
	return out
}

// dynamic_size reports the dynamic table's current byte size (tests/metrics).
pub fn (d &HpackDecoder) dynamic_size() int {
	return d.dyn_size
}

// entry resolves a table index: 1..61 static, 62.. dynamic (newest first).
fn (d &HpackDecoder) entry(idx u32) !(string, string) {
	if idx == 0 {
		return error('hpack: index 0')
	}
	if idx <= 61 {
		return static_name[idx - 1], static_value[idx - 1]
	}
	di := int(idx) - 62
	if di >= d.dyn.len {
		return error('hpack: index beyond table')
	}
	return d.dyn[di].name, d.dyn[di].value
}

// add inserts an entry at the head of the dynamic table, then evicts from the
// tail until the table fits cur_max. An entry larger than the whole table
// empties it and is itself dropped (RFC 7541 §4.4) — insert-then-evict yields
// exactly that.
fn (mut d HpackDecoder) add(name string, value string) {
	d.dyn.insert(0, HeaderField{
		name:  name
		value: value
	})
	d.dyn_size += name.len + value.len + 32
	d.evict()
}

fn (mut d HpackDecoder) evict() {
	for d.dyn_size > d.cur_max && d.dyn.len > 0 {
		last := d.dyn.pop()
		d.dyn_size -= last.name.len + last.value.len + 32
	}
}

// decode_str reads one string literal (§5.2): a Huffman flag + 7-bit-prefix
// length, then the octets (Huffman-decoded when flagged).
fn (mut d HpackDecoder) decode_str(block []u8, pos int) !(string, int) {
	if pos >= block.len {
		return error('hpack: truncated string')
	}
	huff := block[pos] & 0x80 != 0
	length, p := decode_int(block, pos, 7)!
	n := int(length)
	if n < 0 || p + n > block.len {
		return error('hpack: string length beyond block')
	}
	if n == 0 {
		return '', p
	}
	src := unsafe { (&block[p]).vbytes(n) }
	if !huff {
		return src.bytestr(), p + n
	}
	// Huffman output is at most 8/5 of the input (shortest code is 5 bits).
	mut tmp := []u8{cap: n * 8 / 5 + 1}
	huffman_decode(src, mut tmp)!
	return tmp.bytestr(), p + n
}

// decode_int reads an N-bit-prefix integer (§5.1). Accumulates in u64 so no
// intermediate overflow is possible, then rejects values above 2^28 — far
// beyond any legitimate index, length or table size.
fn decode_int(block []u8, pos int, prefix int) !(u32, int) {
	if pos >= block.len {
		return error('hpack: truncated integer')
	}
	mask := u32((1 << prefix) - 1)
	mut v := u64(u32(block[pos]) & mask)
	mut p := pos + 1
	if v < u64(mask) {
		return u32(v), p
	}
	mut shift := 0
	for {
		if p >= block.len {
			return error('hpack: truncated integer')
		}
		b := block[p]
		p++
		v += u64(b & 0x7f) << shift
		shift += 7
		if shift > 35 {
			return error('hpack: integer too long')
		}
		if b & 0x80 == 0 {
			break
		}
	}
	if v > (u64(1) << 28) {
		return error('hpack: integer too large')
	}
	return u32(v), p
}

// encode_int appends an N-bit-prefix integer with the instruction's flag bits
// in the byte's high side (§5.1).
fn encode_int(mut out []u8, flags u8, prefix int, value u32) {
	mask := u32((1 << prefix) - 1)
	if value < mask {
		out << (flags | u8(value))
		return
	}
	out << (flags | u8(mask))
	mut v := value - mask
	for v >= 0x80 {
		out << u8((v & 0x7f) | 0x80)
		v >>= 7
	}
	out << u8(v)
}

// encode_str appends a raw (non-Huffman) string literal (§5.2).
fn encode_str(mut out []u8, s string) {
	encode_int(mut out, 0x00, 7, u32(s.len))
	if s.len > 0 {
		unsafe { out.push_many(s.str, s.len) }
	}
}

// encode_indexed appends an indexed header field (§6.1) — the 1-byte form for
// anything in the static table, e.g. index 8 = `:status: 200`.
pub fn encode_indexed(mut out []u8, idx int) {
	encode_int(mut out, 0x80, 7, u32(idx))
}

// encode_literal_name_idx appends a literal without indexing whose NAME comes
// from a table index (§6.2.2) — e.g. `:status` (8) with an uncommon code.
pub fn encode_literal_name_idx(mut out []u8, name_idx int, value string) {
	encode_int(mut out, 0x00, 4, u32(name_idx))
	encode_str(mut out, value)
}

// encode_literal appends a literal without indexing with a literal name
// (§6.2.2). HTTP/2 field names MUST be lowercase (RFC 9113 §8.2) — that is
// the caller's contract, this appends the bytes as given.
pub fn encode_literal(mut out []u8, name string, value string) {
	out << u8(0x00)
	encode_str(mut out, name)
	encode_str(mut out, value)
}

// encode_status appends the `:status` response pseudo-header: the 1-byte
// static-table form for the seven pre-indexed codes, a literal otherwise.
pub fn encode_status(mut out []u8, status int) {
	match status {
		200 {
			encode_indexed(mut out, 8)
		}
		204 {
			encode_indexed(mut out, 9)
		}
		206 {
			encode_indexed(mut out, 10)
		}
		304 {
			encode_indexed(mut out, 11)
		}
		400 {
			encode_indexed(mut out, 12)
		}
		404 {
			encode_indexed(mut out, 13)
		}
		500 {
			encode_indexed(mut out, 14)
		}
		else {
			mut digits := [u8(0), 0, 0]
			digits[0] = u8(`0` + (status / 100) % 10)
			digits[1] = u8(`0` + (status / 10) % 10)
			digits[2] = u8(`0` + status % 10)
			encode_int(mut out, 0x00, 4, 8) // name index 8 = :status
			encode_int(mut out, 0x00, 7, 3)
			out << digits[0]
			out << digits[1]
			out << digits[2]
		}
	}
}

// huffman_decode appends the decoded octets of `src` (RFC 7541 §5.2 + App. B)
// into `out`. Canonical decoding: the code table is a canonical Huffman code,
// so per bit-length a (first code, symbol range) pair identifies any code —
// no tree, just the five const arrays above. Rejects the EOS symbol in the
// stream and any padding that is not a prefix of EOS (all ones, < 8 bits).
fn huffman_decode(src []u8, mut out []u8) ! {
	mut cur := u64(0)
	mut nbits := 0
	for b in src {
		cur = cur << 8 | u64(b)
		nbits += 8
		for {
			mut matched := false
			for i in 0 .. huff_len.len {
				l := int(huff_len[i])
				if l > nbits {
					break
				}
				top := u32(cur >> (nbits - l))
				if top >= huff_first[i] && top < huff_first[i] + u32(huff_count[i]) {
					sym := huff_symbol[int(huff_base[i]) + int(top - huff_first[i])]
					if sym == 256 {
						return error('hpack: EOS symbol in huffman data')
					}
					out << u8(sym)
					nbits -= l
					cur &= (u64(1) << nbits) - 1
					matched = true
					break
				}
			}
			if !matched {
				if nbits >= 30 {
					return error('hpack: invalid huffman code')
				}
				break
			}
		}
	}
	if nbits > 7 {
		// More than 7 unconsumed bits is an incomplete symbol, not padding —
		// a decoding error even when the bits are all ones (RFC 7541 §5.2).
		return error('hpack: huffman padding longer than 7 bits')
	}
	if cur != (u64(1) << nbits) - 1 {
		return error('hpack: invalid huffman padding')
	}
}
