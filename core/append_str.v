module core

// append_str appends the bytes of `s` to `out`, without allocating and without a
// call on the common path. It is the way to write a static response:
//
//   const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
//   core.append_str(mut out, resp_ok)
//
// `out << arr` and `push_many` always call the generic array push. Inlined, this
// is a capacity check plus a memcpy, and for a const string gcc knows the bytes
// and the length, so the copy becomes a few fixed-size moves (2.5 ns vs 4.7 ns
// for a 102-byte response; docs/V_PERF_TOOLBOX.md, "Appending a static
// response"). Growing `out`, or appending to a slice view, takes the builtin
// path, so the result is always the same as `push_many`'s.
@[inline]
pub fn append_str(mut out []u8, s string) {
	if s.len == 0 {
		return // an empty `out` has no buffer to memcpy into
	}
	if out.len + s.len > out.cap || out.flags.has(.is_slice) {
		append_str_slow(mut out, s)
		return
	}
	unsafe {
		vmemcpy(&u8(out.data) + out.len, s.str, s.len)
		out.len += s.len
	}
}

// append_str_slow is append_str's uncommon case, kept out of line so the
// inlined fast path stays small: push_many grows `out`, or copies a slice view
// before writing to it.
@[noinline]
fn append_str_slow(mut out []u8, s string) {
	unsafe { out.push_many(s.str, s.len) }
}
