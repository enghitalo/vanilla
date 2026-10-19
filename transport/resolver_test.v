// vtest build: !windows
module transport

// The Resolver's hand-off to its followers (moved here from
// http1_1/upstream's tests with the Resolver, #351): the records, the
// thread, and the allocation check. http1_1/upstream and pg_async test their
// own pools following it.
import sync.stdatomic
import time

fn make_record(seq u32, idx int, count int, a Addr) Record {
	return Record{
		seq:    seq
		idx:    u16(idx)
		count:  u16(count)
		family: i32(a.family)
		len:    a.len
		data:   a.data
	}
}

fn (mut f Feed) give(r Record, mut table []Addr) bool {
	f.rec = r
	return f.take_record(mut table)
}

// The resolver's records swap a follower's address table only once a whole
// update has arrived in order; a broken update is dropped.
fn test_records_swap_the_table() {
	a0 := ip_addr('127.0.0.1', 80) or { panic('a0') }
	a1 := ip_addr('10.0.0.1', 80) or { panic('a1') }
	a2 := ip_addr('::1', 80) or { panic('a2') }
	mut table := []Addr{cap: max_addrs}
	table << a0
	mut f := Feed{
		staging: []Addr{cap: max_addrs}
	}
	assert !f.give(make_record(1, 0, 2, a1), mut table)
	assert table.len == 1 // not yet
	assert f.give(make_record(1, 1, 2, a2), mut table)
	assert table.len == 2
	assert table[0].data == a1.data && table[1].family == a2.family
	// Out of order (a record lost on a full pipe): the update is dropped.
	assert !f.give(make_record(2, 0, 3, a2), mut table)
	assert !f.give(make_record(2, 2, 3, a2), mut table)
	assert !f.give(make_record(3, 1, 1, a1), mut table)
	assert table.len == 2 && table[0].data == a1.data
	// A whole update replaces it.
	assert f.give(make_record(4, 0, 1, a2), mut table)
	assert table.len == 1 && table[0].family == a2.family
}

// Port is the test resolver's answer, read on the resolver thread.
@[heap]
struct Port {
mut:
	n i64
}

fn port_of(a Addr) int {
	return int(a.data[2]) << 8 | int(a.data[3])
}

// The resolver thread hands updates to a follower through its pipe, and an
// ask brings a refresh at once even with a long interval.
fn test_thread_hands_off() {
	mut port := &Port{
		n: 1111
	}
	pp := port
	resolve := fn [pp] (host string, port int) []Addr {
		a := ip_addr('127.0.0.1', int(stdatomic.load_i64(&pp.n))) or { return [] }
		return [a]
	}
	mut r := Resolver.new(60_000) or { panic(err) }
	mut f := r.follow('svc.test', 80, resolve) or { panic(err) }
	assert f.followed()
	r.start()
	defer {
		r.stop()
		C.close(f.fd)
	}
	stdatomic.store_i64(&port.n, 2222)
	f.ask()
	mut table := []Addr{cap: max_addrs}
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 2000 {
		if C.transport_wait(f.fd, 100) > 0 && f.take(mut table) {
			break
		}
	}
	assert table.len == 1 && port_of(table[0]) == 2222
}

#include <malloc.h>

struct C.mallinfo2 {
	uordblks usize
	hblkhd   usize
}

fn C.mallinfo2() C.mallinfo2

fn heap_bytes() i64 {
	mi := C.mallinfo2()
	return i64(mi.uordblks) + i64(mi.hblkhd)
}

// A resolver update allocates nothing on either side: under -gc none (nothing
// is ever freed) 1000 updates written by write_update and taken by Feed.take
// leave the heap as it was.
fn test_feed_allocates_nothing() {
	$if gcboehm ? {
		return
	}
	$if race ? {
		return
	}
	a := ip_addr('127.0.0.1', 80) or { panic('addr') }
	mut r := Resolver.new(60_000) or { panic(err) } // never started: the test writes
	mut f := r.follow('127.0.0.1', 80, unsafe { nil }) or { panic(err) }
	r.found << a
	wfd := r.subs[0].fd
	defer {
		for fd in [f.fd, wfd, r.wake_r, r.wake_w] {
			C.close(fd)
		}
	}
	mut table := []Addr{cap: max_addrs}
	heap0 := heap_bytes()
	if heap0 == 0 {
		return
	}
	mut swapped := 0
	for _ in 0 .. 1000 {
		r.seq++
		r.write_update(wfd)
		if f.take(mut table) {
			swapped++
		}
	}
	growth := heap_bytes() - heap0
	assert swapped == 1000
	assert growth < 1024, 'the heap grew ${growth} bytes over 1000 resolver updates'
}
