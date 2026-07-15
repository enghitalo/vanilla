// vtest build: linux
module http_server

// Unit test for the io_uring multishot-accept kernel gate. It stays in-module
// (unlike the backend's socket tests) because iou_release_supports_multishot
// is module-internal and the test needs no sockets at all.
//
// The end-to-end socket tests that used to live here (keep-alive 200 → 404
// routing, 4-pipelined-requests-in-one-write) moved to
// tests/io_uring_backend_test.v, on vtest.

// Guards the multishot-accept gate: the previous code keyed off a non-existent
// params.features bit (1 << 19), which is never set, so multishot was silently
// disabled on every kernel. Detection now keys off the kernel release.
fn test_iou_release_supports_multishot() {
	$if !linux {
		return
	}
	$if linux {
		// >= 5.19 → supported
		assert iou_release_supports_multishot('5.19.0-generic')
		assert iou_release_supports_multishot('6.8.0-41-generic')
		assert iou_release_supports_multishot('6.0.0')
		assert iou_release_supports_multishot('10.2.1-custom')
		// < 5.19 → single-shot fallback
		assert !iou_release_supports_multishot('5.18.0-generic')
		assert !iou_release_supports_multishot('5.4.0-200-generic')
		assert !iou_release_supports_multishot('4.19.255')
		// Malformed / unparseable → safe default (no multishot)
		assert !iou_release_supports_multishot('garbage')
		assert !iou_release_supports_multishot('6')
		assert !iou_release_supports_multishot('')
	}
}
