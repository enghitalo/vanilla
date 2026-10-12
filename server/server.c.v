module server

import socket
import time
import sync.stdatomic
import core
import tls

#include <signal.h>
#include "@VMODROOT/server/sigpipe_shim.h"

fn C.signal(sig int, handler voidptr) voidptr
fn C.vanilla_ignore_default_sigpipe() int

const max_thread_pool_size = core.max_thread_pool_size

// Limits is re-exported from `core` so the public config API stays ergonomic
// (`server.Limits{...}`). The real definition lives in `core` because the
// backend reads it too, and `core` is the leaf both sides depend on.
pub type Limits = core.Limits

// Server is a server with its listeners open: build it with new_server, serve
// with run(), stop with shutdown(). Its fields are what new_server resolved
// from the ServerConfig: build it only with new_server (the zero Server has
// no listener).
pub struct Server {
pub:
	// port is the TCP port it listens on: the kernel's pick when
	// ServerConfig.port was 0. Meaningless with unix_socket_path.
	port int = 3000
	// io_multiplexing is the backend run() drives (IOBackend).
	io_multiplexing IOBackend = unsafe { IOBackend(0) }
	// socket_fd is the listening socket: the only one, except on io_uring
	// over TCP, where it is the first of listener_fds.
	socket_fd int
	// limits are the request and connection limits every worker enforces.
	limits     Limits
	tls_config &tls.Config = unsafe { nil } // nil ⇒ plain HTTP; set ⇒ HTTPS
	// Non-empty ⇒ the listener is an AF_UNIX stream socket at this filesystem
	// path (issue #122 §5) and `port` is meaningless. shutdown() uses it for
	// the io_uring wake poke and to unlink the socket file.
	unix_socket_path string
pub mut:
	// threads holds the worker threads run() spawns: its length is the
	// worker count (ServerConfig.workers).
	threads []thread = []thread{len: max_thread_pool_size, cap: max_thread_pool_size}
	// handler is the request handler (ServerConfig.handler).
	handler core.Handler = unsafe { nil }
	// Optional per-worker state; see ServerConfig. make_state runs once per worker
	// thread, its result reaches every handler call as the worker_state parameter.
	make_state fn () voidptr = unsafe { nil }
	// on_worker_start runs once per epoll worker (ServerConfig.on_worker_start).
	on_worker_start core.WorkerStartFn = unsafe { nil }
	// Runs ONCE on the main thread the instant the server is accepting (all
	// listeners bound + workers spawned), right before run() blocks. See
	// ServerConfig.after_server_start / core.AfterStartFn.
	after_server_start core.AfterStartFn = unsafe { nil }
	// Per-worker in-flight request counters (one per worker, each on its own
	// cache line — written only by its worker, so no contention/false sharing).
	// A request counts while it runs and while it is parked on a watch.
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
	// re-arming and the workers quit accepting. Unused by the epoll backend, whose
	// acceptor stops once its listener reports the shutdown (EPOLLHUP) or accept()
	// says the listener is gone (socket.listener_gone).
	draining &core.Counter = &core.Counter{}
	// Server push (vanilla#230): one mailbox per epoll worker (empty on the
	// other backends), opaque here and never freed (ConnHandles may outlive
	// the server). Its ring exists when ServerConfig.push_mailbox_slots > 0;
	// shutdown() signals .shutdown through it either way.
	mailboxes []voidptr
	// push_watermark is the pending-write bound of a pushed connection
	// (ServerConfig.push_watermark_bytes; 0 = the default, 1 MiB).
	push_watermark int
}

// PushStats are the server's push counters, summed over its workers'
// mailboxes (push_stats).
pub struct PushStats {
pub:
	posted    u64 // posts enqueued
	full      u64 // posts refused because the mailbox was full
	delivered u64 // posts delivered to a wake fn
	stale     u64 // posts dropped: the connection was gone, or no longer subscribed, when its worker took them
}

