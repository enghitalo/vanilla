// vtest build: linux
module upstream

// The Resolver's scheduling of its lookups (#366), through pools whose
// failing exchanges ask, without a server (transport/resolver_test.v tests the
// Resolver itself).
//
// Two pools follow one Resolver: A first, then B. A's DNS is down: each
// lookup takes a_delay ms, then answers nothing, and the address A booted with
// no longer answers. B is healthy and has moved: its lookup answers the new
// address at once. Until #366 the Resolver looked the followed origins up one
// after another, on its one thread, and any pool's ask woke a refresh of every
// origin.
import core
import time
import sync.stdatomic
import transport

// Lookup is one origin's ResolveFn. Its first call (Pool.new, on the test
// thread) answers `boot`. Every later call (the Resolver's) notes when it
// started, waits delay_ms, then answers `answer`.
@[heap]
struct Lookup {
mut:
	boot     transport.Addr
	answer   []transport.Addr
	delay_ms i64
	calls    i64     // atomic; the Resolver looks an origin up once at a time
	at       [64]i64 // monotonic ns each call started
}

fn (l &Lookup) resolve_fn() ResolveFn {
	return fn [l] (host string, port int) []transport.Addr {
		n := int(stdatomic.load_i64(&l.calls))
		if n < l.at.len {
			stdatomic.store_i64(&l.at[n], i64(time.sys_mono_now()))
		}
		stdatomic.add_i64(&l.calls, 1)
		if n == 0 {
			return [l.boot]
		}
		if l.delay_ms > 0 {
			time.sleep(time.Duration(l.delay_ms) * time.millisecond)
		}
		return l.answer.clone()
	}
}

// lookups is how many times the Resolver looked the origin up (Pool.new's
// lookup aside).
fn (l &Lookup) lookups() int {
	return int(stdatomic.load_i64(&l.calls)) - 1
}

// started is when each of those lookups started (the first 63).
fn (l &Lookup) started() []i64 {
	n := int(stdatomic.load_i64(&l.calls))
	mut out := []i64{}
	for i in 1 .. n {
		if i < l.at.len {
			out << stdatomic.load_i64(&l.at[i])
		}
	}
	return out
}

struct Setup {
mut:
	r  &Resolver
	pa &Pool
	pb &Pool
	la &Lookup
	lb &Lookup
}

fn named_pool(host string, resolve ResolveFn) &Pool {
	return Pool.new(Origin{
		host:    host
		port:    80
		https:   false
		resolve: resolve
	}, unsafe { nil }) or { panic(err) }
}

fn setup(interval_ms int, a_delay_ms i64) Setup {
	// Multicast: connect() fails at once (ENETUNREACH), so an exchange fails
	// without parking, as once every address refused.
	dead_a := transport.ip_addr('224.0.0.1', 80) or { panic('addr') }
	dead_b := transport.ip_addr('224.0.0.2', 80) or { panic('addr') }
	moved_b := transport.ip_addr('127.0.0.1', 8080) or { panic('addr') }
	la := &Lookup{
		boot:     dead_a
		delay_ms: a_delay_ms // then answers nothing: A's DNS is down
	}
	lb := &Lookup{
		boot:   dead_b
		answer: [moved_b] // B moved: its DNS answers the new address at once
	}
	mut pa := named_pool('a.test', la.resolve_fn())
	mut pb := named_pool('b.test', lb.resolve_fn())
	mut r := Resolver.new(interval_ms) or { panic(err) }
	pa.follow(mut r) or { panic(err) }
	pb.follow(mut r) or { panic(err) }
	r.start()
	return Setup{
		r:  r
		pa: pa
		pb: pb
		la: la
		lb: lb
	}
}

fn note_watch(mut el core.EventLoop, fd int, _ core.WatchInterest, _ core.WakeFn, _ voidptr) {
	el.last_watched = fd
}

fn not_woken(mut _ []u8, _ int, _ bool, _ voidptr, _ voidptr, mut _ core.EventLoop) core.Step {
	return .done
}

