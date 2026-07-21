module http2

// HPACK decoder/encoder tests. The multi-block sequences are the RFC 7541
// Appendix C examples byte-for-byte (C.3 requests without Huffman, C.4 with,
// C.5 responses with a 256-byte table forcing evictions) — including the
// RFC's published dynamic-table sizes after every block.
import encoding.hex

fn hx(s string) []u8 {
	return hex.decode(s) or { panic(err) }
}

fn int_decoding_fails(buf []u8, prefix int) bool {
	decode_int(buf, 0, prefix) or { return true }
	return false
}

fn field(name string, value string) HeaderField {
	return HeaderField{
		name:  name
		value: value
	}
}

fn test_decode_int_edges() ! {
	// RFC 7541 C.1.1: 10 in a 5-bit prefix.
	v0, p0 := decode_int([u8(0x0a)], 0, 5)!
	assert v0 == 10
	assert p0 == 1
	// RFC 7541 C.1.2: 1337 in a 5-bit prefix.
	v1, p1 := decode_int([u8(0x1f), 0x9a, 0x0a], 0, 5)!
	assert v1 == 1337
	assert p1 == 3
	// RFC 7541 C.1.3: 42 in an 8-bit prefix.
	v2, p2 := decode_int([u8(0x2a)], 0, 8)!
	assert v2 == 42
	assert p2 == 1
	// Exactly the prefix maximum needs a zero continuation byte.
	v3, p3 := decode_int([u8(0x1f), 0x00], 0, 5)!
	assert v3 == 31
	assert p3 == 2
	// Truncated continuation.
	assert int_decoding_fails([u8(0x1f)], 5)
	// Unbounded continuation must be rejected, not wrapped.
	assert int_decoding_fails([u8(0x1f), 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f], 5)
}

fn test_encode_int_roundtrip() ! {
	values := [u32(0), 1, 15, 16, 30, 31, 32, 127, 128, 255, 256, 16383, 16384, 1048576]
	for prefix in [4, 5, 6, 7] {
		for v in values {
			mut out := []u8{}
			encode_int(mut out, 0x00, prefix, v)
			got, p := decode_int(out, 0, prefix)!
			assert got == v
			assert p == out.len
		}
	}
}

fn test_huffman_decode_known_strings() ! {
	// RFC 7541 C.4.1: Huffman('www.example.com').
	mut out := []u8{}
	huffman_decode(hx('f1e3c2e5f23a6ba0ab90f4ff'), mut out)!
	assert out.bytestr() == 'www.example.com'
	// RFC 7541 C.4.2: Huffman('no-cache').
	out.clear()
	huffman_decode(hx('a8eb10649cbf'), mut out)!
	assert out.bytestr() == 'no-cache'
	// RFC 7541 C.4.3: Huffman('custom-key') / Huffman('custom-value').
	out.clear()
	huffman_decode(hx('25a849e95ba97d7f'), mut out)!
	assert out.bytestr() == 'custom-key'
	out.clear()
	huffman_decode(hx('25a849e95bb8e8b4bf'), mut out)!
	assert out.bytestr() == 'custom-value'
}

fn test_huffman_rejects_bad_padding_and_eos() {
	// '0' (00000) + 3 zero padding bits: padding must be all ones.
	mut out := []u8{}
	if _ := huffman_decode([u8(0x00)], mut out) {
		assert false
	}
	// The 30-bit EOS code + 2 one-bits of padding: EOS in data is an error.
	out.clear()
	if _ := huffman_decode([u8(0xff), 0xff, 0xff, 0xff], mut out) {
		assert false
	}
}

fn test_static_indexed_fields() ! {
	mut d := new_decoder(hpack_default_table_size)
	got := d.decode(hx('8288'))!
	assert got == [field(':method', 'GET'), field(':status', '200')]
	assert d.dynamic_size() == 0
}

fn test_index_errors() {
	mut d := new_decoder(hpack_default_table_size)
	// Index 0 is a decoding error (RFC 7541 §6.1).
	if _ := d.decode([u8(0x80)]) {
		assert false
	}
	// Index 64 with an empty dynamic table is out of range.
	if _ := d.decode([u8(0xc0)]) {
		assert false
	}
}

