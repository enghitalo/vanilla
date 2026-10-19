module transport

import sync
import sync.stdatomic
import time

// Name resolution off the workers (#229; moved here from http1_1.upstream so
// pg_async can follow it too, #351). getaddrinfo blocks for as long as the
// DNS takes (seconds when it drops queries) and allocates, so a worker must
// never call it. A follower resolves its host once, at startup (blocking:
// make_state runs before the worker serves). A Resolver keeps the addresses
// fresh afterwards: one thread re-resolves every followed host every
// interval_ms (getaddrinfo gives no TTL), and sooner when a follower asks
// (Feed.ask: every address it tried failed, or it has none), at once or
// refresh_gap_ms after the last refresh, then hands the answer to each
// follower over that follower's own pipe. A worker never resolves, never
// waits, and shares no mutable state with the thread: the pipe carries
// fixed-size address records (one write each, under PIPE_BUF, so atomic),
// and the worker copies them into its own table on its own thread
// (Feed.take). One Resolver can serve every follower in the process:
// http1_1.upstream's pools and pg_async's.
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
// it cannot. It runs at startup and on a Resolver's thread, so it may block
// and allocate.
pub type ResolveFn = fn (host string, port int) []Addr

// refresh_gap_ms spaces the refreshes followers ask for: while a host fails
// every dial (its DNS is down, or every address refuses), each failure asks,
// and the asks of a whole burst cost one resolution per host per gap, however
// fast the DNS fails, instead of one per failure. The gap is
// min(refresh_gap_ms, interval_ms), so an ask never waits past the next
// periodic refresh.
const refresh_gap_ms = 1000

// Resolver is the resolver thread and the followers it writes to.
@[heap]
pub struct Resolver {
mut:
	interval_ms int
	mu          &sync.Mutex = sync.new_mutex()
	subs        []Sub // guarded by mu
	snap        []Sub // the thread's copy, reused
	wake_r      int = -1
	wake_w      int = -1
	stop_flag   i64
	seq         u32
	th          thread
	started     bool
	tmp         [max_addrs]C.transport_resolved
	found       []Addr // the thread's resolve answer, reused
	rec         Record // the record write_update sends, reused
}

// Sub is one follower of the resolver.
struct Sub {
mut:
	id      int
	host    string // NUL-terminated copy
	port    int
	port_z  string // the port as a NUL-terminated decimal string
	resolve ResolveFn = unsafe { nil }
	fd      int  // the follower's pipe, write end: owned (and closed) by the resolver thread
	gone    bool // the follower is done (Feed.unfollow): close fd, write no more
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
	id        int       = -1
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
fn C.read(fd int, buf voidptr, count usize) int
fn C.write(fd int, buf voidptr, n usize) int

// Resolver.new makes a resolver that refreshes every `interval_ms`
// (e.g. 30_000). start() it once the followers follow it, or before:
// followers may follow it at any time.
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
		snap:        []Sub{cap: 64}
		found:       []Addr{cap: max_addrs}
	}
}

// start spawns the resolver thread.
pub fn (mut r Resolver) start() {
	if r.started {
		return
	}
	r.started = true
	r.th = spawn r.run()
}

