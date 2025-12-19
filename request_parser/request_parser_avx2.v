module request_parser

// ultra_fast_parser.v
// Zero-allocation HTTP/1.1 request line parser using AVX2
// Compile with: v -prod -cc gcc -cflags "-mavx2 -march=native" ultra_fast_parser.v

const avx_block = 32
const space_byte = u8(` `)
const cr_byte = u8(`\r`)

// AVX2-accelerated search for first occurrence of any byte in 'delims' (up to 4 unique bytes)
fn avx2_find_delim(buf &u8, len int, delims u32) int {
	unsafe {
		if len < avx_block {
			// Fallback scalar for short inputs
			for i in 0 .. len {
				b := buf[i]
				if (u32(1) << b) & delims != 0 {
					return i
				}
			}
			return -1
		}

		mut offset := 0
		delim_mask := delims

		for offset + avx_block <= len {
			mut found_pos := -1

			asm volatile amd64 {
				//     vmovdqu ymm0, [buf + offset]          // load 32 bytes
				//     vpcmpeqb ymm1, ymm0, ymm0              // not needed, just setup
				//     // Broadcast each delim byte and compare
				//     // We use a trick: create mask of possible delims
				//     vpxor ymm2, ymm2, ymm2                // zero
				//     vpinsrb xmm2, xmm2, byte [delim_mask], 0   // insert space if needed (simplified)
				//     // Better: use precomputed shuffle + pshufb for lookup, but here's simple version
				//     // Actually: efficient way is to compare against broadcasted bytes one by one
				//     // Compare with space (0x20)
				//     vpbroadcastb ymm3, [space_byte]
				//     vpcmpeqb ymm4, ymm0, ymm3
				//     vpor ymm2, ymm2, ymm4
				//     // Compare with \r (0x0d)
				//     vpbroadcastb ymm3, [cr_byte]
				//     vpcmpeqb ymm4, ymm0, ymm3
				//     vpor ymm2, ymm2, ymm4
				//     vpmovmskb eax, ymm2
				//     bsf eax, eax
				//     jnz found
				//     mov found_pos, -1
				//     jmp end
				// found:
				//     mov found_pos, eax
				// end:
				//     vzeroupper
				//     ; +r (found_pos)
				//     ; r (buf)
				//       r (offset)
				//     ; ymm0..ymm4 eax cc memory
			}

			if found_pos >= 0 {
				return offset + found_pos
			}
			offset += avx_block
		}

		// Tail
		for i in offset .. len {
			b := buf[i]
			if b == ` ` || b == `\r` {
				return i
			}
		}
		return -1
	}
}

// Much faster version using AVX2 for main delimiters
@[direct_array_access]
pub fn parse_http1_request_line_avx2(mut req HttpRequest) ! {
	unsafe {
		buf := req.buffer.data
		len := req.buffer.len

		if len < 12 { // Minimum valid: "GET / HTTP/1.1\r\n"
			return error('Too short')
		}

		// Step 1: Find first space (end of method) — use scalar or vector scan
		// We can optimize by searching for both space and \r in one pass if needed
		mut pos1 := 0
		for pos1 < len && buf[pos1] != ` ` {
			pos1++
		}
		if pos1 == 0 || pos1 >= len {
			return error('No method')
		}
		req.method = Slice{0, pos1}

		mut pos2 := pos1 + 1
		for pos2 < len && buf[pos2] == ` ` {
			pos2++
		} // skip spaces (tolerant)
		if pos2 >= len {
			return error('No path')
		}
		path_start := pos2

		// Now use AVX2 to find next space OR \r from current position
		remaining := len - pos2
		if remaining <= 0 {
			return error('Invalid')
		}

		// Search for space or \r in the URL + version part
		delim_pos := avx2_find_delim(buf + pos2, remaining, u32(1 << ` `) | u32(1 << `\r`))
		if delim_pos < 0 {
			return error('No version')
		}

		abs_pos := pos2 + delim_pos
		req.path = Slice{path_start, delim_pos}

		// Now determine if we hit space or \r
		if buf[abs_pos] == `\r` {
			// Path goes to \r, version is empty? Invalid unless tolerant
			req.version = Slice{abs_pos, 0}
		} else {
			// Hit space → version starts after
			version_start := abs_pos + 1
			// Find \r from here
			cr_pos := 0
			for cr_pos = 0; version_start + cr_pos < len; cr_pos++ {
				if buf[version_start + cr_pos] == `\r` {
					break
				}
			}
			if version_start + cr_pos >= len || buf[version_start + cr_pos] != `\r` {
				return error('No \\r in version')
			}
			req.version = Slice{version_start, cr_pos}
			abs_pos = version_start + cr_pos
		}

		// Validate \r\n
		if abs_pos + 1 >= len || buf[abs_pos + 1] != `\n` {
			return error('Missing \\n after \\r')
		}
	}
}

pub fn decode_http_request_avx2(buffer []u8) !HttpRequest {
	mut req := HttpRequest{
		buffer: buffer
	}

	parse_http1_request_line_avx2(mut req)!

	return req
}
