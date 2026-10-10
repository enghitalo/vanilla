module server

import core
import server.backend_epoll

// Backend selection
pub enum IOBackend {
	epoll    = 0 // Linux only
	io_uring = 1 // Linux only
	// The pure-POSIX poll(2) portability floor (QNX/VxWorks tier). Compiled
	// on Linux ONLY under `-d vanilla_poll` (new_server rejects it otherwise)
	// so CI can exercise the RTOS reactor at zero cost to normal builds.
	poll     = 2
}

// run_selected_backend dispatches to the configured Linux backend. Defined per
// OS (here, darwin, windows) so the all-platform facade (server.c.v) needs
// no platform-specific backend import. Blocks in the accept loop.
fn run_selected_backend(srv Server, mut threads []thread) {
	match srv.io_multiplexing {
		.epoll {
			backend_epoll.run_epoll_backend(srv.socket_fd, srv.handler, srv.make_state,
				srv.on_worker_start, srv.after_server_start, srv.port, srv.limits, srv.inflight,
				srv.active_conns, srv.tls_config, srv.mailboxes, srv.push_watermark, mut threads)
		}
		.io_uring {
			run_io_uring_backend(srv, mut threads)
		}
		.poll {
			// Implemented in run_poll_d_vanilla_poll.c.v; the notd twin stub
			// keeps this arm linkable when the flag is off (new_server already
			// rejected the config by then).
			run_poll_backend_impl(srv, mut threads)
		}
	}
}

pub fn (mut srv Server) run() {
	run_selected_backend(srv, mut srv.threads)
}

// new_push_mailboxes builds one push mailbox per epoll plain worker
// (ServerConfig.push_mailbox_slots, vanilla#230).
fn new_push_mailboxes(workers int, slots int) []voidptr {
	mut out := []voidptr{cap: workers}
	for _ in 0 .. workers {
		out << backend_epoll.new_mailbox(slots)
	}
	return out
}

// signal_push_shutdown tells every worker with a mailbox to deliver .shutdown
// to its subscribed connections; each holds one count of its in-flight
// counter until it has.
fn signal_push_shutdown(mailboxes []voidptr, inflight []&core.Counter) {
	for i, m in mailboxes {
		if i < inflight.len {
			backend_epoll.mailbox_signal_shutdown(m, inflight[i])
		}
	}
}

fn push_stats_linux(mailboxes []voidptr) PushStats {
	mut posted, mut full, mut delivered, mut stale := u64(0), u64(0), u64(0), u64(0)
	for m in mailboxes {
		p, f, d, st := backend_epoll.mailbox_counters(m)
		posted += p
		full += f
		delivered += d
		stale += st
	}
	return PushStats{
		posted:    posted
		full:      full
		delivered: delivered
		stale:     stale
	}
}