// stop ends the resolver thread for good and waits for it (through a
// resolution in flight, or the rest of a refresh gap): a stopped Resolver
// does not start again. Followers keep the addresses they have (none, for a
// follower that has not resolved yet), and the pipes it closes hang up.
pub fn (mut r Resolver) stop() {
	if !r.started {
		return
	}
	stdatomic.store_i64(&r.stop_flag, 1)
	b := u8(1)
	C.write(r.wake_w, &b, 1)
	r.th.wait()
	r.started = false
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
// follower gets its own pipe, and the followers of one host:port share one
// lookup per refresh.
pub fn (mut r Resolver) follow(host string, port int, resolve ResolveFn) !Feed {
	mut fds := [2]i32{}
	if C.transport_pipe(&fds[0]) != 0 {
		return error('transport: cannot open the resolver pipe')
	}
	r.mu.lock()
	id := r.subs.len
	r.subs << Sub{
		id:      id
		host:    host.clone()
		port:    port
		port_z:  port.str()
		resolve: resolve
		fd:      int(fds[1])
	}
	r.mu.unlock()
	return Feed{
		fd:       int(fds[0])
		resolver: r
		id:       id
		staging:  []Addr{cap: max_addrs}
	}
}

// followed reports whether the feed came from a Resolver (follow), stopped
// since or not.
pub fn (f &Feed) followed() bool {
	return f.resolver != unsafe { nil }
}

// ask asks the resolver for a refresh (every address the follower tried
// failed, or it has none), which comes at once, or one gap (refresh_gap_ms)
// after the last refresh. One byte on its wake pipe; a full pipe means one is
// pending already. Nothing for a feed that follows no resolver.
pub fn (f &Feed) ask() {
	if f.resolver == unsafe { nil } {
		return
	}
	b := u8(1)
	C.write(f.resolver.wake_w, &b, 1)
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

// unfollow ends the updates: the resolver thread writes no more to the
// feed's pipe and closes its write end at its next refresh. The read end (fd)
// stays the follower's to close.
pub fn (mut f Feed) unfollow() {
	if f.resolver == unsafe { nil } || f.id < 0 {
		return
	}
	mut r := f.resolver
	r.mu.lock()
	r.subs[f.id].gone = true
	r.mu.unlock()
}

// run is the resolver thread.
fn (mut r Resolver) run() {
	// A write to the pipe of a follower that closed its end meets no reader:
	// EPIPE, not a process-killing SIGPIPE (the signal goes to the writing
	// thread).
	C.transport_block_sigpipe()
	gap := u64(if r.interval_ms < refresh_gap_ms { r.interval_ms } else { refresh_gap_ms }) * u64(time.millisecond)
	mut drain := [64]u8{}
	mut last := u64(0) // when the last refresh started
	for {
		C.transport_wait(r.wake_r, r.interval_ms)
		if stdatomic.load_i64(&r.stop_flag) != 0 {
			return
		}
		// Asked again within the gap: wait it out. The asks that come in the
		// meanwhile wait in the pipe, and the one refresh answers them all.
		since := time.sys_mono_now() - last
		if last > 0 && since < gap {
			time.sleep(time.Duration(gap - since))
			if stdatomic.load_i64(&r.stop_flag) != 0 {
				return
			}
		}
		for C.read(r.wake_r, &drain[0], usize(drain.len)) > 0 {
		}
		last = time.sys_mono_now()
		r.refresh()
	}
}

// refresh resolves every followed host once and writes the answer to each
// follower's pipe. A host that does not resolve keeps its old table.
fn (mut r Resolver) refresh() {
	r.mu.lock()
	r.snap.clear()
	for mut s in r.subs {
		if s.gone && s.fd >= 0 {
			// Closed here, by the only thread that writes to it: closed by the
			// worker, the number could be reused under a write in flight.
			C.close(s.fd)
			s.fd = -1
		}
		r.snap << s
	}
	r.mu.unlock()
	r.seq++
	for i, s in r.snap {
		if s.fd < 0 || s.gone {
			continue
		}
		// One resolution per host, written to every follower of it.
		mut first := true
		for j in 0 .. i {
			if r.snap[j].fd >= 0 && !r.snap[j].gone && r.snap[j].port == s.port
				&& r.snap[j].host == s.host {
				first = false
				break
			}
		}
		if !first {
			continue // done with the earlier follower
		}
		r.resolve_into(s)
		if r.found.len == 0 {
			continue
		}
		for j in i .. r.snap.len {
			f := r.snap[j]
			if f.fd >= 0 && !f.gone && f.port == s.port && f.host == s.host {
				r.write_update(f.fd)
			}
		}
	}
}

// write_update writes r.found to one follower's pipe as one update.
fn (mut r Resolver) write_update(fd int) {
	n := if r.found.len > max_addrs { max_addrs } else { r.found.len }
	for k in 0 .. n {
		// r.rec, not a local: a local Record goes to the heap (see Feed.take).
		r.rec = Record{
			seq:    r.seq
			idx:    u16(k)
			count:  u16(n)
			family: i32(r.found[k].family)
			len:    r.found[k].len
			data:   r.found[k].data
		}
		if C.write(fd, &r.rec, sizeof(Record)) != int(sizeof(Record)) {
			return // the pipe is full (a stalled worker): it gets the next round
		}
	}
}

// resolve_into resolves one host into r.found: its own ResolveFn, or the
// system resolver into a reused table (no allocation per refresh).
fn (mut r Resolver) resolve_into(s Sub) {
	r.found.clear()
	if s.resolve != unsafe { nil } {
		for a in s.resolve(s.host, s.port) {
			if r.found.len < max_addrs {
				r.found << a
			}
		}
		return
	}
	mut gerr := i32(0)
	n := C.transport_resolve(&char(s.host.str), &char(s.port_z.str), &r.tmp[0], max_addrs,
		&gerr)
	for k in 0 .. n {
		r.found << Addr{
			family: int(r.tmp[k].family)
			len:    r.tmp[k].len
			data:   r.tmp[k].data
		}
	}
}

// resolve_system resolves host:port with getaddrinfo: the IPv4 and IPv6
// addresses in its order (at most max_addrs), or none. Blocking: at startup
// or on the resolver thread only.
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
