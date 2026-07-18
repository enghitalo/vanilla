module socket

// Kernel-verified peer identity for unix-domain connections on macOS/BSD —
// the darwin twin of peer_cred_linux.c.v (same PeerCred shape, same
// trust-model rationale; see that file). No single SO_PEERCRED here:
// getpeereid(2) yields the effective uid/gid, and the pid comes from the
// LOCAL_PEERPID socket option (SOL_LOCAL level, <sys/un.h>).

#include <sys/un.h>

fn C.getpeereid(fd int, euid &u32, egid &u32) int
fn C.getsockopt(fd int, level int, optname int, optval voidptr, optlen &u32) int

pub struct PeerCred {
pub:
	pid int
	uid int
	gid int
}

// peer_cred returns the peer's credentials for a connected AF_UNIX socket,
// or none for non-unix sockets and errors.
pub fn peer_cred(fd int) ?PeerCred {
	mut euid := u32(0)
	mut egid := u32(0)
	if C.getpeereid(fd, &euid, &egid) != 0 {
		return none
	}
	mut pid := 0
	mut l := u32(sizeof(int))
	if C.getsockopt(fd, C.SOL_LOCAL, C.LOCAL_PEERPID, voidptr(&pid), &l) != 0 || pid <= 0 {
		return none
	}
	return PeerCred{
		pid: pid
		uid: int(euid)
		gid: int(egid)
	}
}
