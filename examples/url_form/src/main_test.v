module main

// SOLUTION: pure decoder / table test — works today.
// Percent-decoding is the kind of byte transformation that benefits most from
// table-driven tests, including the SECURITY case: decode exactly once.

fn test_percent_decode() {
	assert percent_decode('hello%20world') == 'hello world'
	assert percent_decode('c%2B%2B') == 'c++'
	assert percent_decode('a+b') == 'a b' // '+' is space in form/query encoding
	assert percent_decode('plain') == 'plain'
}

fn test_decode_exactly_once() {
	// %2527 -> %27 (NOT all the way to a single quote). Double-decoding is a
	// classic filter bypass; decoding once is the correct, safe behavior.
	assert percent_decode('%2527') == '%27'
}

fn test_malformed_escape_is_literal() {
	assert percent_decode('100%') == '100%' // dangling % left as-is
	assert percent_decode('%zz') == '%zz' // non-hex left as-is
}

fn test_parse_form() {
	m := parse_form('q=hello%20world&tag=c%2B%2B&empty=')
	assert m['q'] == 'hello world'
	assert m['tag'] == 'c++'
	assert m['empty'] == ''
}