// fail_once runs one exchange on a pool none of whose addresses answers:
// dial() runs out of addresses, asks the resolver for a refresh
// (request_resolve), and the exchange fails with .connect.
fn fail_once(mut p Pool) {
	mut el := core.EventLoop{
		register: note_watch
	}
	mut x := p.acquire() or { panic('slot') }
	ok := x.request('GET', '/v1/charges')
	assert ok
	r := x.send(mut el, not_woken, unsafe { nil })
	assert r == .failed
	assert x.failure() == .connect
	x.release()
}

// take_feed takes the resolver's records into the pool, as on_feed does.
fn take_feed(mut p Pool) {
	if p.feed.take(mut p.addrs) {
		p.cursor = 0
	}
}

fn port_of(a transport.Addr) int {
	return int(a.data[2]) << 8 | int(a.data[3])
}

fn ms_of(ns i64) i64 {
	return ns / 1_000_000
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

// An asked refresh (problem 1): A's pool asked, and A's lookup is in flight
// when B's exchange fails and asks. B's new address must not wait for A's
// lookup. (Before #366 it came once A's lookup ended.)
fn test_asked_refresh_does_not_wait_for_another_origins_lookup() {
	mut waits := []i64{}
	for a_delay in [i64(0), 1000] {
		mut s := setup(30_000, a_delay)
		fail_once(mut s.pa) // A asks: its lookup takes a_delay ms
		assert wait_for(&s.la.calls, 2, 2000), "A's lookup did not start"
		t0 := i64(time.sys_mono_now())
		fail_once(mut s.pb)
		ready := C.transport_wait(s.pb.feed.fd, 5000)
		t1 := i64(time.sys_mono_now())
		assert ready > 0
		take_feed(mut s.pb)
		assert s.pb.addrs.len == 1 && port_of(s.pb.addrs[0]) == 8080
		eprintln("A's lookup takes ${a_delay} ms and has started: B's pool asked for a refresh, and its new address reached it ${ms_of(t1 - t0)} ms later")
		waits << ms_of(t1 - t0)
		s.r.stop()
	}
	assert waits[1] < 300, 'B waited for A'
}

// Periodic refreshes (problem 1): with interval_ms 1000 and no ask, B is due
// a lookup every second, whatever A's lookups take. (Before #366, B was looked
// up after A, every 1.7 s.)
fn test_periodic_refresh_does_not_wait_for_another_origins_lookup() {
	mut counts := []int{}
	for a_delay in [i64(0), 700] {
		mut s := setup(1000, a_delay)
		t0 := i64(time.sys_mono_now())
		time.sleep(3500 * time.millisecond)
		mut at := []string{}
		for t in s.lb.started() {
			at << '${f64(t - t0) / 1e9:.2f} s'
		}
		eprintln("interval_ms 1000, A's lookup takes ${a_delay} ms: in 3.5 s B was looked up ${s.lb.lookups()} times, at ${at.join(', ')}")
		counts << s.lb.lookups()
		s.r.stop()
	}
	assert counts[1] == counts[0], 'B was looked up less often'
}

// Asks (problem 2): A's pool fails every exchange and each failure asks. B's
// pool never asks, and its interval (30 s) does not come due within the 2 s
// window, so B needs no lookup in it. A is looked up once per refresh gap at
// most. (Before #366, each refresh A asked for looked B up too.)
fn test_another_pools_asks_do_not_reresolve_every_origin() {
	mut counts := []int{}
	for a_delay in [i64(0), 1000] {
		mut s := setup(30_000, a_delay)
		sw := time.new_stopwatch()
		mut failed := 0
		for sw.elapsed() < 2 * time.second {
			fail_once(mut s.pa)
			failed++
			time.sleep(10 * time.millisecond)
		}
		eprintln("A's lookup takes ${a_delay} ms: A's pool failed ${failed} exchanges in 2 s, each asking; A was looked up ${s.la.lookups()} times, B ${s.lb.lookups()} times")
		counts << s.lb.lookups()
		// The first ask at once, then one gap (1 s) after each lookup ends.
		assert s.la.lookups() >= 1 && s.la.lookups() <= 3, 'A: ${s.la.lookups()} lookups'
		s.r.stop()
	}
	assert counts == [0, 0], "A's asks re-resolved B"
}
