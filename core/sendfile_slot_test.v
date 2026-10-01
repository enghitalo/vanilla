module core

// The sendfile hand-off slot's two gates (sendfile_slot.h): `enabled`, set
// once per capable worker, and the per-request `allowed`. The slot is
// thread-local, so each probe runs on a thread of its own, whose slot starts
// zeroed with both gates closed, and acts as the worker there. The probes
// only record what they saw; the asserts run on the test thread. Under tcc the
// slot is compiled inert and every queue reports "not taken".

fn sf_slot_holds_a_region() bool {
	if _ := take_queued_file() {
		return true
	}
	return false
}

struct SfEnableProbe {
	queued_before_enable bool
	held_before_enable   bool
	queued_after_enable  bool
	taken                bool
	region               QueuedFile
	held_after_take      bool
}

// sf_probe_enable_on_a_fresh_slot never calls set_queue_file_allowed, like the
// plain epoll worker around its handler calls: queue_file can only succeed
// after enable_sendfile if enable opened the per-request gate as well.
fn sf_probe_enable_on_a_fresh_slot() SfEnableProbe {
	queued_before := queue_file(3, 0, 10)
	held_before := sf_slot_holds_a_region()
	enable_sendfile()
	queued_after := queue_file(3, 7, 10)
	mut taken := false
	mut region := QueuedFile{
		file_fd: -1
	}
	if qf := take_queued_file() {
		taken = true
		region = qf
	}
	return SfEnableProbe{
		queued_before_enable: queued_before
		held_before_enable:   held_before
		queued_after_enable:  queued_after
		taken:                taken
		region:               region
		held_after_take:      sf_slot_holds_a_region()
	}
}

// sf_probe_allowed_without_enable opens only the per-request gate: a worker
// that never enabled sendfile still takes nothing. Reports whether anything
// was queued or left in the slot.
fn sf_probe_allowed_without_enable() bool {
	set_queue_file_allowed(true)
	return queue_file(3, 0, 10) || sf_slot_holds_a_region()
}

struct SfGateProbe {
	queued_when_closed bool
	held_when_closed   bool
	queued_when_open   bool
	taken_fd           int
}

// sf_probe_per_request_gate enables sendfile, then closes and reopens the
// per-request gate as a TLS worker does between connections.
fn sf_probe_per_request_gate() SfGateProbe {
	enable_sendfile()
	// Closed for this request (a userspace-TLS connection): the caller must
	// write the bytes itself, and nothing is left queued.
	set_queue_file_allowed(false)
	queued_closed := queue_file(4, 0, 10)
	held_closed := sf_slot_holds_a_region()
	// Open again for the next request.
	set_queue_file_allowed(true)
	queued_open := queue_file(5, 0, 1)
	mut taken_fd := -1
	if qf := take_queued_file() {
		taken_fd = qf.file_fd
	}
	return SfGateProbe{
		queued_when_closed: queued_closed
		held_when_closed:   held_closed
		queued_when_open:   queued_open
		taken_fd:           taken_fd
	}
}

fn test_enable_sendfile_opens_both_gates_on_a_fresh_slot() {
	t := spawn sf_probe_enable_on_a_fresh_slot()
	p := t.wait()
	// Before enable_sendfile nothing is taken.
	assert !p.queued_before_enable
	assert !p.held_before_enable
	$if tinyc {
		assert !p.queued_after_enable
		assert !p.taken
	} $else {
		// The per-request gate was never touched, so this proves that
		// enable_sendfile opened it: a worker that never calls
		// set_queue_file_allowed keeps every request allowed.
		assert p.queued_after_enable
		assert p.taken
		assert p.region.file_fd == 3
		assert p.region.off == 7
		assert p.region.len == 10
	}
	assert !p.held_after_take // taking clears the slot
}

fn test_per_request_gate_alone_takes_nothing() {
	t := spawn sf_probe_allowed_without_enable()
	assert !t.wait()
}

fn test_queue_file_follows_the_per_request_gate() {
	t := spawn sf_probe_per_request_gate()
	p := t.wait()
	assert !p.queued_when_closed
	assert !p.held_when_closed
	$if tinyc {
		assert !p.queued_when_open
		assert p.taken_fd == -1
	} $else {
		assert p.queued_when_open
		assert p.taken_fd == 5
	}
}
