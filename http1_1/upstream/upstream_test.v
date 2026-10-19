// vtest build: linux
module upstream

// Unit tests without a server: request building and validation, the Host
// header, origin validation, the resolver hand-off, and deadline expiry. The
// exchange over real sockets is examples/https_upstream's e2e suite; the
// resolver's records themselves, transport/resolver_test.v.
import core
import time
import sync.stdatomic
import tls
import transport

fn plain_pool(o Origin) &Pool {
	return Pool.new(Origin{
		...o
		https: false
	}, unsafe { nil }) or { panic(err) }
}

fn head_of(mut x Exchange) string {
	return x.head.bytestr()
}

// The request head is built from validated parts only: a CR, LF or NUL in the
// method, target, a field name or value is refused (header injection), the
// exchange is marked invalid, and nothing of the bad part is written.
fn test_request_validation() {
	mut p := plain_pool(Origin{
		host: '127.0.0.1'
		port: 8080
	})
	mut x := p.acquire() or { panic('slot') }
	assert x.request('GET', '/v1/charges?q=a')
	assert x.header('Authorization', 'Bearer abc'.bytes())
	assert head_of(mut x) == 'GET /v1/charges?q=a HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nAuthorization: Bearer abc\r\n'
	assert !x.invalid
	// The #229 repro's target: refused, nothing written.
	assert !x.request('GET', '/v1/charges?q=a\r\nX-Injected: 1')
	assert x.invalid
	assert !head_of(mut x).contains('X-Injected')
	x.release()

	for bad in [['GE T', '/'], ['GET', ''], ['GET', '/a b'], ['GET\r\n', '/'], ['GET', '/\x00']] {
		mut y := p.acquire() or { panic('slot') }
		assert !y.request(bad[0], bad[1]), bad.str()
		y.release()
	}
	mut z := p.acquire() or { panic('slot') }
	assert z.request('POST', '/v1')
	for bad in [['X-A', 'a\r\nX-Injected: 1'], ['X-A', 'a\nb'], ['X-A', 'a\x00'], ['X A', 'v'],
		['X-A\r\n', 'v'], ['Host', 'evil'], ['content-length', '0'], ['Transfer-Encoding', 'chunked']] {
		mut w := p.acquire() or { panic('slot') }
		assert w.request('POST', '/v1')
		before := head_of(mut w)
		assert !w.header(bad[0], bad[1].bytes()), bad.str()
		assert w.invalid
		assert head_of(mut w) == before, bad.str() // nothing written
		w.release()
	}
	z.release()
}

// Host = uri-host [ ":" port ]: the port only when it is not the scheme's
// default, an IPv6 literal in brackets (RFC 9110 §7.2) and without its zone
// (RFC 6874 §4).
fn test_host_header() {
	cases := [
		['127.0.0.1', '80', 'Host: 127.0.0.1\r\n'],
		['127.0.0.1', '8080', 'Host: 127.0.0.1:8080\r\n'],
		['::1', '80', 'Host: [::1]\r\n'],
		['::1', '3000', 'Host: [::1]:3000\r\n'],
		['fe80::1%eth0', '8080', 'Host: [fe80::1]:8080\r\n'],
		['fe80::1%no-such-interface', '80', 'Host: [fe80::1]\r\n'], // longer than an interface name can be
	]
	// A zoned literal is resolved (transport.ip_addr takes no zone), and
	// getaddrinfo fails for an interface the machine lacks (eth0, on many):
	// this resolver answers instead. The other literals never reach it.
	link_local := transport.ip_addr('fe80::1', 80) or { panic('addr') }
	for c in cases {
		p := plain_pool(Origin{
			host:    c[0]
			port:    c[1].int()
			resolve: fn [link_local] (host string, port int) []transport.Addr {
				return [link_local]
			}
		})
		assert p.host_hdr.bytestr() == c[2], c.str()
		assert p.origin.host == c[0], c.str() // the zone stays: it is dialed with
	}
	// HTTPS: 443 is the default.
	mut a := transport.ip_addr('127.0.0.1', 443) or { panic('addr') }
	p := Pool.new(Origin{
		host:    'api.example.com'
		port:    443
		resolve: fn [a] (host string, port int) []transport.Addr {
			return [a]
		}
	}, tls_stub()) or { panic(err) }
	assert p.host_hdr.bytestr() == 'Host: api.example.com\r\n'
	// HTTPS to an IP literal (#233: no SNI, an iPAddress SAN must match): the
	// address is dialed as is, and the Host header carries it.
	for c in [['127.0.0.1', '443', 'Host: 127.0.0.1\r\n'], ['::1', '8443', 'Host: [::1]:8443\r\n']] {
		q := Pool.new(Origin{
			host: c[0]
			port: c[1].int()
		}, tls_stub()) or { panic(err) }
		assert q.host_hdr.bytestr() == c[2], c.str()
		assert q.addrs.len == 1, c.str()
	}
}

