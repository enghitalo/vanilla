module upstream

import core
import transport

// Name resolution off the workers.
//
// Pool.new resolves its origin once, at startup (blocking: make_state runs
// before the worker serves, and a typo fails fast). An origin that sets
// allow_unresolved starts with no address instead when its name does not
// resolve (its DNS is down at boot): each exchange then fails at once with
// .dns, without dialing, until a refresh fills the table. A Resolver keeps the
// addresses fresh afterwards: one thread re-resolves every followed origin
// every interval_ms (getaddrinfo gives no TTL), and sooner when a pool runs
// out of addresses to try or has none (at once, or one refresh gap after the
// last refresh), then hands the answer to each worker over that pool's own
// pipe. A worker never resolves, never waits, and shares no mutable state with
// the thread: the pipe carries fixed-size address records, and the worker
// copies them into its pool's table on its own thread (a clientless watch,
// start_maintenance). The Resolver itself is transport.Resolver
// (transport/resolver_nix.c.v); pg_async's pools can follow the same one.
//
//   resolver := upstream.Resolver.new(30_000)!   // before new_server
//   resolver.start()
//   // make_state:      mut pay := upstream.Pool.new(origin, tls_cfg)!
//   //                  pay.follow(mut resolver)!
//   // on_worker_start: pay.start_maintenance(mut el)!
//
// Connections already open keep their address until max_lifetime_ms retires
// them; new dials use the new table.

// Resolver is transport.Resolver, which moved there from this module so that
// pg_async can follow it too (vanilla#351): upstream.Resolver.new, start(),
// stop() and Pool.follow work as before, and one Resolver can serve both.
pub type Resolver = transport.Resolver

// follow subscribes the pool to the resolver's refreshes: call it in
// make_state, after Pool.new; start_maintenance then watches the updates.
pub fn (mut p Pool) follow(mut r Resolver) ! {
	if p.feed.followed() {
		return error('upstream: the pool already follows a resolver')
	}
	p.feed = r.follow(p.origin.host, p.origin.port, p.origin.resolve)!
}

// request_resolve asks the pool's resolver for a refresh (every address
// failed, or there is none yet), which comes at once, or one gap
// (refresh_gap_ms) after the last refresh (transport.Feed.ask).
fn (mut p Pool) request_resolve() {
	p.feed.ask()
}

// resolve_system resolves host:port with getaddrinfo: the IPv4 and IPv6
// addresses in its order, or none. Blocking: at startup or on the resolver
// thread only. It is transport.resolve_system, kept here for callers of this
// name.
pub fn resolve_system(host string, port int) []transport.Addr {
	return transport.resolve_system(host, port)
}

// on_feed takes the resolver's records on the worker (a clientless watch on
// the pool's pipe) into the pool's address table.
fn on_feed(mut _ []u8, ready_fd int, fd_err bool, watch_payload voidptr, _ voidptr, mut el core.EventLoop) core.Step {
	mut p := unsafe { &Pool(watch_payload) }
	if p.closed {
		p.feed.fd = -1
		return .done // the runtime closes the read end
	}
	if p.feed.take(mut p.addrs) {
		p.cursor = 0
	}
	if fd_err {
		// The resolver stopped and closed its end: the pool keeps the addresses
		// it has. A pipe without a writer is ready for good, so watching it
		// again would spin the worker.
		p.feed.fd = -1
		return .done // the runtime closes the read end
	}
	el.watch_fd(ready_fd, .readable, on_feed, watch_payload)
	return .suspend
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
	p.feed.unfollow() // the resolver thread closes its write end
}
