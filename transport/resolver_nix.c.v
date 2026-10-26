module transport

import sync
import sync.stdatomic
import time

// Name resolution off the workers (#229; moved here from http1_1.upstream so
// pg_async can follow it too, #351). getaddrinfo blocks for as long as the
// DNS takes (seconds when it drops queries) and allocates, so a worker must
// never call it. A follower resolves its host once, at startup (blocking:
// make_state runs before the worker serves). A Resolver keeps the addresses
// fresh afterwards: it re-resolves each followed host every interval_ms
// (getaddrinfo gives no TTL), and sooner when one of the host's followers asks
// (Feed.ask: a dial failed, on every address an exchange tried or on a
// re-dial's address, or it has none), at once or refresh_gap_ms after the
// host's last lookup, then hands the answer to each follower of the host over
// that follower's own pipe. A worker never resolves, never waits and takes no
// lock on the request path: the pipe carries fixed-size address records (one
// write each, under PIPE_BUF, so atomic), the worker copies them into its own
// table on its own thread (Feed.take), and an ask sets an atomic flag (and
// writes one wake byte when it sets it). One Resolver can serve every
// follower in the process: http1_1.upstream's pools and pg_async's.
//
// Each host is looked up on its own, on one of max_lookups lookup threads
// (spawned by start()), so a slow lookup (a host whose DNS drops queries holds
// getaddrinfo for 10 to 30 s) delays only that host, and an ask refreshes only
// the host it names (#366). The followers of one host:port share each lookup
// of it. The resolver thread only schedules: it hands the lookups out (in turn
// while every lookup thread is busy), and writes each answer to the pipes,
// whose only writer it is.
//
//   resolver := transport.Resolver.new(30_000)!   // before new_server
//   resolver.start()
//   // make_state: upstream:  pay.follow(mut resolver)!
//   //             pg_async:  pool.follow(mut resolver)!
//   // (each calls resolver.follow(host, port, resolve) and keeps the Feed)
//
// Connections already open keep their address until they are re-dialed (a
// lifetime cap, a loss); new dials use the new table.

// max_addrs bounds the addresses a follower's table keeps (a resolver
// answer's tail is dropped).
pub const max_addrs = 16

// ResolveFn resolves host:port to the addresses to dial, in order: empty when
// it cannot. It runs at startup (each follower's first lookup, in its
// worker's make_state) and on a Resolver's lookup threads, so it may block and
// allocate, and it may run on several threads at once: the Resolver looks
// different host:ports up in parallel (one host:port once at a time), next to
// the workers' startup lookups. Make it safe to call from several threads.
// One that never returns keeps its lookup thread for good. The followers of
// one host:port share each lookup of it, made with the first follower's
// ResolveFn (Resolver.follow): give them all the same one.
pub type ResolveFn = fn (host string, port int) []Addr

// refresh_gap_ms spaces the refreshes a host's followers ask for: while a
// host fails every dial (its DNS is down, or every address refuses), each
// failure asks, and the asks of a whole burst cost one lookup of that host per
// gap, however fast its DNS fails, instead of one per failure. The gap runs
// from the end of the host's last lookup, and is min(refresh_gap_ms,
// interval_ms), so an ask never waits past the next periodic refresh.
const refresh_gap_ms = 1000

// max_lookups is the number of lookup threads (start() spawns them all), so
// the most lookups that run at once. Neither getaddrinfo nor a ResolveFn can
// be cancelled: a lookup holds its thread until the call returns, and while
// every thread is held, the hosts that are due wait their turn, in order, for
// one to return.
const max_lookups = 8

// Resolver is the resolver thread, its lookup threads, and the followers it
// writes to.
@[heap]
pub struct Resolver {
mut:
	interval_ms int
	mu          &sync.Mutex = sync.new_mutex()
	subs        []&Sub          // guarded by mu
	names       []&Name         // the hosts the subs follow, one each; guarded by mu
	snap        []&Sub          // the resolver thread's copy of the live subs, reused
	nsnap       []&Name         // and of names
	threads     []&LookupThread // spawned by start()
	next        int             // the resolver thread's: where its next hand-out starts in nsnap (in turn)
	wake_r      int = -1
	wake_w      int = -1
	stop_flag   i64 // atomic, set under mu (see look)
	seq         u32
	th          thread
	started     bool
	rec         Record // the record write_update sends, reused
}

