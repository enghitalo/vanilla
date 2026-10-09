module socket

import time

#include <errno.h>

// accept_pause is how long an acceptor stops taking connections after
// accept() ran out of a resource (accept_starved). Clients that arrive
// meanwhile wait in the listen backlog, and the acceptor makes at most one
// failed accept() per pause.
pub const accept_pause = time.Duration(50 * time.millisecond)

// The pause notice is printed at most this often per acceptor, so a long
// shortage leaves a trace in the log without flooding it.
const accept_pause_log_every = time.Duration(10 * time.second)

// accept_starved reports whether accept() failed because the process or the
// system is out of a resource: file descriptors (EMFILE, ENFILE), socket
// buffers (ENOBUFS) or memory (ENOMEM), not because of the one connection it
// tried to take. Retrying at once cannot work and spins (issue #256): the
// connection stays in the backlog, so the listener stays readable, and on a
// full fd table Linux fails accept4() with EMFILE before it even looks at the
// backlog. The caller stops accepting for accept_pause instead. Only the
// error path calls this.
@[inline]
pub fn accept_starved(err int) bool {
	return err == C.EMFILE || err == C.ENFILE || err == C.ENOBUFS || err == C.ENOMEM
}

// note_accept_pause tells why `who` stopped accepting, at most once every 10 s.
// `next_log` is that acceptor's own rate-limit state (start it at 0); store the
// value returned in its place.
pub fn note_accept_pause(who string, err int, next_log u64) u64 {
	now := time.sys_mono_now()
	if now < next_log {
		return next_log
	}
	reason := unsafe { cstring_to_vstring(C.strerror(err)) }
	eprintln('${who} accept: ${reason} (errno ${err}). New connections wait in the backlog; retrying every ${accept_pause.milliseconds()} ms (this notice repeats at most every ${i64(accept_pause_log_every / time.second)} s).')
	return now + u64(accept_pause_log_every)
}
