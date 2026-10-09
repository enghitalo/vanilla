module tls

import os

// The TLS client (pg_async's, http1_1/upstream's) against vanilla's own server
// side, over a socketpair. POSIX-only (`_nix`): <sys/socket.h> and fcntl do not
// exist on Windows. Like tls_test.v, these only do anything under
// `-d vanilla_tls`.

#include <sys/socket.h>
#include <fcntl.h>

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.close(fd int) int
fn C.fcntl(fd int, cmd int, arg int) int

// nonblocking_pair is a connected, non-blocking AF_UNIX socket pair: TLS does
// not care what carries it, and both ends live in this thread.
fn nonblocking_pair() [2]int {
	mut sv := [2]i32{} // C ints: V's int is 64-bit
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
	fds := [int(sv[0]), int(sv[1])]!
	for fd in fds {
		C.fcntl(fd, C.F_SETFL, C.fcntl(fd, C.F_GETFL, 0) | C.O_NONBLOCK)
	}
	return fds
}

// handshake_both steps a client and a server session in turn until both are
// done, or one fails: the client's result, then the server's.
fn handshake_both(cli Session, srv Session) (int, int) {
	mut cr, mut sr := want, want
	for _ in 0 .. 1000 {
		if cr != 0 && cr != closed {
			cli.mark_readable()
			cr = cli.handshake()
		}
		if sr != 0 && sr != closed {
			srv.mark_readable()
			sr = srv.handshake()
		}
		if (cr == 0 || cr == closed) && (sr == 0 || sr == closed || cr == closed) {
			break
		}
	}
	return cr, sr
}

// The client side (pg_async's TLS) against vanilla's own server side: each
// Verify mode against the self-signed localhost/loopback certificate, a host
// the certificate does not name, a session re-armed for a second connection,
// and data both ways.
fn test_client_sessions_against_the_server() {
	$if vanilla_tls ? {
		srv_cfg := new_self_signed() or { panic(err) }
		defer {
			srv_cfg.free()
		}
		ca := os.join_path(os.temp_dir(), 'vanilla_tls_client_ca_${os.getpid()}.pem')
		os.write_file(ca, srv_cfg.cert_pem()) or { panic(err) }
		defer {
			os.rm(ca) or {}
		}
		cases := [
			ClientCase{.full, 'localhost', ''},
			ClientCase{.full, '127.0.0.1', ''},
			ClientCase{.full, '::1', ''},
			ClientCase{.full, 'db.example.com', 'does not match the host name'},
			ClientCase{.chain, 'db.example.com', ''},
			ClientCase{.off, 'db.example.com', ''},
		]
		for case in cases {
			verify, host, want_err := case.verify, case.host, case.want_err
			cli_cfg := new_client(if verify == .off { '' } else { ca }, verify) or { panic(err) }
			mut cli := Session{}
			for round in 0 .. 2 {
				fds := nonblocking_pair()
				srv := srv_cfg.new_session(fds[0]) or { panic('server session') }
				if round == 0 {
					cli = cli_cfg.new_client_session(fds[1], host) or { panic('client session') }
				} else {
					// A re-dial: the same session, re-armed on a new socket.
					assert cli.reset(fds[1])
				}
				cr, _ := handshake_both(cli, srv)
				if want_err != '' {
					assert cr == closed, '${verify} ${host}: the handshake must fail'
					assert cli.handshake_error().contains(want_err), cli.handshake_error()
					assert cli.verify_failed()
				} else {
					assert cr == 0, '${verify} ${host}: ${cli.handshake_error()}'
					// Exact-size C buffers: under AddressSanitizer a read or
					// write past either end (Mbed TLS's memcpy included) aborts.
					msg := 'ping ${host} ${round}'
					out := unsafe { &u8(C.malloc(msg.len)) }
					unsafe { vmemcpy(out, msg.str, msg.len) }
					assert cli.write_from(out, msg.len) == msg.len
					inb := unsafe { &u8(C.malloc(msg.len)) }
					srv.mark_readable()
					assert srv.read_into(inb, msg.len) == msg.len
					assert unsafe { tos(inb, msg.len) } == msg
					assert srv.write_from(out, msg.len) == msg.len
					cli.mark_readable()
					assert cli.read_into(inb, msg.len) == msg.len
					assert !cli.peer_closed()
					unsafe {
						C.free(out)
						C.free(inb)
					}
				}
				// Round 0 ends with the server's close_notify (srv.free sends one);
				// round 1 with a bare EOF first, which is not a clean TLS close.
				if round == 1 {
					C.shutdown(fds[0], C.SHUT_WR)
				}
				srv.free()
				if want_err == '' {
					cli.mark_readable()
					assert cli.read_into(buf_scratch().data, 16) == closed
					assert cli.peer_closed()
					assert cli.close_notify() == (round == 0), '${verify} ${host} round ${round}'
				}
				assert cli.reset(-1) // detach before the fd is closed
				C.close(fds[0])
				C.close(fds[1])
			}
			cli.free()
			cli_cfg.free()
		}
	}
}

fn C.shutdown(fd int, how int) int

struct ClientCase {
	verify   Verify
	host     string
	want_err string // '' = the handshake succeeds
}

fn buf_scratch() []u8 {
	return []u8{len: 16}
}

// A root certificate file that is missing, or holds no certificate, is an
// error at config time; with Verify.off no file is read at all.
fn test_client_config_errors() {
	$if vanilla_tls ? {
		if _ := new_client('/nonexistent/ca.pem', .full) {
			assert false, 'a missing CA file must be an error'
		} else {
			assert err.msg().contains('/nonexistent/ca.pem'), err.msg()
		}
		junk := os.join_path(os.temp_dir(), 'vanilla_tls_junk_${os.getpid()}.pem')
		os.write_file(junk, 'not a certificate\n') or { panic(err) }
		defer {
			os.rm(junk) or {}
		}
		if _ := new_client(junk, .chain) {
			assert false, 'a file without a certificate must be an error'
		}
		c := new_client('/nonexistent/ca.pem', .off) or { panic(err) }
		c.free()
	}
}
