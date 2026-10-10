module upstream

import core
import sync
import sync.stdatomic
import transport

// Name resolution off the workers.
//
// Pool.new resolves its origin once, at startup (blocking: make_state runs
// before the worker serves, and a typo fails fast). A Resolver keeps the
// addresses fresh afterwards: one thread re-resolves every followed origin
// every interval_ms (getaddrinfo gives no TTL), and at once when a pool runs
// out of addresses to try, then hands the answer to each worker over that
// pool's own pipe. A worker never resolves, never waits, and shares no mutable
// state with the thread: the pipe carries fixed-size address records (one
// write each, under PIPE_BUF, so atomic), and the worker copies them into its
// pool's table on its own thread (a clientless watch, start_maintenance).
//
//   resolver := upstream.Resolver.new(30_000)!   // before new_server
//   resolver.start()
//   // make_state:      mut pay := upstream.Pool.new(origin, tls_cfg)!
//   //                  pay.follow(mut resolver)!
//   // on_worker_start: pay.start_maintenance(mut el)!
//
// Connections already open keep their address until max_lifetime_ms retires
// them; new dials use the new table.

// Resolver is the resolver thread and the pools that follow it.
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
	tmp         [max_addrs]C.upstream_addr
	found       []transport.Addr // the thread's resolve answer, reused
	rec         Record           // the record write_update sends, reused
}

// Sub is one pool following the resolver.
struct Sub {
mut:
	id      int
	host    string // NUL-terminated copy
	port    int
	port_z  string // the port as a NUL-terminated decimal string
	resolve ResolveFn = unsafe { nil }
	fd      int  // the pool's pipe, write end: owned (and closed) by the resolver thread
	gone    bool // the pool closed: close fd, write no more
}

// Record is one address in an update: `count` records with the same `seq`,
// `idx` 0 .. count-1, make the origin's new address table.
struct Record {
	seq    u32
	idx    u16
	count  u16
	family i32
	len    u32
	data   [128]u8
}

@[typedef]
struct C.upstream_addr {
mut:
	family i32
	len    u32
	data   [128]u8
}

fn C.upstream_resolve(host &char, port &char, out &C.upstream_addr, max int, gai_err &i32) int
fn C.upstream_pipe(fds &i32) int
fn C.upstream_wait(fd int, timeout_ms int) int
fn C.write(fd int, buf voidptr, n usize) int
fn C.upstream_block_sigpipe()

