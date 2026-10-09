module server

// The ONLY file that imports backend_poll on Linux (issue #122 step 4).
// Imports cannot be conditional in V, so without this flag-suffix split the
// portability reactor would be compiled into every Linux build; with it, a
// plain build never sees backend_poll, and `-d vanilla_poll` swaps this in
// for the notd stub — the same mechanism as the tls _d_vanilla_tls pair.
import server.backend_poll

fn run_poll_backend_impl(srv Server, mut threads []thread) {
	backend_poll.run_poll_backend(srv.socket_fd, srv.handler, srv.make_state,
		srv.after_server_start, srv.limits, srv.inflight, srv.active_conns, mut threads)
}
