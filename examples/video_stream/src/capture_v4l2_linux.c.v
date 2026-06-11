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
// Returns the number of frames broadcast (0 ⇒ unavailable, caller falls back).
fn run_v4l2(path string, mut v Viewers) int {
	cam := C.vcam_open(&char(path.str), 640, 480)
	if isnil(cam) {
		return 0 // no device, or no MJPEG mode — let the caller try ffmpeg
	}
	eprintln('[webcam] capturing via V4L2 in-process (no ffmpeg, zero-copy mmap)')
	mut frames := 0
	for {
		n := C.vcam_next(cam)
		if n <= 0 {
			break
		}
		// Copy the JPEG out of the mmap'd buffer, then immediately return the
		// buffer to the driver so it can be refilled while we broadcast.
		src := C.vcam_ptr(cam)
		mut frame := []u8{len: n}
		unsafe { vmemcpy(frame.data, src, n) }
		C.vcam_done(cam)
		v.broadcast_frame(frame)
		frames++
	}
	C.vcam_close(cam)
	return frames
}
