module core

// The sendfile hand-off slot's two gates (sendfile_slot.h): `enabled`, set
// once per capable worker, and the per-request `allowed`. The slot is
// thread-local, so this test thread acts as the worker. Under tcc the slot is
// compiled inert and every queue reports "not taken".

fn sf_slot_holds_a_region() bool {
	if _ := take_queued_file() {
		return true
	}
	return false
}

fn test_queue_file_needs_enable_then_follows_the_per_request_gate() {
	// Before enable_sendfile nothing is taken, whatever the gate says.
	set_queue_file_allowed(true)
	assert !queue_file(3, 0, 10)
	assert !sf_slot_holds_a_region()

	enable_sendfile()
	$if tinyc {
		assert !queue_file(3, 0, 10)
		assert !sf_slot_holds_a_region()
	} $else {
		// enable_sendfile opens the per-request gate too: a worker that never
		// calls set_queue_file_allowed keeps every request allowed.
		assert queue_file(3, 7, 10)
		qf := take_queued_file() or { panic('a queued region must be taken') }
		assert qf.file_fd == 3
		assert qf.off == 7
		assert qf.len == 10
		assert !sf_slot_holds_a_region() // taking clears the slot

		// Closed for this request (a userspace-TLS connection): the caller
		// must write the bytes itself, and nothing is left queued.
		set_queue_file_allowed(false)
		assert !queue_file(4, 0, 10)
		assert !sf_slot_holds_a_region()

		// Open again for the next request.
		set_queue_file_allowed(true)
		assert queue_file(5, 0, 1)
		again := take_queued_file() or { panic('a queued region must be taken') }
		assert again.file_fd == 5
	}
}