// tls_stub is a non-nil stand-in for a client TLS config: Pool.new only
// checks that one is set (no handshake runs here).
fn tls_stub() &tls.Config {
	return &tls.Config{}
}

fn test_origin_validation() {
	for bad in [Origin{
		host:  ''
		https: false
	}, Origin{
		host:  'a b'
		https: false
	}, Origin{
		host:  'a/b'
		https: false
	}, Origin{
		host:  'user@host'
		https: false
	}, Origin{
		host:  '127.0.0.1'
		port:  0
		https: false
	}, Origin{
		host:      '127.0.0.1'
		https:     false
		max_conns: 0
	}, Origin{
		host: 'api.example.com' // HTTPS without a TLS config
	}] {
		if _ := Pool.new(bad, unsafe { nil }) {
			assert false, bad.host
		}
	}
	// A name the resolver does not know.
	if _ := Pool.new(Origin{
		host:    'nowhere.invalid'
		https:   false
		resolve: fn (host string, port int) []transport.Addr {
			return []
		}
	}, unsafe { nil }) {
		assert false
	}
}

// never_woken is the continuation of an exchange that never parks.
fn never_woken(mut _ []u8, _ int, _ bool, _ voidptr, _ voidptr, mut _ core.EventLoop) core.Step {
	return .done
}

// The #348 repro, through the system resolver: provider.invalid never
// resolves (RFC 6761). Without allow_unresolved Pool.new fails as it always
// did (a typo fails fast). With it, the pool starts with no address, and
// every exchange fails at once with .dns: nothing is dialed or parked.
fn test_unresolved_origin_starts_empty() {
	if resolve_system('provider.invalid', 80).len > 0 {
		eprintln('upstream: this resolver answers provider.invalid; skipping')
		return
	}
	o := Origin{
		host:  'provider.invalid'
		port:  80
		https: false
	}
	if _ := Pool.new(o, unsafe { nil }) {
		assert false, 'Pool.new resolved provider.invalid'
	} else {
		assert err.msg() == 'upstream: cannot resolve provider.invalid:80'
	}
	mut p := Pool.new(Origin{
		...o
		allow_unresolved: true
	}, unsafe { nil }) or { panic(err) }
	assert p.addrs.len == 0
	mut el := core.EventLoop{
		register: record_watch
	}
	for method in ['GET', 'POST'] {
		mut x := p.acquire() or { panic('slot') }
		assert x.request(method, '/v1/charges')
		assert x.send(mut el, never_woken, unsafe { nil }) == .failed, method
		assert x.failure() == .dns, method
		assert x.fd == -1, method
		x.release()
	}
	assert p.stats.dials == 0
	assert el.last_watched == -1 // nothing parked
}

fn no_address(_ string, _ int) []transport.Addr {
	return []
}

// An origin that may start unresolved must follow a Resolver, or nothing ever
// fills its table: start_maintenance refuses it, whether or not the name
// resolved at this boot, and arms nothing, so the mistake shows at the first
// boot, not as .dns for good during an outage. A zoned IPv6 literal is
// resolved like a name: refused too. An IP literal (dialed as is, never
// empty) and a pool without the flag need no Resolver.
fn test_unresolved_origin_needs_a_resolver() {
	a := transport.ip_addr('127.0.0.1', 80) or { panic('addr') }
	one_address := fn [a] (host string, port int) []transport.Addr {
		return [a]
	}
	// One Resolver for every pool here; start() then stop() closes the write
	// ends of their pipes. (Its own wake pipe stays open: a Resolver lives as
	// long as the process.)
	mut r := Resolver.new(60_000) or { panic(err) }
	for host in ['provider.test', 'fe80::1%no-such-interface'] {
		for resolve in [no_address, one_address] {
			mut p := plain_pool(Origin{
				host:             host
				allow_unresolved: true
				resolve:          resolve
			})
			mut el := core.EventLoop{
				register: record_watch
			}
			if _ := p.start_maintenance(mut el) {
				assert false, '${host}: started without a Resolver'
			} else {
				assert err.msg().contains('Resolver'), err.msg()
			}
			assert p.timer_fd == -1 && el.last_watched == -1, host // nothing armed
			p.follow(mut r) or { panic(err) }
			p.start_maintenance(mut el) or { panic(err) }
			assert p.timer_fd >= 0 && el.last_watched == p.feed.fd, host
			for fd in [p.timer_fd, p.feed.fd] {
				C.close(fd)
			}
		}
	}
	r.start()
	r.stop()
	for o in [Origin{
		host:             '127.0.0.1'
		allow_unresolved: true
	}, Origin{
		host: '127.0.0.1'
	}] {
		mut q := plain_pool(o)
		mut el := core.EventLoop{
			register: record_watch
		}
		q.start_maintenance(mut el) or { panic(err) }
		C.close(q.timer_fd)
	}
}

