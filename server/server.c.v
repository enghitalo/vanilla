module server

import socket
import time
import sync.stdatomic
import core
import tls

const max_thread_pool_size = core.max_thread_pool_size

// Limits is re-exported from `core` so the public config API stays ergonomic
// (`server.Limits{...}`). The real definition lives in `core` because the
// backend reads it too, and `core` is the leaf both sides depend on.
pub type Limits = core.Limits

pub struct Server {
pub:
	port            int       = 3000
	io_multiplexing IOBackend = unsafe { IOBackend(0) }
	socket_fd       int
	limits          Limits
	tls_config      &tls.Config = unsafe { nil } // nil ⇒ plain HTTP; set ⇒ HTTPS
	// Non-empty ⇒ the listener is an AF_UNIX stream socket at this filesystem
	// path (issue #122 §5) and `port` is meaningless. shutdown() uses it for
	// the io_uring wake poke and to unlink the socket file.
	unix_socket_path string
pub mut:
	threads []thread     = []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	handler core.Handler = unsafe { nil }
	// Optional per-worker state; see ServerConfig. make_state runs once per worker
	// thread, its result reaches every handler call as the worker_state parameter.
	make_state      fn () voidptr      = unsafe { nil }
	on_worker_start core.WorkerStartFn = unsafe { nil }
	// Runs ONCE on the main thread the instant the server is accepting (all
	// listeners bound + workers spawned), right before run() blocks. See
	// ServerConfig.after_server_start / core.AfterStartFn.
	after_server_start core.AfterStartFn = unsafe { nil }
	// Per-worker in-flight request counters (one per worker, each on its own
	// cache line — written only by its worker, so no contention/false sharing).
	// shutdown() sums them to drain precisely.
	inflight []&core.Counter = []&core.Counter{len: max_thread_pool_size, init: &core.Counter{}}
	// Global count of open connections (incremented at accept, decremented at
	// close) — enforces max_connections. Touched per CONNECTION, not per request.
	active_conns &core.Counter = &core.Counter{}
	// Every listening socket the server accepts on. epoll uses one (socket_fd); the
	// io_uring backend uses one SO_REUSEPORT listener per worker, all created up
	// front in new_server so shutdown() can stop them ALL (not just worker 0's).
	listener_fds []int
	// Shared shutdown flag: shutdown() sets it so the io_uring accept handlers stop
	// re-arming and the workers quit accepting. Unused by the epoll backend (which
	// stops accepting when its single listener is closed).
	draining &core.Counter = &core.Counter{}
}

// shutdown performs a graceful stop: it stops every listener so the kernel
// refuses NEW connections, then waits up to `grace_ms` for in-flight request
// handling to finish before the caller exits the process.
//
// It works for BOTH backends. epoll accepts on one listener (socket_fd); the
// io_uring backend accepts on one SO_REUSEPORT listener per worker (all in
// listener_fds). We set the shared `draining` flag — so io_uring accept handlers
// stop re-arming — and shutdown(SHUT_RDWR) every listener (close() alone would
// not cancel an io_uring multishot accept, which holds its own file reference).
//
// The drain is PRECISE: it sums the per-worker in-flight counters and returns
// the instant they all hit zero, so an idle server shuts down in ~milliseconds
// rather than waiting the whole grace. The counters are per-worker and each on
// its own cache line, so the per-request increment is uncontended and free on
// the hot path (measured: no throughput change). Idle keep-alive connections
// hold no in-flight work, so they're simply dropped on exit.
//
// Call it from a signal handler, then `exit(0)`. It is safe to call from another
// thread while `run()` is blocked: stopping the listeners halts new accepts;
// existing workers finish their current request.
pub fn (s Server) shutdown(grace_ms int) {
	// Tell the io_uring accept handlers to stop re-arming BEFORE the listeners are
	// shut, so the resulting accept-error completion already observes the flag.
	stdatomic.store_i64(&s.draining.n, 1)
	// UDS + io_uring wake poke (issue #122 §5): shutdown(2) on an AF_UNIX
	// listener produces NO CQE for armed multishot accepts (unlike TCP), so a
	// parked worker would never observe `draining`. Wake each worker with a
	// dummy connect BEFORE the listeners are shut (afterwards connect() fails
	// and still generates no CQE): every armed accept completes with the dummy
	// connection, whose handler sees the flag and stops re-arming.
	$if linux {
		if s.unix_socket_path != '' && s.io_multiplexing == .io_uring {
			for _ in 0 .. s.inflight.len {
				fd := socket.connect_to_unix_server(s.unix_socket_path) or { continue }
				socket.close_socket(fd)
			}
		}
	}
	if s.listener_fds.len > 0 {
		for fd in s.listener_fds {
			if fd >= 0 {
				socket.shutdown_socket(fd)
			}
		}
	} else {
		// Server built without new_server (defensive): fall back to the one fd.
		socket.shutdown_socket(s.socket_fd)
	}
	// Precise drain: poll the per-worker in-flight counters and return as soon
	// as they all reach zero (or the grace deadline elapses). An idle server
	// shuts down in ~1 ms instead of waiting the full grace.
	mut waited := 0
	for waited < grace_ms {
		mut active := i64(0)
		for c in s.inflight {
			active += stdatomic.load_i64(&c.n)
		}
		if active == 0 {
			break
		}
		time.sleep(time.millisecond)
		waited++
	}
	// The socket file outlives the process unless removed; clean it up so the
	// path is free for the next run (create_unix_server_socket also unlinks a
	// stale one defensively).
	$if !windows {
		if s.unix_socket_path != '' {
			socket.unlink_socket_path(s.unix_socket_path)
		}
	}
}

