module server

// notd twin of server_io_uring_d_vanilla_io_uring.c.v (issue #189): a build
// without `-d vanilla_io_uring` compiles no io_uring code, so it needs neither
// the liburing headers nor liburing.so.2. Compiled on EVERY OS without the
// flag (a define suffix overrides V's OS suffixes), which makes this the one
// iou_backend_available for darwin/windows too.

// iou_backend_available is false: the io_uring backend is not built in (or the
// OS has none). Tests use it to skip their io_uring cases.
pub fn iou_backend_available() bool {
	return false
}

// Keeps the `.io_uring` match arm in server_linux.c.v linkable. Unreachable in
// practice — new_server rejects `.io_uring` at config time when the flag is off.
pub fn run_io_uring_backend(srv Server, mut threads []thread) {
	eprintln('the io_uring backend requires building with `-d vanilla_io_uring`')
	exit(1)
}