// push_stats sums the push counters of every worker's mailbox (zero when the
// mailbox is off).
pub fn (s &Server) push_stats() PushStats {
	$if linux {
		return push_stats_linux(s.mailboxes)
	}
	return PushStats{}
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
// In flight includes a request PARKED on a watch (.suspend: an async DB query,
// an upstream call, a timer) until its continuation answers it, so size
// grace_ms for the slowest parked operation (DB or upstream timeout); a
// request parked for good (a stream that waits on a watch) holds the drain
// for the whole grace. A parked client that disconnects stops counting at
// once on epoll and kqueue; io_uring notices only when its request resumes.
// A subscribed connection (epoll, core.EventLoop.subscribe: an SSE stream, a
// WebSocket) is not parked: its wake fn gets .shutdown, and the drain waits
// for that delivery, not for the connection.
//
// The drain is PRECISE: it sums the per-worker in-flight counters and returns
// the instant they all hit zero, so an idle server shuts down in ~milliseconds
// rather than waiting the whole grace. The counters are per-worker and each on
// its own cache line, so the per-request increment is uncontended and free on
// the hot path (measured: no throughput change). Idle keep-alive connections
// hold no in-flight work, so they're simply dropped on exit.
//
// Do NOT call it (or `exit`) inside a signal handler: the handler runs in
// async-signal context, on whichever thread the kernel interrupts, and neither
// call is async-signal-safe (a worker interrupted there would also spin here,
// unable to finish its own request). Let the handler only write(2) a byte to a
// pipe, and call shutdown from an ordinary thread blocked on that pipe, then
// `exit(0)` — see "Graceful Shutdown" in the README and
// examples/graceful_shutdown. It is safe to call from another thread while
// `run()` is blocked: stopping the listeners halts new accepts; existing
// workers finish their current request.
pub fn (s Server) shutdown(grace_ms int) {
	// Tell the io_uring accept handlers to stop re-arming BEFORE the listeners are
	// shut, so the resulting accept-error completion already observes the flag.
	stdatomic.store_i64(&s.draining.n, 1)
	// Subscribed connections (vanilla#230) get .shutdown, to say goodbye; the
	// drain below waits for those deliveries, not for the connections.
	$if linux {
		signal_push_shutdown(s.mailboxes, s.inflight)
	}
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

// Certificates is unused: nothing reads ServerConfig.certificates (#287).
// Configure HTTPS with ServerConfig.tls_config instead, e.g.
// `tls.new_from_pem(cert_pem, key_pem)!`.
pub struct Certificates {
pub:
	cert_pem    []u8 // PEM certificate (chain); ignored, see Certificates
	key_pem     []u8 // PEM private key; ignored
	ca_cert_pem []u8 // PEM CA certificate; ignored
}

// ServerConfig configures new_server. Only `handler` is required; every
// other field has a working default: port 3000, the platform's backend, no
// timeouts, one worker per CPU.
pub struct ServerConfig {
pub:
	// port is the TCP port to listen on. 0 lets the kernel pick a free one,
	// which new_server reads back into Server.port. Ignored with
	// unix_socket_path.
	port int = 3000
	// io_multiplexing selects the backend (IOBackend). The zero value is the
	// platform's default: epoll on Linux, kqueue on macOS, IOCP on Windows.
	// new_server errors for one the platform does not have.
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
	// only, with or without TLS. See core.WorkerStartFn.
	on_worker_start core.WorkerStartFn = unsafe { nil }
	// after_server_start runs ONCE on the main thread the moment the server is
	// accepting connections (all listeners bound + listening, workers spawned),
	// right before run() blocks in its accept loop. A single process-level
	// lifecycle hook that works on EVERY backend (unlike on_worker_start). Use it
	// to log readiness, register in service discovery, write a PID/ready file,
	// notify a supervisor, or signal a channel in tests. See core.AfterStartFn.
	after_server_start core.AfterStartFn = unsafe { nil }
	// push_mailbox_slots > 0 gives every epoll worker a mailbox of that many
	// slots (rounded up to a power of two; ~280 B each: 4096 slots are ~1.1 MiB
	// per worker), through which any thread can post to a subscribed
	// connection (core.ConnHandle.post_wake / post_bytes, vanilla#230). 0 (the
	// default) = off: posts report .unsupported; subscriptions, wake_after,
	// .shutdown and .closed still work. The epoll backend only, with or
	// without TLS.
	push_mailbox_slots int
	// push_watermark_bytes bounds what a subscribed connection may have
	// waiting to be sent after its wake fn ran: past it the connection is
	// closed (a subscriber that stopped reading). 0 = 1 MiB; at most
	// core.max_pending_write_bytes (8 MiB).
	push_watermark_bytes int
	// certificates is ignored: nothing reads it, so setting it without
	// tls_config serves plain HTTP (#287). Use tls_config.
	certificates Certificates
	// limits bounds request sizes, the connection count and the timeouts
	// (core.Limits); the zero value arms no timeout.
	limits Limits
	// tls_config, when set, serves HTTPS (e.g. tls.new_self_signed()); the
	// program must be built with `-d vanilla_tls`. The Linux epoll backend
	// only: new_server rejects it on io_uring, poll, kqueue, IOCP and a unix
	// socket.
	tls_config &tls.Config = unsafe { nil }
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

// new_server validates `config` and opens the listeners; `run` starts serving.
// A listener it cannot open (port in use, not permitted, out of fds) is
// returned as an error whose code is the errno (WSAGetLastError() on Windows).
//
// On POSIX, if SIGPIPE still has its default action, new_server sets it to
// ignored, process-wide, as nginx does. sendfile(2) has no MSG_NOSIGNAL, so a
// file sent to a peer that reset the connection would otherwise raise SIGPIPE
// and end the whole process; ignored, the send fails with EPIPE and the
// worker closes that connection. A SIGPIPE handler the application installed
// before calling new_server is kept (it must not end the process). An ignored
// signal stays ignored across exec, so child processes (os.execute, popen)
// inherit it: one that relies on SIGPIPE's default action (`yes | head`)
// should restore it.
pub fn new_server(config ServerConfig) !Server {
	if config.handler == unsafe { nil } {
		return error('provide a handler')
	}
	// on_worker_start arms clientless background watches on the epoll worker's
	// reactor (plain HTTP or HTTPS); no other backend runs it.
	if config.on_worker_start != unsafe { nil } {
		$if linux {
			if config.io_multiplexing != .epoll {
				return error('on_worker_start requires the epoll backend')
			}
		} $else {
			return error('on_worker_start is only supported on the Linux epoll backend')
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

	// Check the backend against the OS, and TLS against the backend. Nothing is
	// bound yet, so a rejected config leaves no listener behind. The zero
	// IOBackend is the platform default (epoll, kqueue, IOCP): no defaulting
	// happens here.
	io_multiplexing := config.io_multiplexing
	$if windows {
		if io_multiplexing != .iocp {
			return error('Windows only supports IOCP backend')
		}
		if config.tls_config != unsafe { nil } {
			return error('TLS is not yet supported on the Windows/IOCP backend')
		}
	} $else $if linux {
		$if vanilla_poll ? {
			if io_multiplexing !in [.epoll, .io_uring, .poll] {
				return error('Linux only supports the epoll, io_uring and poll backends')
			}
			if io_multiplexing == .poll && config.tls_config != unsafe { nil } {
				return error('TLS is not supported on the poll backend')
			}
		} $else {
			if io_multiplexing == .poll {
				return error('the poll backend requires building with `-d vanilla_poll`')
			}
			if io_multiplexing != .epoll && io_multiplexing != .io_uring {
				return error('Linux only supports epoll and io_uring backends')
			}
		}
		// TLS lives in the epoll worker only (backend_epoll/tls_conn_linux.c.v).
		// The io_uring backend never reads tls_config, so accepting it would
		// serve PLAINTEXT to a server configured for HTTPS (#156).
		if io_multiplexing == .io_uring && config.tls_config != unsafe { nil } {
			return error('TLS is not yet supported on the io_uring backend; use the epoll backend')
		}
	} $else $if darwin {
		if io_multiplexing != .kqueue {
			return error('macOS only supports kqueue backend')
		}
		// Same as io_uring: kqueue has no TLS, and would serve plaintext (#156).
		if config.tls_config != unsafe { nil } {
			return error('TLS is not yet supported on the macOS/kqueue backend')
		}
	}

	// Per-server worker count: config.workers when set (>0), else the process-wide
	// default (VANILLA_WORKERS → nr_cpus). This is the single source of truth for
	// this server's worker fan-out — it sizes the thread / in-flight-counter /
	// io_uring-listener arrays below, and every backend derives its worker count
	// from threads.len, so two co-hosted servers can split the cores independently.
	n_workers := if config.workers > 0 { config.workers } else { max_thread_pool_size }

	// The listeners are opened only now, once the config is valid, so a rejected
	// config leaves nothing bound. A listener failure (EADDRINUSE, EACCES,
	// EMFILE…) is returned to the caller after closing every listener already
	// opened: a leaked SO_REUSEPORT listener would take a share of the port's
	// connections and never accept them.
	mut socket_fd := 0
	$if !windows {
		if config.unix_socket_path != '' {
			socket_fd = socket.create_unix_server_socket(config.unix_socket_path)!
		} else {
			socket_fd = socket.create_server_socket(config.port)!
		}
	} $else {
		socket_fd = socket.create_server_socket(config.port)!
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
			socket.close_socket(socket_fd)
			return error('could not resolve ephemeral port for listener fd ${socket_fd}')
		}
	}

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
				fd := socket.create_server_socket(port) or {
					for l in listener_fds {
						socket.close_socket(l)
					}
					return err
				}
				listener_fds << fd
			}
		}
	}

	// Server push mailboxes (vanilla#230): one per epoll worker, built once the
	// listeners are open, here so shutdown() can reach them; never freed. With
	// push_mailbox_slots = 0 one has no ring and no eventfd until its worker's
	// first subscription, only what shutdown() needs to deliver .shutdown.
	mut mailboxes := []voidptr{}
	$if linux {
		if io_multiplexing == .epoll {
			mailboxes = new_push_mailboxes(n_workers, config.push_mailbox_slots)
		}
	}

	// sendfile(2) has no MSG_NOSIGNAL: a write to a peer that reset the
	// connection raises SIGPIPE, whose default action kills the whole process.
	// Ignore it, unless the application set its own disposition (see the doc
	// comment above). Windows has no SIGPIPE; the shim is a no-op there.
	C.vanilla_ignore_default_sigpipe()

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
		mailboxes:          mailboxes
		push_watermark:     config.push_watermark_bytes
	}
}
