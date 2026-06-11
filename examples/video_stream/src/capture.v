module main

// Live webcam stream — the PUSH model: motion-JPEG over
// `multipart/x-mixed-replace`. The server pushes frames forever; the browser
// renders them with a plain `<img src="/webcam">`.
//
// The design mirrors the SSE example's: a viewer is just an fd already living in
// the server's epoll set. We never spawn a thread per viewer. ONE capture thread
// reads frames from the camera and fans each one out to every viewer fd. Cost
// per viewer: one fd + one map entry.
//
// Frames come straight from the kernel via V4L2 (see capture_v4l2.c.v / vcam.c):
// no ffmpeg subprocess, no pipe, no transcode. Each V4L2 buffer already holds one
// complete JPEG, so there is nothing to parse — we broadcast it as-is.
import sync
import time

#include <errno.h>

fn C.send(fd int, buf voidptr, n usize, flags int) int

// msg_nosignal returns MSG_NOSIGNAL on Linux: a dead viewer must not raise
// SIGPIPE — we detect it from send(). macOS has no such flag; SIGPIPE is
// suppressed per-socket via SO_NOSIGPIPE, set at accept.
@[inline]
fn msg_nosignal() int {
	$if linux {
		return 0x4000
	}
	return 0
}

// multipart part boundary (must match the Content-Type sent to the client).
const boundary = 'vanillaframe'

// Viewers is the only shared state: the set of fds currently watching /webcam,
// plus a one-shot flag so the capture thread starts on the first viewer (the
// camera isn't even opened until someone watches).
struct Viewers {
mut:
	mu      &sync.RwMutex = sync.new_rwmutex()
	fds     map[int]bool
	started bool
}

fn (mut v Viewers) add(fd int) {
	v.mu.lock()
	v.fds[fd] = true
	v.mu.unlock()
}

fn (mut v Viewers) drop(fd int) {
	v.mu.lock()
	v.fds.delete(fd)
	v.mu.unlock()
}

fn (mut v Viewers) snapshot() []int {
	v.mu.rlock()
	fds := v.fds.keys()
	v.mu.runlock()
	return fds
}

// ensure_capture spawns the single capture+broadcast thread exactly once, on the
// first viewer. Lazy: the camera isn't opened until someone watches /webcam.
fn (mut v Viewers) ensure_capture() {
	v.mu.lock()
	first := !v.started
	v.started = true
	v.mu.unlock()
	if first {
		spawn capture_loop(mut v)
	}
}

// capture_loop streams the camera straight to viewers via V4L2 until it stops
// (camera unplugged) or fails to open (no MJPEG-capable camera). The /video file
// stream is independent and works regardless.
fn capture_loop(mut v Viewers) {
	if run_v4l2('/dev/video0', mut v) == 0 {
		eprintln('[webcam] no MJPEG camera at /dev/video0 — /webcam will not stream (the /video file stream is unaffected)')
	}
	eprintln('[webcam] capture ended')
}

// broadcast_frame writes one multipart part (headers + JPEG + CRLF) to every
// viewer, dropping any that can't keep up or have disconnected.
fn (mut v Viewers) broadcast_frame(jpeg []u8) {
	part_header :=
		'--${boundary}\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.len}\r\n\r\n'.bytes()
	part_trailer := '\r\n'.bytes()
	for fd in v.snapshot() {
		if !send_all(fd, part_header) || !send_all(fd, jpeg) || !send_all(fd, part_trailer) {
			v.drop(fd)
		}
	}
}

// send_all writes the whole buffer to a non-blocking socket, tolerating partial
// writes and brief back-pressure. A viewer that stays full too long is reported
// as failed (the caller drops it) — live video favors fresh frames over a
// backlog, and one slow viewer must not stall the single capture thread for long.
fn send_all(fd int, data []u8) bool {
	mut off := 0
	mut stalls := 0
	for off < data.len {
		n := C.send(fd, unsafe { &u8(data.data) + off }, usize(data.len - off), msg_nosignal())
		if n > 0 {
			off += n
			stalls = 0
			continue
		}
		if n < 0 && (C.errno == C.EAGAIN || C.errno == C.EWOULDBLOCK) {
			stalls++
			if stalls > 50 {
				return false // ~50 ms of back-pressure: this viewer is too slow
			}
			time.sleep(time.millisecond)
			continue
		}
		return false // hard error (peer gone)
	}
	return true
}