// Sub is one follower of the resolver.
@[heap]
struct Sub {
mut:
	name  &Name = unsafe { nil } // the host it follows
	fd    int  // the follower's pipe, write end: owned (and closed) by the resolver thread
	gone  bool // guarded by mu: the follower is done (Feed.unfollow): close fd, write no more
	asked u64  // atomic: the follower asked for a refresh, and no lookup of its host started since
}

// Name is one host:port the resolver follows, shared by every follower of
// it: one lookup of it at a time, made with its first follower's resolve.
@[heap]
struct Name {
mut:
	host    string // NUL-terminated copy
	port    int
	port_z  string // the port as a NUL-terminated decimal string
	resolve ResolveFn = unsafe { nil }
	// the resolver thread's (follow sets the first due)
	due   u64  // the next periodic lookup, monotonic ns
	last  u64  // when the last lookup ended
	asked bool // a follower asked: look up once the gap since `last` has passed
	busy  bool // a lookup is in flight
	live  bool // a follower still follows it
}

// LookupThread is one of the resolver's lookup threads, with the answer of
// the lookup it runs.
@[heap]
struct LookupThread {
mut:
	sem  &sync.Semaphore = sync.new_semaphore() // posted with a lookup, and by stop()
	job  &Name           = unsafe { nil }         // the lookup it runs (nil: idle), set by the resolver thread before it posts
	done u64 // atomic: the answer is ready
	// the answer: written by the lookup, read by the resolver thread once done
	count int
	found [max_addrs]Addr
	tmp   [max_addrs]C.transport_resolved
}

// Record is one address in an update: `count` records with the same `seq`,
// `idx` 0 .. count-1, make the host's new address table.
struct Record {
	seq    u32
	idx    u16
	count  u16
	family i32
	len    u32
	data   [128]u8
}

// Feed is one follower's end of a Resolver (follow): the read end of the
// pipe the resolver thread writes its updates to, and the update being
// received. It belongs to the follower's worker: only that thread uses it.
pub struct Feed {
pub mut:
	// fd is the pipe's read end, -1 if none. The follower owns it: it reads
	// the updates with take, when fd turns readable or on a timer, and closes
	// it once done.
	fd int = -1
mut:
	resolver  &Resolver = unsafe { nil }
	sub       &Sub      = unsafe { nil }
	staging   []Addr // the update being received
	stage_seq u32
	rec       Record // the record take reads into, reused
}

@[typedef]
struct C.transport_resolved {
mut:
	family i32
	len    u32
	data   [128]u8
}

fn C.transport_resolve(host &char, port &char, out &C.transport_resolved, max int, gai_err &i32) int
fn C.transport_pipe(fds &i32) int
fn C.transport_wait(fd int, timeout_ms int) int
fn C.transport_block_sigpipe()
fn C.read(fd int, buf voidptr, count u64) int
fn C.write(fd int, buf voidptr, n u64) int

// Resolver.new makes a resolver that refreshes each followed host every
// `interval_ms` (e.g. 30_000). start() it once the followers follow it, or
// before: followers may follow it at any time.
pub fn Resolver.new(interval_ms int) !&Resolver {
	if interval_ms < 1 {
		return error('transport: resolver interval_ms must be >= 1')
	}
	mut fds := [2]i32{}
	if C.transport_pipe(&fds[0]) != 0 {
		return error('transport: cannot open the resolver wake pipe')
	}
	return &Resolver{
		interval_ms: interval_ms
		wake_r:      int(fds[0])
		wake_w:      int(fds[1])
		snap:        []&Sub{cap: 64}
		nsnap:       []&Name{cap: 16}
	}
}

// start spawns the resolver thread and its max_lookups lookup threads, all at
// once: a thread that cannot be created stops the process here, at startup (V
// aborts), not in the middle of a DNS incident. A stopped Resolver does not
// start again.
pub fn (mut r Resolver) start() {
	if r.started || stdatomic.load_i64(&r.stop_flag) != 0 {
		return
	}
	r.started = true
	for _ in 0 .. max_lookups {
		mut t := &LookupThread{}
		r.threads << t
		spawn r.look(mut t)
	}
	r.th = spawn r.run()
}