pub struct Certificates {
pub:
	cert_pem    []u8
	key_pem     []u8
	ca_cert_pem []u8
}

pub struct ServerConfig {
pub:
	port            int       = 3000
	io_multiplexing IOBackend = unsafe { IOBackend(0) }
	// unix_socket_path, when set, makes the server listen on an AF_UNIX stream
	// socket at this filesystem path INSTEAD of TCP (`port` is then ignored;
	// max length socket.max_unix_path). Local IPC: ≈3× lower RTT than TCP
	// loopback, filesystem permissions as access control. Works on the epoll,
	// io_uring (single shared listener across workers — no SO_REUSEPORT for
	// UDS) and kqueue backends; not on Windows/IOCP.
	unix_socket_path string
	// handler is THE request handler — one contract for every use case, with
	// every input as an explicit parameter (see core.Handler): it appends the
	// raw response to `response` and returns .done, parks the request on an fd
	// via event_loop.watch_fd(...) and returns .suspend (DB sockets, upstreams,
	// timers — Linux epoll/io_uring and macOS/kqueue), or returns .close to
	// flush-and-drop the connection.
	handler core.Handler = unsafe { nil }
	// make_state opts into lock-free per-worker state: each worker calls
	// make_state ONCE (so the value is thread-local), then every handler call on
	// that worker receives it as the worker_state parameter. Used to give each
	// worker its own DB connection / reused render scratch — no shared pool, no
	// mutex.
	make_state fn () voidptr = unsafe { nil }
	// on_worker_start runs once per worker (after make_state, before the loop) to
	// arm CLIENTLESS background watches — e.g. a periodic timerfd that refreshes
	// per-worker state with no shared state and no extra thread. Linux/epoll
	// only. See core.WorkerStartFn.
	on_worker_start core.WorkerStartFn = unsafe { nil }
	// after_server_start runs ONCE on the main thread the moment the server is
	// accepting connections (all listeners bound + listening, workers spawned),
	// right before run() blocks in its accept loop. A single process-level
	// lifecycle hook that works on EVERY backend (unlike on_worker_start). Use it
	// to log readiness, register in service discovery, write a PID/ready file,
	// notify a supervisor, or signal a channel in tests. See core.AfterStartFn.
	after_server_start core.AfterStartFn = unsafe { nil }
	certificates       Certificates
	limits             Limits
	tls_config         &tls.Config = unsafe { nil } // set for HTTPS (e.g. tls.new_self_signed())
	// workers sets how many worker threads THIS server runs. 0 (default) =
	// `VANILLA_WORKERS` env → `runtime.nr_cpus()` (the process-wide default). Set it
	// PER server instance when co-hosting two servers in one process so their worker
	// threads don't oversubscribe the cores: e.g. give the high-traffic plaintext
	// server most cores and a co-hosted TLS/secondary server a small pool, keeping
	// the total ≈ nr_cpus. The meaning is uniform across backends (count of worker
	// threads); the topology differs — epoll runs a central acceptor + `workers`
	// epoll loops, io_uring runs `workers` shared-nothing rings (one SO_REUSEPORT
	// listener each).
	workers int
}