// acquire hands out at most max_conns exchanges; release gives the slot back.
fn test_acquire_sheds_past_max_conns() {
	mut p := plain_pool(Origin{
		host:      '127.0.0.1'
		max_conns: 2
	})
	mut a := p.acquire() or { panic('a') }
	mut b := p.acquire() or { panic('b') }
	if _ := p.acquire() {
		assert false, 'a third exchange past max_conns: 2'
	}
	a.release()
	mut c := p.acquire() or { panic('c') }
	c.release()
	b.release()
}

// Port is the test resolver's answer, read on a lookup thread.
@[heap]
struct Port {
mut:
	n i64
}

// The resolver thread hands updates to a following pool through its pipe.
fn test_resolver_thread_hands_off() {
	mut port := &Port{
		n: 1111
	}
	pp := port
	mut p := plain_pool(Origin{
		host:    'svc.test'
		port:    80
		resolve: fn [pp] (host string, port int) []transport.Addr {
			a := transport.ip_addr('127.0.0.1', int(stdatomic.load_i64(&pp.n))) or { return [] }
			return [a]
		}
	})
	mut r := Resolver.new(20) or { panic(err) }
	p.follow(mut r) or { panic(err) }
	r.start()
	defer {
		r.stop()
	}
	stdatomic.store_i64(&port.n, 2222)
	sw := time.new_stopwatch()
	for sw.elapsed().milliseconds() < 2000 {
		if p.feed.take(mut p.addrs) && p.addrs.len == 1
			&& (int(p.addrs[0].data[2]) << 8 | int(p.addrs[0].data[3])) == 2222 {
			break
		}
		time.sleep(5 * time.millisecond)
	}
	assert (int(p.addrs[0].data[2]) << 8 | int(p.addrs[0].data[3])) == 2222
}

// record_watch is a test event loop's register: it only notes the fd.
fn record_watch(mut el core.EventLoop, fd int, _ core.WatchInterest, _ core.WakeFn, _ voidptr) {
	el.last_watched = fd
}

// A stopped resolver closes its end of the pool's pipe, which hangs up:
// on_feed takes the update still in it, then stops watching. (Watched again,
// a pipe without a writer is ready for good: the worker spun on it.)
fn test_feed_stops_when_the_resolver_stops() {
	mut port := &Port{
		n: 1111
	}
	pp := port
	mut p := plain_pool(Origin{
		host:    'svc.test'
		port:    80
		resolve: fn [pp] (host string, port int) []transport.Addr {
			a := transport.ip_addr('127.0.0.1', int(stdatomic.load_i64(&pp.n))) or { return [] }
			return [a]
		}
	})
	mut r := Resolver.new(60_000) or { panic(err) }
	p.follow(mut r) or { panic(err) }
	stdatomic.store_i64(&port.n, 2222)
	r.start()
	p.request_resolve()
	assert C.transport_wait(p.feed.fd, 2000) > 0 // the update is in the pipe
	r.stop()
	fd := p.feed.fd
	mut el := core.EventLoop{
		register: record_watch
	}
	mut out := []u8{}
	// fd_err: the worker's epoll reports the hangup (EPOLLHUP).
	assert on_feed(mut out, fd, true, voidptr(p), unsafe { nil }, mut el) == .done
	C.close(fd) // the runtime's part of .done
	assert el.last_watched == -1
	assert p.feed.fd == -1
	assert (int(p.addrs[0].data[2]) << 8 | int(p.addrs[0].data[3])) == 2222
}

// maintain() shuts down the socket of an exchange past its deadline (its
// watch then wakes, and advance() reports .timeout), and closes idle
// connections past idle_timeout_ms.
fn test_maintain_enforces_deadlines() {
	mut p := plain_pool(Origin{
		host:            '127.0.0.1'
		idle_timeout_ms: 50
	})
	mut fds := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &fds[0]) == 0
	mut x := p.acquire() or { panic('slot') }
	x.fd = int(fds[0])
	x.phase = .reading
	x.deadline = time.sys_mono_now() - 1
	p.maintain()
	assert x.timed_out
	assert C.upstream_peek(int(fds[0])) == 0 // shut down: reads see EOF
	x.release() // timed out: closed
	assert x.fd == -1
	C.close(int(fds[1]))
	// An idle kept connection past idle_timeout_ms is closed.
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &fds[0]) == 0
	mut y := p.acquire() or { panic('slot') }
	y.fd = int(fds[0])
	y.born = time.sys_mono_now()
	y.phase = .ready
	y.framer.keep_alive = true
	y.release()
	assert y.fd >= 0 // kept
	next := p.maintain()
	assert y.fd >= 0 && next <= 51
	time.sleep(60 * time.millisecond)
	p.maintain()
	assert y.fd == -1
	C.close(int(fds[1]))
}

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