// stop ends a started resolver for good (before start() it does nothing) and
// returns at once: it waits for the resolver thread, which never waits for a
// lookup, and not for a lookup in flight. Neither getaddrinfo nor a ResolveFn
// can be cancelled, so a ResolveFn may still be running when stop() returns:
// its thread finishes the call, drops the answer and ends, and one that never
// returns keeps its thread for good. Once stop() returns, no thread of the
// resolver writes to any pipe. Followers keep the addresses they have (none,
// for a follower that has not resolved yet), and the pipes it closes hang up.
// The wake pipe stays open: followers may still ask, and nobody reads it.
pub fn (mut r Resolver) stop() {
	if !r.started {
		return
	}
	r.mu.lock()
	stdatomic.store_i64(&r.stop_flag, 1) // under mu: a lookup thread checks it there before it writes
	r.mu.unlock()
	b := u8(1)
	C.write(r.wake_w, &b, 1)
	r.th.wait()
	r.started = false
	for mut t in r.threads {
		t.sem.post() // an idle lookup thread ends now, a busy one once its call returns
	}
	r.mu.lock()
	for mut s in r.subs {
		if s.fd >= 0 {
			C.close(s.fd)
			s.fd = -1
		}
	}
	r.mu.unlock()
}

// follow subscribes host:port to the resolver's refreshes, resolved with
// `resolve` (nil: the system resolver, getaddrinfo), and returns the
// follower's end. Call it at startup (make_state), once per follower: each
// follower gets its own pipe, and the followers of one host:port share each
// lookup of it, made with the first one's `resolve` (even once that one has
// unfollowed). The host's first periodic refresh comes interval_ms after its
// first follow.
pub fn (mut r Resolver) follow(host string, port int, resolve ResolveFn) !Feed {
	mut fds := [2]i32{}
	if C.transport_pipe(&fds[0]) != 0 {
		return error('transport: cannot open the resolver pipe')
	}
	r.mu.lock()
	mut name := &Name(unsafe { nil })
	for n in r.names {
		if n.port == port && n.host == host {
			name = n
			break
		}
	}
	if name == unsafe { nil } {
		name = &Name{
			host:    host.clone()
			port:    port
			port_z:  port.str()
			resolve: resolve
			due:     time.sys_mono_now() + u64(r.interval_ms) * u64(time.millisecond)
		}
		r.names << name
	}
	sub := &Sub{
		name: name
		fd:   int(fds[1])
	}
	r.subs << sub
	r.mu.unlock()
	return Feed{
		fd:       int(fds[0])
		resolver: r
		sub:      sub
		staging:  []Addr{cap: max_addrs}
	}
}

// followed reports whether the feed came from a Resolver (follow), stopped
// since or not.
pub fn (f &Feed) followed() bool {
	return f.resolver != unsafe { nil }
}

// ask asks the resolver to refresh the feed's host (a dial failed: every
// address an exchange tried, or a re-dial's address; or the follower has no
// address): at once, or one gap (refresh_gap_ms) after the host's last
// lookup. It sets a flag on the follower's own Sub, which the host's next
// lookup clears as it starts, and only the ask that sets it writes a byte to
// wake the resolver thread: a burst of asks costs one write per lookup, and a
// full pipe loses nothing (the thread is awake already, and the flag holds
// the ask). Nothing for a feed that follows no resolver.
pub fn (f &Feed) ask() {
	if f.sub == unsafe { nil } {
		return
	}
	// A load first: while the flag is set (a burst of failures), an ask only
	// reads it, so the workers' asks never bounce its cache line.
	if stdatomic.load_u64(&f.sub.asked) == 0
		&& C.atomic_exchange_u64(voidptr(&f.sub.asked), 1) == 0 {
		b := u8(1)
		C.write(f.resolver.wake_w, &b, 1)
	}
}

// take reads the records waiting in the feed's pipe, without blocking, and
// swaps each complete update into `table` (up to max_addrs addresses, in the
// resolver's order). true when it swapped the table. Allocates nothing once
// `table` has room for max_addrs addresses.
pub fn (mut f Feed) take(mut table []Addr) bool {
	if f.fd < 0 {
		return false
	}
	mut swapped := false
	// Into the feed's record, not a local: V moves a local Record (its fixed
	// array) to the heap, an allocation per call under -gc none.
	for C.read(f.fd, &f.rec, sizeof(Record)) == int(sizeof(Record)) {
		if f.take_record(mut table) {
			swapped = true
		}
	}
	return swapped
}