// RFC 7541 C.3 — three request blocks on one connection, no Huffman.
fn test_rfc7541_c3_requests_plain() ! {
	mut d := new_decoder(hpack_default_table_size)
	first := d.decode(hx('828684410f7777772e6578616d706c652e636f6d'))!
	assert first == [field(':method', 'GET'), field(':scheme', 'http'),
		field(':path', '/'), field(':authority', 'www.example.com')]
	assert d.dynamic_size() == 57
	second := d.decode(hx('828684be58086e6f2d6361636865'))!
	assert second == [field(':method', 'GET'), field(':scheme', 'http'),
		field(':path', '/'), field(':authority', 'www.example.com'),
		field('cache-control', 'no-cache')]
	assert d.dynamic_size() == 110
	third := d.decode(hx('828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565'))!
	assert third == [field(':method', 'GET'), field(':scheme', 'https'),
		field(':path', '/index.html'), field(':authority', 'www.example.com'),
		field('custom-key', 'custom-value')]
	assert d.dynamic_size() == 164
}

// RFC 7541 C.4 — the same three requests, Huffman-encoded strings.
fn test_rfc7541_c4_requests_huffman() ! {
	mut d := new_decoder(hpack_default_table_size)
	first := d.decode(hx('828684418cf1e3c2e5f23a6ba0ab90f4ff'))!
	assert first == [field(':method', 'GET'), field(':scheme', 'http'),
		field(':path', '/'), field(':authority', 'www.example.com')]
	assert d.dynamic_size() == 57
	second := d.decode(hx('828684be5886a8eb10649cbf'))!
	assert second == [field(':method', 'GET'), field(':scheme', 'http'),
		field(':path', '/'), field(':authority', 'www.example.com'),
		field('cache-control', 'no-cache')]
	assert d.dynamic_size() == 110
	third := d.decode(hx('828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf'))!
	assert third == [field(':method', 'GET'), field(':scheme', 'https'),
		field(':path', '/index.html'), field(':authority', 'www.example.com'),
		field('custom-key', 'custom-value')]
	assert d.dynamic_size() == 164
}

// RFC 7541 C.5-shaped responses: a table-size update to 256 leads the first
// block, and the third block's inserts evict earlier entries.
fn test_response_blocks_with_eviction() ! {
	mut d := new_decoder(hpack_default_table_size)
	first :=
		d.decode(hx('3fe101488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3'))!
	assert first == [field(':status', '302'), field('cache-control', 'private'),
		field('date', 'Mon, 21 Oct 2013 20:13:21 GMT'), field('location', 'https://www.example.com')]
	assert d.dynamic_size() == 222
	second := d.decode(hx('4883640effc1c0bf'))!
	assert second == [field(':status', '307'), field('cache-control', 'private'),
		field('date', 'Mon, 21 Oct 2013 20:13:21 GMT'), field('location', 'https://www.example.com')]
	assert d.dynamic_size() == 222
	third :=
		d.decode(hx('88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007'))!
	assert third == [field(':status', '200'), field('cache-control', 'private'),
		field('date', 'Mon, 21 Oct 2013 20:13:22 GMT'), field('location', 'https://www.example.com'),
		field('content-encoding', 'gzip'),
		field('set-cookie',
			'foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1')]
	assert d.dynamic_size() == 215
	assert d.dynamic_size() <= 256
}

fn test_table_size_update_above_settings_limit_rejected() {
	mut d := new_decoder(128)
	// Update to 256 when the advertised limit is 128 — connection error.
	if _ := d.decode(hx('3fe101')) {
		assert false
	}
}

fn test_encoder_helpers_roundtrip() ! {
	mut d := new_decoder(hpack_default_table_size)
	mut out := []u8{}
	encode_status(mut out, 200)
	assert out == [u8(0x88)]
	encode_status(mut out, 302)
	encode_literal_name_idx(mut out, 21, '120') // 21 = age
	encode_literal(mut out, 'x-custom', 'yes')
	encode_literal(mut out, 'x-empty', '')
	got := d.decode(out)!
	assert got == [field(':status', '200'), field(':status', '302'),
		field('age', '120'), field('x-custom', 'yes'), field('x-empty', '')]
	// Stateless encoding must leave the peer's dynamic table untouched.
	assert d.dynamic_size() == 0
}
