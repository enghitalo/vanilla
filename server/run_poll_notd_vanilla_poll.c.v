module server

// notd twin of run_poll_d_vanilla_poll.c.v: keeps the `.poll` match arm
// linkable in builds without `-d vanilla_poll`. Unreachable in practice —
// new_server rejects `.poll` at config time when the flag is off.
fn run_poll_backend_impl(srv Server, mut threads []thread) {
	eprintln('the poll backend requires building with `-d vanilla_poll`')
	exit(1)
}
