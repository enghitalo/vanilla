module core

// V interface to the per-thread sendfile hand-off slot (see sendfile_slot.h).
//
// This is the backend-agnostic bridge that lets a pure `(req, fd, out)` handler
// ask the running worker to emit a file body with sendfile(2) instead of
// copying it through the response buffer. Only a sendfile-capable worker (the
// epoll plain worker) calls enable_sendfile(); everywhere else queue_file()
// returns false and the caller writes the bytes itself, so this is a no-op on
// TLS, other backends, and non-Linux OSes.

#include "@VMODROOT/http_server/core/sendfile_slot.h"

fn C.vanilla_sf_enable()
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
// file via sendfile(2). Call once per capable worker (the epoll plain worker).
@[inline]
pub fn enable_sendfile() {
	C.vanilla_sf_enable()
}

// queue_file hands a file region to the current worker, to be sent right after
// the bytes the handler appended to `out`. Returns false when the running
// backend can't sendfile (TLS, a non-epoll backend, or a non-Linux OS) — the
// caller MUST then write the body bytes itself. The fd must stay open and is
// never closed by the worker (assets keep one fd open for their whole life;
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
