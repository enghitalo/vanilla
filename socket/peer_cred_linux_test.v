module socket

import net
import os

// peer_cred against real sockets. `_linux`: SO_PEERCRED and PID namespaces are
// Linux's (peer_cred_darwin.c.v reads getpeereid + LOCAL_PEERPID instead).
// (`${}` here is test scaffolding.)

#include <sched.h>

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.unshare(flags int) int

fn test_peer_cred_reads_a_socketpair_peer() {
	mut sv := [2]i32{} // C ints: V's int is 64-bit
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
	defer {
		close_socket(sv[0])
		close_socket(sv[1])
	}
	cred := peer_cred(sv[0]) or {
		assert false, 'peer_cred must answer on a connected AF_UNIX socket'
		return
	}
	assert cred.pid == os.getpid()
	assert cred.uid == os.geteuid()
	assert cred.gid == os.getegid()
}

// No credentials recorded means none: the kernel answers SO_PEERCRED on any
// socket, with uid = gid = (uid_t)-1 when no peer process is behind it.
fn test_peer_cred_is_none_without_kernel_credentials() ! {
	assert peer_cred(-1) == none // not a socket
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { l.close() or {} }
	mut c := net.dial_tcp(l.addr()!.str())!
	defer { c.close() or {} }
	mut s := l.accept()!
	defer { s.close() or {} }
	assert peer_cred(s.sock.handle) == none // TCP, both ends
	assert peer_cred(c.sock.handle) == none
	fd := C.socket(C.AF_UNIX, C.SOCK_STREAM, 0)
	assert fd >= 0
	defer { close_socket(fd) }
	assert peer_cred(fd) == none // AF_UNIX, but no peer yet
}

// #329: a peer in a PID namespace the receiver cannot see — a reverse proxy in
// one container, the server in another, the socket shared through a volume —
// reads as pid 0, but its uid and gid are still the kernel's.
//
// A namespace sees every descendant's pids, so it is the RECEIVER that must
// sit in a namespace the peer is not in: fork, unshare a user + PID namespace
// (the user namespace makes that unprivileged), map our ids 1:1, fork again.
// The grandchild is pid 1 of the new namespace, where this process has no pid,
// and reads peer_cred on its end of a socketpair this process created. The
// children only make syscalls (no allocation in a fork of a threaded
// process), and report [found, pid, uid, gid] back over the pair.
//
// Skips where the kernel refuses an unprivileged user namespace (Ubuntu's
// AppArmor default); VANILLA_REQUIRE_USERNS=1 makes that a failure, for the
// CI step that lifts the restriction.
fn test_peer_cred_keeps_uid_and_gid_across_a_pid_namespace() {
	mut sv := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
	uid_map := '${os.geteuid()} ${os.geteuid()} 1'
	gid_map := '${os.getegid()} ${os.getegid()} 1'
	child := C.fork()
	assert child >= 0
	if child == 0 {
		mut rec := [i32(-1), 0, 0, 0]!
		if C.unshare(C.CLONE_NEWUSER | C.CLONE_NEWPID) == 0
			&& write_proc(c'/proc/self/uid_map', uid_map)
			&& write_proc(c'/proc/self/setgroups', 'deny')
			&& write_proc(c'/proc/self/gid_map', gid_map) {
			if C.fork() == 0 {
				rec[0] = 0
				if cred := peer_cred(sv[1]) {
					rec = [i32(1), i32(cred.pid), i32(cred.uid), i32(cred.gid)]!
				}
				C.write(sv[1], &rec[0], sizeof(rec))
				C._exit(0)
			}
			C.waitpid(-1, unsafe { nil }, 0)
			C._exit(0)
		}
		C.write(sv[1], &rec[0], sizeof(rec)) // no namespace: skip
		C._exit(0)
	}
	close_socket(sv[1])
	C.waitpid(child, unsafe { nil }, 0)
	mut rec := [4]i32{}
	n := C.read(sv[0], &rec[0], sizeof(rec))
	close_socket(sv[0])
	assert n == sizeof(rec), 'no report from the namespaced reader'
	if rec[0] == -1 {
		assert os.getenv('VANILLA_REQUIRE_USERNS') != '1', 'VANILLA_REQUIRE_USERNS=1, yet no unprivileged user namespace here'
		eprintln('skip: no unprivileged user + PID namespace here')
		return
	}
	assert rec[0] == 1, 'peer_cred dropped a peer outside its PID namespace'
	assert rec[1] == 0 // the peer has no pid in the reader's namespace
	assert rec[2] == os.geteuid()
	assert rec[3] == os.getegid()
}

// write_proc writes s to a /proc file in one write(2), as id maps require.
fn write_proc(path &char, s string) bool {
	fd := C.open(path, C.O_WRONLY)
	if fd < 0 {
		return false
	}
	n := C.write(fd, s.str, usize(s.len))
	C.close(fd)
	return n == s.len
}
