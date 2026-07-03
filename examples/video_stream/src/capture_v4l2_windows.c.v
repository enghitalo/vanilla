module main

// V4L2 is a Linux kernel API — there is no in-process webcam capture on
// Windows. run_v4l2 reports "unavailable" (0 frames); /webcam simply won't
// stream, while the /video file route keeps working (see capture.v).
fn run_v4l2(path string, mut v Viewers) int {
	return 0
}
