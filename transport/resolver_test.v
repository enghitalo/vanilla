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
	mut n := r.subs[0].name
	n.found[0] = a
	n.count = 1
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
		r.write_update(wfd, n)
		if f.take(mut table) {
			swapped++
		}
	}
	growth := heap_bytes() - heap0
	assert swapped == 1000
	assert growth < 1024, 'the heap grew ${growth} bytes over 1000 resolver updates'
}

// Nor does a refresh, on the resolver's side: under -gc none, a follower of
// 127.0.0.1 through the system resolver (getaddrinfo frees what it
// allocates), due every millisecond, is refreshed hundreds of times in a
// second, and the heap stays as it was once the first refreshes ran (the
// lookup thread's spawn, getaddrinfo's first call).
fn test_refreshes_allocate_nothing() {
	$if gcboehm ? {
		return
	}
	$if race ? {
		return
	}
	mut r := Resolver.new(1) or { panic(err) }
	mut f := r.follow('127.0.0.1', 80, unsafe { nil }) or { panic(err) }
	r.start()
	mut table := []Addr{cap: max_addrs}
	mut updates := 0
	mut heap0 := i64(-1)
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 1200 {
		if heap0 < 0 && sw.elapsed().milliseconds() >= 200 {
			heap0 = heap_bytes()
			updates = 0
		}
		if C.transport_wait(f.fd, 10) > 0 && f.take(mut table) {
			updates++
		}
	}
	growth := heap_bytes() - heap0
	r.stop()
	C.close(f.fd)
	C.close(r.wake_r)
	C.close(r.wake_w)
	if heap0 <= 0 {
		return
	}
	eprintln('${updates} refreshes in a second: the heap grew ${growth} bytes')
	assert updates > 100, 'only ${updates} refreshes in a second'
	assert growth < 4096, 'the heap grew ${growth} bytes over ${updates} refreshes'
}

// Gate holds the Resolver's lookups of a host until the test opens it, or for
// 5 s (until #366, stop() waited for the lookup in flight).
@[heap]
struct Gate {
mut:
	answer  Addr
	entered i64 // atomic: lookups that reached the gate
	left    i64 // atomic: lookups that got past it
	open    i64 // atomic
}

fn new_gate() &Gate {
	return &Gate{
		answer: ip_addr('127.0.0.1', 2222) or { panic('addr') }
	}
}

fn (g &Gate) resolve_fn() ResolveFn {
	return fn [g] (host string, port int) []Addr {
		stdatomic.add_i64(&g.entered, 1)
		sw := time.new_stopwatch()
		for stdatomic.load_i64(&g.open) == 0 && sw.elapsed() < 5 * time.second {
			time.sleep(time.millisecond)
		}
		stdatomic.add_i64(&g.left, 1)
		return [g.answer]
	}
}

// wait_for waits up to ms for *counter to reach n.
fn wait_for(counter &i64, n i64, ms i64) bool {
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < ms {
		if stdatomic.load_i64(counter) >= n {
			return true
		}
		time.sleep(time.millisecond)
	}
	return stdatomic.load_i64(counter) >= n
}

// answered waits for the feed's first update, and reports whether it carries
// the gate's answer.
fn answered(mut f Feed) bool {
	if C.transport_wait(f.fd, 2000) <= 0 {
		return false
	}
	mut table := []Addr{cap: max_addrs}
	return f.take(mut table) && table.len == 1 && port_of(table[0]) == 2222
}

// The followers of one host:port (in a server, one per worker) share each
// lookup of it: both ask before the Resolver starts, the host is looked up
// once, and both get the answer. A host nobody asked for is not looked up.
// (Before #366, an ask looked every followed host up.)
fn test_followers_of_one_host_share_a_lookup() {
	mut g := new_gate()
	stdatomic.store_i64(&g.open, 1)
	mut other := new_gate()
	mut r := Resolver.new(60_000) or { panic(err) }
	mut fa := r.follow('svc.test', 80, g.resolve_fn()) or { panic(err) }
	mut fb := r.follow('svc.test', 80, g.resolve_fn()) or { panic(err) }
	fc := r.follow('other.test', 80, other.resolve_fn()) or { panic(err) }
	fa.ask()
	fb.ask()
	r.start()
	assert answered(mut fa)
	assert answered(mut fb)
	time.sleep(50 * time.millisecond)
	assert stdatomic.load_i64(&g.entered) == 1, 'svc.test looked up ${stdatomic.load_i64(&g.entered)} times'
	assert stdatomic.load_i64(&other.entered) == 0, 'other.test looked up, unasked'
	r.stop()
	C.close(fa.fd)
	C.close(fb.fd)
	C.close(fc.fd)
}

