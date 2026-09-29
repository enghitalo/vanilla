// vtest build: linux && vanilla_tls?
// Several TLS workers in one process (issue #157). PSA Crypto's state — the
// key store every session's keys live in, the RNG — is process-wide, and an
// Mbed TLS built without MBEDTLS_THREADING_C (the upstream default config,
// and distro packages such as Arch's) does not lock it: concurrent handshakes
// on different workers raced on it, failing connections and corrupting the
// heap (an abort in malloc ends this test binary). Many clients handshake and
// exchange keep-alive requests at once, over four workers: every connection
// must complete.
//
// Only runs with `-d vanilla_tls` on Linux (see tls_timeouts_test.v, whose
// client this follows):
//
//   v -cc gcc -d vanilla_tls test tests/tls_workers_test.v
import os
import time
import net.openssl
import server
import core
import tls
import vtest

const tw_ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok'.bytes()
const tw_req = 'GET / HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const tw_workers = 4
// Client threads, each dialing tw_conns connections in turn: tw_clients
// handshakes in flight at a time, across the workers.
const tw_clients = 16
const tw_conns = 80
// Keep-alive requests per connection, so record crypto runs concurrently too.
const tw_requests = 3
// Hang backstop for the openssl client only: a stalled connection fails its
// session instead of blocking the test.
const tw_backstop = time.Duration(5 * time.second)

fn tw_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	res << tw_ok_response
	return .done
}

fn tw_start() !&vtest.Harness {
	os.signal_ignore(.pipe) // see tt_start in tls_timeouts_test.v
	$if linux {
		return vtest.start(server.ServerConfig{
			io_multiplexing: .epoll
			workers:         tw_workers
			tls_config:      tls.new_self_signed()!
			handler:         tw_handler
		})
	} $else {
		return error('the TLS worker is the Linux epoll backend')
	}
}

// tw_session dials one connection, sends tw_requests requests on it one after
// another and reports whether every response arrived intact.
fn tw_session(port int) bool {
	mut c := openssl.new_ssl_conn(validate: false) or { return false }
	c.dial('127.0.0.1', port) or { return false }
	c.set_read_timeout(tw_backstop)
	defer {
		c.shutdown() or {}
	}
	mut buf := []u8{len: 256}
	for _ in 0 .. tw_requests {
		c.write(tw_req) or { return false }
		mut got := []u8{}
		for got.len < tw_ok_response.len {
			n := c.read(mut buf) or { return false }
			if n <= 0 {
				return false
			}
			got << buf[..n]
		}
		if got != tw_ok_response {
			return false
		}
	}
	return true
}

// tw_client runs tw_conns sessions in turn and returns how many completed.
fn tw_client(port int) int {
	mut ok := 0
	for _ in 0 .. tw_conns {
		if tw_session(port) {
			ok++
		}
	}
	return ok
}

fn test_tls_many_workers_concurrent_handshakes() ! {
	$if linux {
		$if vanilla_tls ? {
			mut h := tw_start()!
			defer {
				h.stop()
			}
			port := h.port()
			mut clients := []thread int{}
			for _ in 0 .. tw_clients {
				clients << spawn tw_client(port)
			}
			mut ok := 0
			for n in clients.wait() {
				ok += n
			}
			total := tw_clients * tw_conns
			assert ok == total, '${total - ok} of ${total} TLS connections failed across ${tw_workers} workers (parallel crypto: ${tls.parallel_crypto()})'
		}
	}
}
