module main

// In-process webcam capture via V4L2 — the most efficient frame source: no
// ffmpeg subprocess, no pipe, no transcode. The kernel fills mmap'd DMA buffers
// with the camera's native MJPEG and we copy each frame ONCE before handing the
// buffer back to the driver. See vcam.c / vcam.h for the V4L2 ioctl plumbing.

#flag -I@VMODROOT/examples/video_stream/src
#flag @VMODROOT/examples/video_stream/src/vcam.c
#include "vcam.h"

fn C.vcam_open(path &char, width int, height int) voidptr
fn C.vcam_next(c voidptr) int
fn C.vcam_ptr(c voidptr) &u8
fn C.vcam_done(c voidptr)
fn C.vcam_close(c voidptr)

// run_v4l2 streams frames straight from the camera until it errors/stops.
// Returns the number of frames broadcast (0 ⇒ unavailable, the caller logs
// that /webcam won't stream and gives up — there is deliberately no ffmpeg
// fallback, see the README).
fn run_v4l2(path string, mut v Viewers) int {
	cam := C.vcam_open(&char(path.str), 640, 480)
	if isnil(cam) {
		return 0 // no device, or no MJPEG mode
	}
	eprintln('[webcam] capturing via V4L2 in-process (no ffmpeg, zero-copy mmap)')
	mut frames := 0
	// ONE frame buffer + ONE header scratch, reused for every frame (grown to
	// the high-water JPEG size instead of a fresh zeroed alloc per frame,
	// BEST_PRACTICES §4). Reuse is safe: broadcast_frame completes synchronously
	// below, before the buffer is refilled — this thread is the only writer.
	mut frame := []u8{cap: 256 * 1024}
	mut scratch := []u8{cap: part_prefix.len + 32}
	for {
		n := C.vcam_next(cam)
		if n <= 0 {
			break
		}
		// Copy the JPEG out of the mmap'd buffer, then immediately return the
		// buffer to the driver so it can be refilled while we broadcast.
		src := C.vcam_ptr(cam)
		frame.ensure_cap(n)
		unsafe {
			frame.len = n // spare capacity is about to be overwritten
			vmemcpy(frame.data, src, n)
		}
		C.vcam_done(cam)
		v.broadcast_frame(frame, mut scratch)
		frames++
	}
	C.vcam_close(cam)
	return frames
}