// A follower that unfollows while its host's lookup is in flight: the
// resolver thread, its pipe's only writer, closes the pipe once the lookup
// ends and writes it nothing, while the host's other follower gets the
// answer. (Before #366 the refresh wrote the answer to both, and closed the
// pipe at the next refresh.)
fn test_unfollowed_during_its_lookup_gets_nothing() {
	mut g := new_gate()
	mut r := Resolver.new(60_000) or { panic(err) }
	mut fa := r.follow('svc.test', 80, g.resolve_fn()) or { panic(err) }
	mut fb := r.follow('svc.test', 80, g.resolve_fn()) or { panic(err) }
	r.start()
	fa.ask()
	assert wait_for(&g.entered, 1, 2000) // the lookup is in flight
	fa.unfollow()
	stdatomic.store_i64(&g.open, 1)
	assert answered(mut fb)
	// fa's pipe: closed by its writer (the read end sees EOF), and empty.
	mut rec := Record{}
	assert C.transport_wait(fa.fd, 2000) > 0
	n := C.read(fa.fd, &rec, sizeof(Record))
	assert n == 0, 'the follower that left got ${n} bytes'
	r.stop()
	C.close(fa.fd)
	C.close(fb.fd)
}

// stop() returns at once although a lookup is blocked (in getaddrinfo, or a
// ResolveFn that never returns): it closes the followers' pipes, and the
// lookup thread, once its call returns, writes nothing. (Until #366 stop()
// joined the thread blocked in the lookup, for good if it never returned.)
fn test_stop_does_not_wait_for_a_blocked_lookup() {
	mut g := new_gate()
	mut r := Resolver.new(60_000) or { panic(err) }
	f := r.follow('svc.test', 80, g.resolve_fn()) or { panic(err) }
	r.start()
	f.ask()
	assert wait_for(&g.entered, 1, 2000) // the lookup is blocked
	sw := time.new_stopwatch()
	r.stop()
	took := sw.elapsed().milliseconds()
	eprintln('stop() took ${took} ms with a lookup blocked')
	assert took < 100, 'stop() waited for the lookup'
	// The follower's pipe is closed (EOF), and empty.
	mut rec := Record{}
	assert C.transport_wait(f.fd, 1000) > 0
	assert C.read(f.fd, &rec, sizeof(Record)) == 0
	// The lookup returns: its thread drops the answer and writes nothing, not
	// even to the wake pipe.
	mut b := [64]u8{}
	for C.read(r.wake_r, &b[0], usize(b.len)) > 0 {
	}
	stdatomic.store_i64(&g.open, 1)
	assert wait_for(&g.left, 1, 2000)
	time.sleep(20 * time.millisecond)
	assert C.read(r.wake_r, &b[0], usize(b.len)) < 0
	C.close(f.fd)
	C.close(r.wake_r)
	C.close(r.wake_w)
}

// stop() right after an ask returns at once (#368): the old loop checked
// stop_flag before it drained the wake pipe, so a stop() that landed between
// the two lost its byte to the drain and waited out interval_ms. 500 rounds
// of: start, one ask, a spin of 0-60 us, stop().
fn test_stop_right_after_an_ask_returns_at_once() {
	interval := 1000
	addr := ip_addr('127.0.0.1', 1111) or { panic('addr') }
	resolve := fn [addr] (host string, port int) []Addr {
		return [addr]
	}
	mut slow := 0
	mut worst := i64(0)
	for _ in 0 .. 500 {
		mut r := Resolver.new(interval) or { panic(err) }
		f := r.follow('svc.test', 80, resolve) or { panic(err) }
		r.start()
		time.sleep(time.millisecond) // the thread is in its wait
		spin := time.sys_mono_now() % 60_000
		f.ask()
		t0 := time.sys_mono_now()
		for time.sys_mono_now() - t0 < spin {
		}
		sw := time.new_stopwatch()
		r.stop()
		us := sw.elapsed().microseconds()
		if us > worst {
			worst = us
		}
		if us >= i64(interval) * 1000 / 2 {
			slow++
		}
		// No thread of the resolver writes once stop() returned.
		C.close(f.fd)
		C.close(r.wake_r)
		C.close(r.wake_w)
	}
	eprintln('${slow} of 500 stops waited out interval_ms (${interval} ms); worst ${worst} us')
	assert slow == 0
}
