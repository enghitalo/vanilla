module core

const resp = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'

fn test_append_str_appends_after_existing_bytes() {
	mut out := []u8{cap: 64}
	out << 'x'.bytes()
	append_str(mut out, resp)
	assert out.bytestr() == 'x' + resp
	assert out.cap == 64
}

fn test_append_str_grows_out() {
	mut out := []u8{cap: 4}
	append_str(mut out, resp)
	append_str(mut out, resp)
	assert out.bytestr() == resp + resp
}

fn test_append_str_empty_string_appends_nothing() {
	mut out := []u8{cap: 8}
	append_str(mut out, '')
	assert out.len == 0
	mut empty := []u8{}
	append_str(mut empty, '')
	assert empty.len == 0
}

fn test_append_str_never_writes_into_the_parent_of_a_slice() {
	mut parent := []u8{len: 8, cap: 16, init: `a`}
	// a slice view truncated below its cap: an in-place write would land in parent[2]
	mut view := unsafe { parent[..4] }
	unsafe {
		view.len = 2
	}
	assert view.flags.has(.is_slice)
	assert view.cap > view.len
	append_str(mut view, 'z')
	assert view.bytestr() == 'aaz'
	assert parent.bytestr() == 'aaaaaaaa'
}