// take_record stages f.rec; the last record of an update swaps the table
// (true). A record out of sequence (a write the resolver dropped) discards
// the update.
fn (mut f Feed) take_record(mut table []Addr) bool {
	rec := &f.rec
	if rec.idx == 0 {
		f.staging.clear()
		f.stage_seq = rec.seq
	}
	if rec.seq != f.stage_seq || int(rec.idx) != f.staging.len || rec.count == 0 {
		f.staging.clear()
		f.stage_seq = 0
		return false
	}
	if f.staging.len < max_addrs {
		f.staging << Addr{
			family: int(rec.family)
			len:    rec.len
			data:   rec.data
		}
	}
	if int(rec.idx) != int(rec.count) - 1 {
		return false
	}
	table.clear()
	for a in f.staging {
		table << a
	}
	f.staging.clear()
	return true
}

// unfollow ends the updates: the resolver thread closes the pipe's write end
// once it wakes, which unfollow asks it to, and writes no more to it after an
// update it may be writing right then. The read end (fd) stays the follower's
// to close.
pub fn (mut f Feed) unfollow() {
	if f.sub == unsafe { nil } {
		return
	}
	mut r := f.resolver
	r.mu.lock()
	f.sub.gone = true
	r.mu.unlock()
	b := u8(1)
	C.write(r.wake_w, &b, 1)
}

// run is the resolver thread: it hands each host's lookups to the lookup
// threads when they are due, and writes each answer to the host's followers.
// It never waits for a lookup: a lookup thread wakes it when one ends.
fn (mut r Resolver) run() {
	// A write to the pipe of a follower that closed its end meets no reader:
	// EPIPE, not a process-killing SIGPIPE (the signal goes to the writing
	// thread).
	C.transport_block_sigpipe()
	interval := u64(r.interval_ms) * u64(time.millisecond)
	gap := u64(if r.interval_ms < refresh_gap_ms { r.interval_ms } else { refresh_gap_ms }) * u64(time.millisecond)
	mut drain := [64]u8{}
	for {
		for C.read(r.wake_r, &drain[0], u64(drain.len)) > 0 {
		}
		// After every drain and before the next wait: the drain may have taken
		// stop()'s byte, which comes after the flag (#368).
		if stdatomic.load_i64(&r.stop_flag) != 0 {
			return
		}
		r.take_subs()
		now := time.sys_mono_now()
		// The lookups that ended: their answers go to the hosts' followers.
		for mut t in r.threads {
			if t.job != unsafe { nil } && stdatomic.load_u64(&t.done) != 0 {
				mut n := t.job
				n.busy = false
				n.last = now
				n.due = now + interval
				r.answer(n, t)
				t.job = unsafe { nil }
				stdatomic.store_u64(&t.done, 0)
			}
		}
		// The asks: each follower's flag, onto its host (the host's next
		// lookup clears them).
		for mut s in r.snap {
			if stdatomic.load_u64(&s.asked) != 0 {
				s.name.asked = true
			}
		}
		// Hand out the lookups that are due, and wait for the next one. The
		// scan starts where the last hand-out stopped, so while every lookup
		// thread is busy, the hosts that are due get the threads in turn: none
		// waits behind hosts that keep coming due.
		mut wait := interval
		count := r.nsnap.len
		from := r.next
		for k in 0 .. count {
			i := (from + k) % count
			mut n := r.nsnap[i]
			if n.busy || !n.live {
				continue
			}
			mut at := n.due
			if n.asked && n.last + gap < at {
				at = n.last + gap
			}
			if at > now {
				if at - now < wait {
					wait = at - now
				}
				continue
			}
			if !r.start_lookup(mut n) {
				// Every lookup thread is busy: this host gets the next one, and
				// the next one to end wakes this thread.
				r.next = i
				break
			}
			r.next = i + 1
		}
		C.transport_wait(r.wake_r, int((wait + 999_999) / 1_000_000))
	}
}

// take_subs copies the live subs and the names for the resolver thread, and
// closes the pipes of the followers that are done: here, by their only writer
// (closed by the follower, the number could be reused under a write in
// flight).
fn (mut r Resolver) take_subs() {
	r.mu.lock()
	r.snap.clear()
	for mut s in r.subs {
		if s.gone {
			if s.fd >= 0 {
				C.close(s.fd)
				s.fd = -1
			}
			continue
		}
		r.snap << s
	}
	r.nsnap.clear()
	for n in r.names {
		r.nsnap << n
	}
	r.mu.unlock()
	for mut n in r.nsnap {
		n.live = false
	}
	for mut s in r.snap {
		s.name.live = true
	}
}

