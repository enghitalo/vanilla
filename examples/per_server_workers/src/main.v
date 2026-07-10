module main

// Per-server worker pools — `ServerConfig.workers`.
//
// By default EVERY server in a process runs `nr_cpus` worker threads (or
// `$VANILLA_WORKERS`). When you co-host more than one server in a single process
// that double-subscribes the cores (2 servers × nr_cpus threads). `workers` lets
// you size each server's pool independently so the total stays ≈ nr_cpus: here a
// main API server keeps most of the cores and a small secondary (admin/metrics)
// server gets a couple. `workers: 0` (the default) keeps the nr_cpus behavior.
//
// The field's meaning is uniform across backends (count of worker threads); the
// topology differs — epoll runs one central acceptor + `workers` epoll loops,
// io_uring runs `workers` shared-nothing rings (one SO_REUSEPORT listener each).
import http_server
import http_server.core
import runtime

fn api_handler(req_buffer []u8, mut out []u8, mut worker core.Worker) core.Step {
	out << 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\nmain'.bytes()
	return .done
}

fn admin_handler(req_buffer []u8, mut out []u8, mut worker core.Worker) core.Step {
	out << 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nadmin'.bytes()
	return .done
}

fn main() {
	// Backend chosen per-OS; this example targets the Linux epoll backend.
	mut backend := unsafe { http_server.IOBackend(0) }
	$if linux {
		backend = http_server.IOBackend.epoll
	} $else {
		eprintln('per_server_workers: this example targets the Linux epoll backend')
		return
	}

	cpus := runtime.nr_cpus()
	// Give the secondary server a small pool; the main server takes the rest, so
	// the two pools together are ≈ nr_cpus instead of 2 × nr_cpus.
	admin_workers := if cpus >= 4 { 2 } else { 1 }
	main_workers := if cpus - admin_workers >= 1 { cpus - admin_workers } else { 1 }

	// Secondary (admin) server on :8081 with a small pool, in its own thread.
	mut admin := http_server.new_server(http_server.ServerConfig{
		port:            8081
		io_multiplexing: backend
		workers:         admin_workers
		handler:         admin_handler
	})!
	spawn fn [admin] () {
		mut s := admin
		s.run()
	}()

	// Main API server on :8080 with the remaining cores.
	mut api := http_server.new_server(http_server.ServerConfig{
		port:            8080
		io_multiplexing: backend
		workers:         main_workers
		handler:         api_handler
	})!
	println('per-server workers: api :8080 = ${main_workers}, admin :8081 = ${admin_workers} (nr_cpus=${cpus})')
	api.run()
}
