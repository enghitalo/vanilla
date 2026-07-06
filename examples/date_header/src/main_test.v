module main

// The cache logic is pure/in-memory, so the format, the publish, and the response
// composition are all unit-testable without a clock-dependent assertion on the
// exact value. seed() must run before refresh() (it lays the static "Date: " /
// CRLF frame that write_http_header does not touch), exactly as main() does.

fn test_refresh_produces_valid_date_line() {
	mut c := DateCache{}
	c.seed()
	c.refresh()
	line := c.date_line().bytestr()
	assert line.starts_with('Date: ')
	assert line.ends_with(' GMT\r\n')
	assert line.len == date_line_len // fixed-width IMF-fixdate line
}

fn test_double_buffer_flips() {
	mut c := DateCache{}
	c.seed()
	c.refresh()
	first := c.idx
	c.refresh()
	assert c.idx == 1 - first // publishes to the other buffer each time
}

fn test_response_includes_date_header() {
	mut c := DateCache{}
	c.seed()
	c.refresh()
	// Reproduce exactly what the request_handler closure writes into `out`:
	// the two static halves plus the cached, zero-copy Date line.
	mut out := []u8{}
	out << status_head
	out << c.date_line()
	out << resp_tail
	resp := out.bytestr()
	assert resp.contains('HTTP/1.1 200 OK\r\n')
	assert resp.contains('Date: ')
	assert resp.contains(' GMT\r\n')
	assert resp.contains('Content-Length: 2\r\n')
}