// start_lookup hands n's lookup to an idle lookup thread: false when every
// one is busy. The lookup answers every ask of n's followers so far: their
// flags clear.
fn (mut r Resolver) start_lookup(mut n Name) bool {
	for mut t in r.threads {
		if t.job != unsafe { nil } {
			continue
		}
		n.busy = true
		n.asked = false
		for mut s in r.snap {
			if voidptr(s.name) == voidptr(n) {
				stdatomic.store_u64(&s.asked, 0)
			}
		}
		t.job = n
		t.sem.post()
		return true
	}
	return false
}

// look is a lookup thread: it runs each lookup the resolver thread hands it,
// then wakes that thread for the answer. It writes to no follower's pipe.
fn (mut r Resolver) look(mut t LookupThread) {
	// A ResolveFn that writes to a peer gone away gets EPIPE, not a SIGPIPE
	// that kills the process: this thread took start()'s caller's signal mask,
	// which need not block it.
	C.transport_block_sigpipe()
	for {
		t.sem.wait()
		if stdatomic.load_i64(&r.stop_flag) != 0 {
			return
		}
		t.lookup()
		// Under mu, where stop() sets the flag: no write once stop() returned.
		r.mu.lock()
		stopped := stdatomic.load_i64(&r.stop_flag) != 0
		if !stopped {
			stdatomic.store_u64(&t.done, 1)
			b := u8(1)
			C.write(r.wake_w, &b, 1)
		}
		r.mu.unlock()
		if stopped {
			return
		}
	}
}

// answer writes t's answer, an ended lookup of n, to each follower of n as
// one update. A host that did not resolve keeps its old table.
fn (mut r Resolver) answer(n &Name, t &LookupThread) {
	if t.count == 0 {
		return
	}
	r.seq++
	for s in r.snap {
		if voidptr(s.name) == voidptr(n) {
			r.write_update(s.fd, t)
		}
	}
}

// write_update writes t's answer to one follower's pipe as one update.
fn (mut r Resolver) write_update(fd int, t &LookupThread) {
	for k in 0 .. t.count {
		// r.rec, not a local: a local Record goes to the heap (see Feed.take).
		r.rec = Record{
			seq:    r.seq
			idx:    u16(k)
			count:  u16(t.count)
			family: i32(t.found[k].family)
			len:    t.found[k].len
			data:   t.found[k].data
		}
		if C.write(fd, &r.rec, sizeof(Record)) != int(sizeof(Record)) {
			return // the pipe is full (a stalled worker): it gets the next round
		}
	}
}

// lookup resolves t.job's host into t.found, on t's thread, for as long as
// that takes: the host's ResolveFn, or the system resolver into a reused table
// (no allocation per lookup).
fn (mut t LookupThread) lookup() {
	n := t.job
	t.count = 0
	if n.resolve != unsafe { nil } {
		for a in n.resolve(n.host, n.port) {
			if t.count < max_addrs {
				t.found[t.count] = a
				t.count++
			}
		}
		return
	}
	mut gerr := i32(0)
	k := C.transport_resolve(&char(n.host.str), &char(n.port_z.str), &t.tmp[0], max_addrs,
		&gerr)
	for i in 0 .. k {
		t.found[i] = Addr{
			family: int(t.tmp[i].family)
			len:    t.tmp[i].len
			data:   t.tmp[i].data
		}
	}
	t.count = if k > 0 { k } else { 0 }
}

// resolve_system resolves host:port with getaddrinfo: the IPv4 and IPv6
// addresses in its order (at most max_addrs), or none. Blocking: at startup
// or on a resolver's lookup thread only.
pub fn resolve_system(host string, port int) []Addr {
	mut tmp := [max_addrs]C.transport_resolved{}
	h := host.clone() // NUL-terminated
	ps := port.str()
	mut gerr := i32(0)
	n := C.transport_resolve(&char(h.str), &char(ps.str), &tmp[0], max_addrs, &gerr)
	mut out := []Addr{}
	for i in 0 .. n {
		out << Addr{
			family: int(tmp[i].family)
			len:    tmp[i].len
			data:   tmp[i].data
		}
	}
	return out
}