// Resolver.new makes a resolver that refreshes every `interval_ms`
// (e.g. 30_000). start() it once the pools follow it, or before: pools may
// follow it at any time.
pub fn Resolver.new(interval_ms int) !&Resolver {
	if interval_ms < 1 {
		return error('upstream: resolver interval_ms must be >= 1')
	}
	mut fds := [2]i32{}
	if C.upstream_pipe(&fds[0]) != 0 {
		return error('upstream: cannot open the resolver wake pipe')
	}
	return &Resolver{
		interval_ms: interval_ms
		wake_r:      int(fds[0])
		wake_w:      int(fds[1])
		snap:        []Sub{cap: 64}
		found:       []transport.Addr{cap: max_addrs}
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

// stop ends the resolver thread for good and waits for it: a stopped
// Resolver does not start again. Pools keep the addresses they have, and
// their workers stop watching the pipes it closes.
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

// follow subscribes the pool to the resolver's refreshes: call it in
// make_state, after Pool.new; start_maintenance then watches the updates.
pub fn (mut p Pool) follow(mut r Resolver) ! {
	if p.resolver != unsafe { nil } {
		return error('upstream: the pool already follows a resolver')
	}
	mut fds := [2]i32{}
	if C.upstream_pipe(&fds[0]) != 0 {
		return error('upstream: cannot open the resolver pipe')
	}
	p.feed_fd = int(fds[0])
	p.resolver = r
	r.mu.lock()
	p.sub_id = r.subs.len
	r.subs << Sub{
		id:      p.sub_id
		host:    p.origin.host.clone()
		port:    p.origin.port
		port_z:  p.origin.port.str()
		resolve: p.origin.resolve
		fd:      int(fds[1])
	}
	r.mu.unlock()
}

// request_resolve asks the resolver for a refresh now (every address failed).
// One byte on its wake pipe; a full pipe means one is pending already.
fn (mut p Pool) request_resolve() {
	if p.resolver == unsafe { nil } {
		return
	}
	b := u8(1)
	C.write(p.resolver.wake_w, &b, 1)
}

// run is the resolver thread.
fn (mut r Resolver) run() {
	// A write to the pipe of a pool the worker closed meets no reader: EPIPE,
	// not a process-killing SIGPIPE (the signal goes to the writing thread).
	C.upstream_block_sigpipe()
	mut drain := [64]u8{}
	for {
		C.upstream_wait(r.wake_r, r.interval_ms)
		if stdatomic.load_i64(&r.stop_flag) != 0 {
			return
		}
		for C.read(r.wake_r, &drain[0], usize(drain.len)) > 0 {
		}
		r.refresh()
	}
}

// refresh resolves every followed origin once and writes the answer to each
// follower's pipe. An origin that does not resolve keeps its old table.
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
		// One resolution per origin, written to every follower of it.
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
		// r.rec, not a local: a local Record goes to the heap (see on_feed).
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

// resolve_into resolves one origin into r.found: its own ResolveFn, or the
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
	n := C.upstream_resolve(&char(s.host.str), &char(s.port_z.str), &r.tmp[0], max_addrs, &gerr)
	for k in 0 .. n {
		r.found << transport.Addr{
			family: int(r.tmp[k].family)
			len:    r.tmp[k].len
			data:   r.tmp[k].data
		}
	}
}

// resolve_system resolves host:port with getaddrinfo: the IPv4 and IPv6
// addresses in its order, or none. Blocking: at startup or on the resolver
// thread only.
pub fn resolve_system(host string, port int) []transport.Addr {
	mut tmp := [max_addrs]C.upstream_addr{}
	h := host.clone() // NUL-terminated
	ps := port.str()
	mut gerr := i32(0)
	n := C.upstream_resolve(&char(h.str), &char(ps.str), &tmp[0], max_addrs, &gerr)
	mut out := []transport.Addr{}
	for i in 0 .. n {
		out << transport.Addr{
			family: int(tmp[i].family)
			len:    tmp[i].len
			data:   tmp[i].data
		}
	}
	return out
}

// on_feed takes the resolver's records on the worker (a clientless watch on
// the pool's pipe) into the pool's address table.
fn on_feed(mut _ []u8, ready_fd int, fd_err bool, watch_payload voidptr, _ voidptr, mut el core.EventLoop) core.Step {
	mut p := unsafe { &Pool(watch_payload) }
	if p.closed {
		p.feed_fd = -1
		return .done // the runtime closes the read end
	}
	// Into the pool's record, not a local: V moves a local Record (its fixed
	// array) to the heap, an allocation per wake under -gc none.
	for C.read(ready_fd, &p.feed_rec, sizeof(Record)) == int(sizeof(Record)) {
		p.take_record(&p.feed_rec)
	}
	if fd_err {
		// The resolver stopped and closed its end: the pool keeps the addresses
		// it has. A pipe without a writer is ready for good, so watching it
		// again would spin the worker.
		p.feed_fd = -1
		return .done // the runtime closes the read end
	}
	el.watch_fd(ready_fd, .readable, on_feed, watch_payload)
	return .suspend
}

// take_record stages one record; the last one of an update swaps the table.
// A record out of sequence (a write the resolver dropped) discards the update.
fn (mut p Pool) take_record(rec &Record) {
	if rec.idx == 0 {
		p.staging.clear()
		p.stage_seq = rec.seq
	}
	if rec.seq != p.stage_seq || int(rec.idx) != p.staging.len || rec.count == 0 {
		p.staging.clear()
		p.stage_seq = 0
		return
	}
	if p.staging.len < max_addrs {
		p.staging << transport.Addr{
			family: int(rec.family)
			len:    rec.len
			data:   rec.data
		}
	}
	if int(rec.idx) == int(rec.count) - 1 {
		p.addrs.clear()
		for a in p.staging {
			p.addrs << a
		}
		p.cursor = 0
		p.staging.clear()
	}
}

// close ends the pool: kept connections are closed, the maintenance timer and
// the resolver watch stop at their next wake, and the resolver stops writing
// to it. Exchanges in flight finish on their own (release() closes them).
pub fn (mut p Pool) close() {
	p.closed = true
	for mut x in p.slots {
		if !x.busy {
			x.drop_conn()
		}
	}
	if p.resolver != unsafe { nil } && p.sub_id >= 0 {
		mut r := p.resolver
		r.mu.lock()
		r.subs[p.sub_id].gone = true // the resolver thread closes its write end
		r.mu.unlock()
	}
}
