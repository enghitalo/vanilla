module core

// V interface to the per-thread sendfile hand-off slot (see sendfile_slot.h).
//
// This is the backend-agnostic bridge that lets a pure `(req, fd, out)` handler
// ask the running worker to emit a file body with sendfile(2) instead of
// copying it through the response buffer. Only a sendfile-capable worker (the
// epoll plain and TLS workers) calls enable_sendfile(); everywhere else
// queue_file() returns false and the caller writes the bytes itself, so this is
// a no-op on other backends and non-Linux OSes.
//
// A worker that can sendfile on some connections but not others narrows the
// hand-off per request with set_queue_file_allowed(): the epoll TLS worker,
// where sendfile(2) writes plaintext that only a kernel-TLS socket encrypts,
// passes false for a userspace-TLS connection. The plain worker only closes it
// around a watch continuation, whose region it would never take.

#include "@VMODROOT/core/sendfile_slot.h"

fn C.vanilla_sf_enable()
fn C.vanilla_sf_set_allowed(allowed bool)
fn C.vanilla_sf_queue(file_fd int, off i64, len i64) bool
fn C.vanilla_sf_take(out_fd &int, out_off &i64, out_len &i64) bool

// QueuedFile is a borrowed file region a worker should send after the headers
// already appended to the write buffer. The fd is NOT owned by the worker.
pub struct QueuedFile {
pub:
	file_fd int
	off     i64
	len     i64
}

// enable_sendfile marks the calling worker thread as able to consume a queued
// file via sendfile(2). Call once per capable worker (the epoll plain and TLS
// workers). It also allows every request until set_queue_file_allowed says
// otherwise.
@[inline]
pub fn enable_sendfile() {
	C.vanilla_sf_enable()
}

// set_queue_file_allowed gates queue_file for the call about to run, on a
// worker that called enable_sendfile. Call it before every handler call, with
// false for a connection the worker cannot sendfile to (a userspace-TLS
// connection), or false around a call whose queued region the worker never
// takes (the epoll worker's watch continuations), then true again. A no-op on
// a worker that never enabled sendfile, and under tcc.
@[inline]
pub fn set_queue_file_allowed(allowed bool) {
	C.vanilla_sf_set_allowed(allowed)
}

// queue_file hands a file region to the current worker, to be sent right after
// the bytes the handler appended to `out`. Returns false when the running
// backend can't sendfile (a worker that never enabled it, a connection it is
// not allowed on, a non-epoll backend, or a non-Linux OS) — the caller MUST
// then write the body bytes itself (on POSIX, core.append_file_region reads
// them into `out` without allocating). The epoll workers drain the slot after
// every core.Handler call (a pipelined request, or the head of a streamed
// large body), whatever the step: a region queued by a step that returns
// .suspend is dropped, and one queued by a step that returns .close is still
// sent after the bytes appended to `out`, best-effort like the rest of that
// response: one flush, then the close, so what goes out is bounded by the
// socket send buffer. A streamed-body head the worker rejects (any step but
// .done) has its region dropped, and the worker's 400 follows whatever the
// handler appended. Watch continuations cannot queue a file: queue_file
// returns false while one runs, so a continuation writes its body itself. The
// fd must stay open and is never closed by the worker (assets keep one fd open
// for their whole life; sendfile() with an explicit offset never touches the
// fd's own position, so the same fd is safe to send concurrently from many
// connections/threads).
@[inline]
pub fn queue_file(file_fd int, off i64, len i64) bool {
	return C.vanilla_sf_queue(file_fd, off, len)
}

// take_queued_file returns the file region a handler queued during the request
// just handled, or none. Always clears the slot, so it never leaks into the
// next request.
@[inline]
pub fn take_queued_file() ?QueuedFile {
	mut fd := 0
	mut off := i64(0)
	mut len := i64(0)
	if C.vanilla_sf_take(&fd, &off, &len) {
		return QueuedFile{
			file_fd: fd
			off:     off
			len:     len
		}
	}
	return none
}
