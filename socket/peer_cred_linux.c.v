module socket

// Kernel-verified peer identity for unix-domain connections (LOCAL_IPC §6,
// issue #122): SO_PEERCRED returns the pid/uid/gid the peer held when it
// connect()ed — credentials the kernel recorded, not headers the client
// claims. The trust model this completes: filesystem permissions on the
// socket path decide WHO MAY CONNECT; peer_cred tells the handler WHO EACH
// CONNECTION IS (per-uid authorization, audit, rate limits by caller).
// Sits next to peer_addr, same contract: call it from a handler only when
// identity is needed — one getsockopt syscall, nothing otherwise.

// struct ucred is glibc's __USE_GNU surface.
#flag -D_GNU_SOURCE

struct C.ucred {
	pid int
	uid u32
	gid u32
}

fn C.getsockopt(fd int, level int, optname int, optval voidptr, optlen &u32) int

// PeerCred is the kernel-recorded identity of a unix-socket peer, captured
// at connect() time (a peer that later drops privileges keeps the original
// credentials here — that is the semantics SO_PEERCRED defines).
pub struct PeerCred {
pub:
	pid int
	uid int
	gid int
}

// peer_cred returns the peer's credentials for a connected AF_UNIX socket,
// or none for non-unix sockets and errors. `client_fd` is the handler's
// parameter — accepted UDS connections on every backend qualify.
pub fn peer_cred(fd int) ?PeerCred {
	mut cred := C.ucred{}
	mut l := u32(sizeof(C.ucred))
	if C.getsockopt(fd, C.SOL_SOCKET, C.SO_PEERCRED, voidptr(&cred), &l) != 0 {
		return none
	}
	// On a non-AF_UNIX socket Linux answers the call but with no peer
	// process behind it (pid 0 / overflow ids) — surface that as "no
	// credentials", never as a real identity.
	if cred.pid <= 0 {
		return none
	}
	return PeerCred{
		pid: cred.pid
		uid: int(cred.uid)
		gid: int(cred.gid)
	}
}
