module main

// SOLUTION: pure logic test — works today.
// The dangerous and fiddly parts of a static server (Range math, MIME, and
// above all path-traversal safety) are pure and must be tested in isolation.

fn test_parse_range() {
	if s, e := parse_range('bytes=0-99', 1000) {
		assert s == 0 && e == 99
	} else {
		assert false
	}
	if s, e := parse_range('bytes=500-', 1000) {
		assert s == 500 && e == 999 // open-ended -> to last byte
	} else {
		assert false
	}
	if s, e := parse_range('bytes=-100', 1000) {
		assert s == 900 && e == 999 // suffix range -> last 100 bytes
	} else {
		assert false
	}
}

fn test_parse_range_rejects_bad_input() {
	if _, _ := parse_range('bytes=900-100', 1000) { // start > end
		assert false
	} else {
		assert true
	}
	if _, _ := parse_range('items=0-9', 1000) { // wrong unit
		assert false
	} else {
		assert true
	}
}

fn test_mime_type() {
	assert mime_type('index.html').contains('text/html')
	assert mime_type('app.js') == 'application/javascript'
	assert mime_type('pic.png') == 'image/png'
	assert mime_type('blob.bin') == 'application/octet-stream'
}

// THE most important test in a static server.
fn test_path_traversal_refused() {
	assert safe_path('/../../etc/passwd') == none
	assert safe_path('/../../../root/.ssh/id_rsa') == none
	// a normal path resolves to something inside the root
	p := safe_path('/index.html') or { '' }
	assert p != ''
}
