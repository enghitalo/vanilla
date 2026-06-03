module main

// The cache logic is pure/in-memory, so the format, the publish, and the handler
// injection are all unit-testable without a clock-dependent assertion on the
// exact value.

fn test_refresh_produces_valid_date_line() {
	mut c := DateCache{}
	c.refresh()
	line := c.date_line().bytestr()
	assert line.starts_with('Date: ')
	assert line.ends_with(' GMT\r\n')
	assert line.len == date_line_len // fixed-width IMF-fixdate line
}

fn test_double_buffer_flips() {
	mut c := DateCache{}
	c.refresh()
	first := c.idx
	c.refresh()
	assert c.idx == 1 - first // publishes to the other buffer each time
}

fn test_handler_includes_date_header() ! {
	mut c := DateCache{}
	c.refresh()
	out := handle('GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes(), -1, c)!.bytestr()
	assert out.contains('HTTP/1.1 200 OK\r\n')
	assert out.contains('Date: ')
	assert out.contains(' GMT\r\n')
	assert out.contains('Content-Length: 2\r\n')
}
