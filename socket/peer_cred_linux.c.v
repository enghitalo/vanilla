module socket

// Kernel-verified peer identity for unix-domain connections (LOCAL_IPC §6,
// issue #122): SO_PEERCRED returns the pid/uid/gid the peer held when it
// connect()ed — credentials the kernel recorded, not headers the client
// claims. The trust model this completes: filesystem permissions on the
// socket path decide WHO MAY CONNECT; peer_cred tells the handler WHO EACH
// CONNECTION IS (per-uid authorization, audit, rate limits by caller).
// Sits next to peer_ipv4, same contract: call it from a handler only when
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
// credentials here — that is the semantics SO_PEERCRED defines). The kernel
// translates the ids into the reader's namespaces: `pid` is 0 when the peer
// runs in a PID namespace this process cannot see (a proxy in another
// container sharing the socket through a volume, #329) — uid and gid are
// still the kernel's — and an id with no mapping in this user namespace reads
// as the overflow id (65534, /proc/sys/kernel/overflowuid). Every unmapped
// peer shares that id, so it names no one: never grant access to it.
pub struct PeerCred {
pub:
	pid int
	uid int
	gid int
}

// peer_cred returns the peer's credentials for a connected AF_UNIX socket,
// or none when the kernel recorded none (a non-unix socket, a unix socket
// with no peer) and on errors. `client_fd` is the handler's
// parameter — accepted UDS connections on every backend qualify.
pub fn peer_cred(fd int) ?PeerCred {
	mut cred := C.ucred{}
	mut l := u32(sizeof(C.ucred))
	if C.getsockopt(fd, C.SOL_SOCKET, C.SO_PEERCRED, voidptr(&cred), &l) != 0 {
		return none
	}
	// Linux answers SO_PEERCRED on any socket; uid = gid = (uid_t)-1 is its
	// "no credentials recorded" (cred_to_ucred): TCP, a unix socket with no
	// peer. No real id reads as -1, so this needs no second syscall to ask
	// the family. Not the pid: it is 0 for a real peer outside this PID
	// namespace (#329).
	if cred.uid == max_u32 {
		return none
	}
	return PeerCred{
		pid: cred.pid
		uid: int(cred.uid)
		gid: int(cred.gid)
	}
}
