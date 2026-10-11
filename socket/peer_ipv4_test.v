module socket

import net

// peer_ipv4 over real connections: vlib's net opens them, so the same file
// runs on every platform. (`${}` here is test scaffolding.)

const loopback = u32(0x7f000001) // 127.0.0.1

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int

fn test_peer_ipv4_reads_both_ends_of_a_loopback_connection() ! {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { l.close() or {} }
	mut c := net.dial_tcp(l.addr()!.str())!
	defer { c.close() or {} }
	mut s := l.accept()!
	defer { s.close() or {} }
	assert peer_ipv4(s.sock.handle)? == loopback
	assert peer_ipv4(c.sock.handle)? == loopback
	assert peer_addr(s.sock.handle) == '127.0.0.1' // the allocating twin agrees
}

fn test_peer_ipv4_is_none_without_a_peer() ! {
	assert peer_ipv4(-1) == none // not a socket
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { l.close() or {} }
	assert peer_ipv4(l.sock.handle) == none // a listener has no peer
}

fn test_peer_ipv4_is_none_on_a_unix_socket() {
	$if !windows {
		mut sv := [2]i32{}
		assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
		defer {
			close_socket(sv[0])
			close_socket(sv[1])
		}
		assert peer_ipv4(sv[0]) == none
	}
}

// A dual-stack listener sees an IPv4 client as ::ffff:a.b.c.d: peer_ipv4
// unwraps it. A real IPv6 peer has no IPv4 address. Skipped where the host
// has no IPv6.
fn test_peer_ipv4_unwraps_ipv4_mapped_ipv6_and_rejects_ipv6() ! {
	mut l := net.listen_tcp(.ip6, '[::]:0') or {
		eprintln('skip: no IPv6 listener here (${err})')
		return
	}
	defer { l.close() or {} }
	port := l.addr()!.port()!
	mut c4 := net.dial_tcp('127.0.0.1:${port}')!
	defer { c4.close() or {} }
	mut s4 := l.accept()!
	defer { s4.close() or {} }
	assert peer_ipv4(s4.sock.handle)? == loopback
	mut c6 := net.dial_tcp('[::1]:${port}') or {
		eprintln('skip: no IPv6 loopback here (${err})')
		return
	}
	defer { c6.close() or {} }
	mut s6 := l.accept()!
	defer { s6.close() or {} }
	assert peer_ipv4(s6.sock.handle) == none
}

// One syscall and nothing on the heap: 20k calls must not move the
// collector's allocation counter.
fn test_peer_ipv4_allocates_nothing() ! {
	$if gcboehm ? {
		mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
		defer { l.close() or {} }
		mut c := net.dial_tcp(l.addr()!.str())!
		defer { c.close() or {} }
		mut s := l.accept()!
		defer { s.close() or {} }
		fd := s.sock.handle
		mut sum := u64(0)
		before := gc_heap_usage().total_bytes
		for _ in 0 .. 20_000 {
			sum += peer_ipv4(fd) or { 0 }
			if _ := peer_ipv4(-1) {
				sum++
			}
		}
		grown := gc_heap_usage().total_bytes - before
		assert sum == u64(20_000) * loopback
		assert grown < 4096, 'peer_ipv4 allocated ${grown} bytes over 40000 calls'
	}
}
