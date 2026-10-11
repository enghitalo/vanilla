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

// The notices are whole lines built once, at startup: printing one allocates
// nothing (the epoll build runs with -gc none, where nothing is ever freed) and
// calls no strerror, which is not thread-safe while workers may log at once.
// The tail quotes accept_pause and accept_pause_log_every: keep them in step.
const accept_pause_tail = ' New connections wait in the listen backlog; accepting pauses 50 ms at a time while this lasts (noted at most every 10 s per acceptor).'
const accept_emfile_note = '[vanilla] accept: EMFILE, the process is out of file descriptors (RLIMIT_NOFILE).' +
	accept_pause_tail
const accept_enfile_note = '[vanilla] accept: ENFILE, the system is out of file descriptors.' +
	accept_pause_tail
const accept_enobufs_note = '[vanilla] accept: ENOBUFS, out of socket buffer memory.' +
	accept_pause_tail
const accept_enomem_note = '[vanilla] accept: ENOMEM, out of memory.' + accept_pause_tail

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

// listener_gone reports whether accept() failed because the listener itself
// is gone: its number was closed (EBADF), or names a file that is not a
// socket (ENOTSOCK) or a socket that is not listening (EINVAL: a TCP listener
// that was shut down, or whatever reused the number). A live listener never
// fails this way, so no retry can succeed: the acceptor stops instead.
// Server.shutdown() closes the listener from another thread, so an acceptor
// woken just before can call accept() after the close, and retrying at once
// spun it at full CPU for the rest of the process (#163). Only the error path
// calls this.
@[inline]
pub fn listener_gone(err int) bool {
	return err == C.EBADF || err == C.ENOTSOCK || err == C.EINVAL
}

// note_accept_pause tells why an acceptor stopped accepting, at most once
// every 10 s. `next_log` is that acceptor's own rate-limit state (start it at
// 0); store the value returned in its place.
pub fn note_accept_pause(err int, next_log u64) u64 {
	now := time.sys_mono_now()
	if now < next_log {
		return next_log
	}
	eprintln(if err == C.EMFILE {
		accept_emfile_note
	} else if err == C.ENFILE {
		accept_enfile_note
	} else if err == C.ENOBUFS {
		accept_enobufs_note
	} else {
		accept_enomem_note
	})
	return now + u64(accept_pause_log_every)
}
