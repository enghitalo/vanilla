module core

// V interface to the per-thread sendfile hand-off slot (see sendfile_slot.h).
//
// This is the backend-agnostic bridge that lets a pure `(req, fd, out)` handler
// ask the running worker to emit a file body with sendfile(2) instead of
// copying it through the response buffer. Only a sendfile-capable worker (the
// epoll worker) calls enable_sendfile(); everywhere else queue_file() returns
// false and the caller writes the bytes itself, so this is a no-op on other
// backends and non-Linux OSes. The epoll worker takes a region on every
// connection: a plain or kernel-TLS one gets it with sendfile(2), a
// userspace-TLS one (where sendfile would write plaintext) as bytes, read and
// encrypted a chunk at a time.
//
// The epoll worker closes the hand-off with set_queue_file_allowed() around a
// call whose region it would never take: a watch continuation, a wake fn or a
// ConnHandler.

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
// file via sendfile(2). Call once per capable worker (the epoll worker). It
// also allows every request until set_queue_file_allowed says otherwise.
@[inline]
pub fn enable_sendfile() {
	C.vanilla_sf_enable()
}

// set_queue_file_allowed gates queue_file for the call about to run, on a
// worker that called enable_sendfile: false around a call whose queued region
// the worker never takes (the epoll worker's watch continuations, wake fns
// and ConnHandlers), then true again. A no-op on a worker that never enabled
// sendfile, and under tcc.
@[inline]
pub fn set_queue_file_allowed(allowed bool) {
	C.vanilla_sf_set_allowed(allowed)
}

// queue_file hands a file region to the current worker, to be sent right after
// the bytes the handler appended to `out`. Returns false when the running
// backend can't take it (a worker that never enabled it, a call it is not
// allowed in, a non-epoll backend, or a non-Linux OS) — the caller MUST then
// write the body bytes itself (on POSIX, core.append_file_region reads them
// into `out` without allocating). The epoll worker takes it on plain HTTP and
// on HTTPS alike: sendfile(2) on a plain or kernel-TLS connection, and on a
// userspace-TLS one the file read and sent through Mbed TLS a chunk at a time.
// It drains the slot after every core.Handler call (a
// pipelined request, or the head of a streamed large body), whatever the step:
// a region queued by a step that returns .suspend is dropped, and one queued
// by a step that returns .close is still sent after the bytes appended to
// `out`, the connection closing once all of it is out. A streamed-body head
// the worker rejects (any step but .done) has its region dropped, and the
// worker's 400 follows whatever the handler appended. Watch continuations, wake fns and ConnHandlers
// (core.ConnHandler) cannot queue a file: queue_file returns false while one
// runs, so it writes its bytes itself. The fd must stay open and is never
// closed by the worker (assets keep one fd open for their whole life;
// sendfile() with an explicit offset never touches the fd's own position, so
// the same fd is safe to send concurrently from many connections/threads).
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