pub fn new_server(config ServerConfig) !Server {
	if config.handler == unsafe { nil } {
		return error('provide a handler')
	}
	// on_worker_start arms clientless background watches on the epoll worker's
	// reactor; the TLS worker has none, so it is epoll + plaintext only for now.
	if config.on_worker_start != unsafe { nil } {
		$if linux {
			if config.io_multiplexing != .epoll {
				return error('on_worker_start requires the epoll backend')
			}
		} $else {
			return error('on_worker_start is only supported on the Linux epoll backend')
		}
		if config.tls_config != unsafe { nil } {
			return error('on_worker_start is not yet supported with TLS')
		}
	}

	if config.unix_socket_path != '' {
		$if windows {
			return error('unix_socket_path is not supported on Windows/IOCP')
		}
		if config.tls_config != unsafe { nil } {
			return error('TLS over a unix socket is not supported')
		}
	}

	mut socket_fd := 0
	$if !windows {
		if config.unix_socket_path != '' {
			socket_fd = socket.create_unix_server_socket(config.unix_socket_path)!
		} else {
			socket_fd = socket.create_server_socket(config.port)
		}
	} $else {
		socket_fd = socket.create_server_socket(config.port)
	}

	// port: 0 = ephemeral. The kernel picked a free port at bind time; read it back
	// ONCE so (a) the io_uring per-worker listeners below bind the SAME port and
	// actually join the SO_REUSEPORT group (each create_server_socket(0) would pick
	// a DIFFERENT port), and (b) Server.port tells every consumer — tests dialing
	// back, co-hosted servers, the startup banners — the real port. A UDS
	// listener has no port; the address is unix_socket_path.
	mut port := config.port
	if port == 0 && config.unix_socket_path == '' {
		port = socket.local_port(socket_fd)
		if port <= 0 {
			return error('could not resolve ephemeral port for listener fd ${socket_fd}')
		}
	}

	// Set default backend based on OS
	io_multiplexing := config.io_multiplexing
	$if windows {
		if io_multiplexing != .iocp {
			return error('Windows only supports IOCP backend')
		}
		if config.tls_config != unsafe { nil } {
			return error('TLS is not yet supported on the Windows/IOCP backend')
		}
	} $else $if linux {
		if io_multiplexing != .epoll && io_multiplexing != .io_uring {
			return error('Linux only supports epoll and io_uring backends')
		}
	} $else $if darwin {
		if io_multiplexing != .kqueue {
			return error('macOS only supports kqueue backend')
		}
	}

	// Per-server worker count: config.workers when set (>0), else the process-wide
	// default (VANILLA_WORKERS → nr_cpus). This is the single source of truth for
	// this server's worker fan-out — it sizes the thread / in-flight-counter /
	// io_uring-listener arrays below, and every backend derives its worker count
	// from threads.len, so two co-hosted servers can split the cores independently.
	n_workers := if config.workers > 0 { config.workers } else { max_thread_pool_size }

	// Listeners the server will accept on. The first is always socket_fd. The
	// io_uring backend is shared-nothing with one SO_REUSEPORT listener PER worker,
	// so create the rest up front (worker 0 reuses socket_fd): then shutdown() can
	// stop them ALL, and there is no extra never-accepted listener. epoll and the
	// other backends accept on the single socket_fd.
	// For a UDS listener there is no SO_REUSEPORT group: every io_uring worker
	// arms its accept on the ONE shared listener (the kernel wakes one armed
	// accept per connection), so listener_fds stays [socket_fd].
	mut listener_fds := [socket_fd]
	$if linux {
		if io_multiplexing == .io_uring && config.unix_socket_path == '' {
			for _ in 1 .. n_workers {
				listener_fds << socket.create_server_socket(port)
			}
		}
	}

	return Server{
		port:               port
		io_multiplexing:    config.io_multiplexing
		socket_fd:          socket_fd
		unix_socket_path:   config.unix_socket_path
		handler:            config.handler
		make_state:         config.make_state
		on_worker_start:    config.on_worker_start
		after_server_start: config.after_server_start
		limits:             config.limits
		tls_config:         config.tls_config
		threads:            []thread{len: n_workers, cap: n_workers}
		inflight:           []&core.Counter{len: n_workers, init: &core.Counter{}}
		listener_fds:       listener_fds
	}
}
