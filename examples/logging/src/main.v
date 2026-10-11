// logging — an access log that never writes on the request path (#15).
//
// Every request gets one JSON line, appended into THIS worker's buffer: no
// lock, no syscall, no allocation. The worker's own timer (on_worker_start, a
// timerfd on its epoll loop) drains that buffer between requests: one
// write(2) of many lines to the log file, and a copy into a bounded queue
// that ships to a collector through http1_1.upstream, a POST of NDJSON
// parked on the pool's socket, so a slow or dead collector never stalls a
// request. The file rotates by size (worker 0 renames it, every worker
// reopens) and reopens on SIGHUP (logrotate's move-then-signal). Whatever
// cannot keep up (a full buffer, a full shipping queue) is dropped and
// COUNTED, never waited for: GET /stats shows the counts.
//
//   v run examples/logging/src
//   curl -i http://localhost:8098/
//   curl http://localhost:8098/stats
//   tail -f access.log
//
// Environment (see README.md): LOG_FILE (access.log; empty: no file),
// LOG_MAX_BYTES (64 MiB; 0: never rotate by size), LOG_KEEP (5),
// LOG_FLUSH_MS (200), COLLECTOR_HOST (unset: no shipping), COLLECTOR_PORT,
// COLLECTOR_PATH (/ingest), COLLECTOR_HTTPS (0), COLLECTOR_CA.
//
// Platform: the Linux epoll plain worker, the one that runs on_worker_start.
module main

import os
import core
import server
import time
import tls
import sync.stdatomic
import http1_1.request_parser
import http1_1.response
import http1_1.upstream

const port = 8098

const resp_hello = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, logs!\n'
const resp_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok'
const resp_404 = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'
const resp_405 = 'HTTP/1.1 405 Method Not Allowed\r\nAllow: GET\r\nContent-Length: 0\r\n\r\n'
const stats_head = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '

// handle is the server's handler: the app answers, then one line records
// what it answered. A malformed request is logged too (status 400).
fn handle(req_buffer []u8, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	t0 := time.sys_mono_now()
	start := out.len
	mut req := request_parser.HttpRequest{
		buffer: req_buffer
	}
	mut step := core.Step.done
	mut ua := request_parser.Slice{}
	if request_parser.decode_into(mut req) {
		step = app(req, req_buffer, mut out, mut w)
		ua = req.get_header_value_slice('user-agent') or { request_parser.Slice{} }
	} else {
		out << response.tiny_bad_request_response
		step = .close
	}
	w.record(req_buffer, req.method, req.path, ua, out, start, time.sys_mono_now() - t0)
	return step
}

// app is the service being logged: three routes, appended into `out`.
fn app(req request_parser.HttpRequest, req_buffer []u8, mut out []u8, mut w Worker) core.Step {
	if !is_get(req_buffer, req.method) {
		core.append_str(mut out, resp_405)
	} else if is_path(req_buffer, req.path, '/') {
		core.append_str(mut out, resp_hello)
	} else if is_path(req_buffer, req.path, '/healthz') {
		core.append_str(mut out, resp_ok)
	} else if is_path(req_buffer, req.path, '/stats') {
		// The body first (a per-worker scratch), then its length.
		unsafe {
			w.body.len = 0
		}
		w.sh.stats_json(mut w.body)
		core.append_str(mut out, stats_head)
		wi(mut out, w.body.len)
		core.append_str(mut out, '\r\n\r\n')
		unsafe { out.push_many(w.body.data, w.body.len) }
	} else {
		core.append_str(mut out, resp_404)
	}
	return .done
}

@[direct_array_access]
fn is_get(buf []u8, m request_parser.Slice) bool {
	return m.len == 3 && buf[m.start] == `G` && buf[m.start + 1] == `E` && buf[m.start + 2] == `T`
}

// is_path reports whether the request target is `lit`, with or without a
// query, compared in place: no string is built.
@[direct_array_access]
fn is_path(buf []u8, p request_parser.Slice, lit string) bool {
	if p.len < lit.len || (p.len > lit.len && buf[p.start + lit.len] != `?`) {
		return false
	}
	return unsafe { vmemcmp(&buf[p.start], lit.str, lit.len) } == 0
}

