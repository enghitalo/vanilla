module main

import http_server
import runtime

// ServerConfig.workers sizes each server's worker pool independently. new_server
// allocates the per-worker thread / in-flight-counter / io_uring-listener arrays
// from it WITHOUT spawning any threads (run() later spawns exactly threads.len
// workers, and each backend derives its count from threads.len). So asserting the
// public array lengths verifies the knob end-to-end, deterministically — no
// sleeps, no real server to start or stop, nothing that can hang CI.

fn noop_handler(req_buffer []u8, _ int, mut out []u8) ! {}

// workers:N is honored, and two co-hosted servers size their pools independently.
fn test_workers_override_sizes_pools_independently() {
	$if linux {
		mut a := http_server.new_server(http_server.ServerConfig{
			port:            18181
			io_multiplexing: .epoll
			workers:         5
			request_handler: noop_handler
		}) or { panic(err) }
		assert a.threads.len == 5
		assert a.inflight.len == 5

		mut b := http_server.new_server(http_server.ServerConfig{
			port:            18182
			io_multiplexing: .epoll
			workers:         9
			request_handler: noop_handler
		}) or { panic(err) }
		assert b.threads.len == 9
		assert b.inflight.len == 9
	}
}

// workers unset (0) falls back to the process default (nr_cpus, unless
// $VANILLA_WORKERS is set — CI does not set it).
fn test_workers_zero_falls_back_to_default() {
	$if linux {
		mut s := http_server.new_server(http_server.ServerConfig{
			port:            18183
			io_multiplexing: .epoll
			request_handler: noop_handler
		}) or { panic(err) }
		assert s.threads.len == runtime.nr_cpus()
		assert s.inflight.len == runtime.nr_cpus()
	}
}

// io_uring is shared-nothing: workers:N creates N SO_REUSEPORT listeners (one per
// worker) in addition to sizing the thread array.
fn test_workers_io_uring_one_listener_per_worker() {
	$if linux {
		mut s := http_server.new_server(http_server.ServerConfig{
			port:            18184
			io_multiplexing: .io_uring
			workers:         6
			request_handler: noop_handler
		}) or { panic(err) }
		assert s.threads.len == 6
		assert s.listener_fds.len == 6
	}
}