// install_reopen_on_hup makes SIGHUP reopen the log file (logrotate's
// postrotate). The handler runs in async-signal context, on whichever thread
// the kernel interrupts, so it does one async-signal-safe thing, an atomic
// add; each worker reopens on its own thread, before its next write.
fn install_reopen_on_hup(sh &Shared) ! {
	os.signal_opt(.hup, fn [sh] (_ os.Signal) {
		stdatomic.add_i64(&sh.reopen_gen, 1)
	})!
}

// rotated_names is path.1 … path.<keep>, built once so that a rotation
// allocates nothing.
fn rotated_names(path string, keep int) []string {
	mut names := []string{cap: keep}
	for i in 1 .. keep + 1 {
		names << '${path}.${i}'
	}
	return names
}

// shared_from_env builds the configuration from the environment.
fn shared_from_env() !&Shared {
	path := os.getenv_opt('LOG_FILE') or { 'access.log' }
	keep := (os.getenv_opt('LOG_KEEP') or { '5' }).int()
	if keep < 1 {
		return error('LOG_KEEP must be at least 1')
	}
	flush_ms := (os.getenv_opt('LOG_FLUSH_MS') or { '200' }).int()
	if flush_ms < 1 {
		return error('LOG_FLUSH_MS must be at least 1')
	}
	if path != '' {
		// Fail now, not at the first flush: the directory must exist and be
		// writable.
		fd := C.open(&char(path.str), C.O_WRONLY | C.O_CREAT | C.O_APPEND | C.O_CLOEXEC,
			0o644)
		if fd < 0 {
			return error('cannot open ${path}: ${os.posix_get_error_msg(C.errno)}')
		}
		C.close(fd)
	}
	mut collector := upstream.Origin{}
	mut tls_cfg := &tls.Config(unsafe { nil })
	host := os.getenv('COLLECTOR_HOST')
	if host != '' {
		https := os.getenv('COLLECTOR_HTTPS') == '1'
		collector = upstream.Origin{
			host:                host
			port:                (os.getenv_opt('COLLECTOR_PORT') or {
				if https { '443' } else { '80' }
			}).int()
			https:               https
			max_conns:           1 // one batch in flight per worker
			connect_timeout_ms:  2000
			response_timeout_ms: 5000
		}
		if https {
			// One client config for every worker: the trusted CAs are parsed once.
			tls_cfg = tls.new_client(os.getenv('COLLECTOR_CA'), .full)!
		}
	}
	return &Shared{
		path:      path
		rotated:   rotated_names(path, keep)
		max_bytes: (os.getenv_opt('LOG_MAX_BYTES') or { '67108864' }).i64()
		flush_ms:  flush_ms
		collector: collector
		tls_cfg:   tls_cfg
		target:    os.getenv_opt('COLLECTOR_PATH') or { '/ingest' }
	}
}

fn main() {
	sh := shared_from_env() or {
		eprintln('logging: ${err}')
		exit(1)
	}
	mut srv := server.new_server(server.ServerConfig{
		port:            port
		io_multiplexing: .epoll
		handler:         handle
		make_state:      fn [sh] () voidptr {
			return new_worker(sh)
		}
		on_worker_start: on_worker_start
	})!
	install_reopen_on_hup(sh)!
	// SIGTERM / SIGINT: the handler only writes a byte to a pipe; a normal
	// thread drains the server, has every worker flush, and exits (see
	// examples/graceful_shutdown for why the handler does no more).
	wake := os.pipe()!
	on_stop := fn [wake] (_ os.Signal) {
		saved := C.errno
		C.write(wake.write_fd, c'x', 1)
		C.errno = saved
	}
	os.signal_opt(.term, on_stop)!
	os.signal_opt(.int, on_stop)!
	spawn fn [srv, sh, wake] () {
		os.fd_read(wake.read_fd, 1)
		srv.shutdown(2000)
		if !sh.final_flush(2 * sh.flush_ms + 1000) {
			eprintln('logging: a worker did not flush in time; its last lines are lost')
		}
		exit(0)
	}()
	mut dest := if sh.path != '' { sh.path } else { 'no file' }
	if sh.collector.host != '' {
		scheme := if sh.collector.https { 'https' } else { 'http' }
		dest = '${dest} + ${scheme}://${sh.collector.host}:${sh.collector.port}${sh.target}'
	}
	println('logging on http://localhost:${port}/ (/healthz, /stats) to ${dest}; SIGHUP reopens')
	srv.run()
}
