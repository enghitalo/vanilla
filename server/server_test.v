module server

// Hook-contract test for `after_server_start`. This file deliberately stays
// hand-rolled (chan + select + testkit) because it tests the readiness hook
// mechanism ITSELF — vtest's drive()/start() are built on that hook, so they
// cannot be used to verify it (docs/VTEST.md, "What stays hand-rolled").
//
// The end-to-end behavior tests that used to live here (keep-alive GET → 404
// routing, body delivery, malformed request → 400 + close) moved to
// tests/server_default_backend_test.v, on vtest.
import os
import net
import time
import testkit
import core
import socket
import tls

fn dummy_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	if req.bytestr().contains('/notfound') {
		res << 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\nNot Found'.bytes()
		return .done
	}
	res << 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK'.bytes()
	return .done
}

// The after_server_start hook fires exactly once, on the run() thread, at the
// moment the server is accepting. This verifies the hook mechanism itself: it must
// signal within a deadline, and the server must be serving immediately afterwards.
fn test_after_server_start_fires_when_ready() ! {
	ready := chan bool{cap: 1}
	mut srv := new_server(ServerConfig{
		port:               8156
		io_multiplexing:    unsafe { IOBackend(0) }
		handler:            dummy_handler
		after_server_start: fn [ready] () {
			ready <- true
		}
	})!
	spawn fn [mut srv] () {
		srv.run()
	}()

	select {
		_ := <-ready {
		}
		2000 * time.millisecond {
			assert false, 'after_server_start did not fire within 2s'
		}
	}

	mut c := net.dial_tcp('127.0.0.1:8156')!
	c.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes())!
	assert testkit.read_until_count(mut c, 'HTTP/1.1 200', 1, 2000) == 1, 'server must be serving the instant after_server_start fired'
	c.close() or {}

	srv.shutdown(500)
}

fn sigpipe_probe_handler(_ int) {}

// new_server ignores SIGPIPE only while it still has its default action: a
// handler the application installed first is kept (sendfile(2) to a reset peer
// then runs it and fails with EPIPE), and the default becomes SIG_IGN. Each
// C.signal call below returns the disposition it replaces, which is how the
// test reads what new_server left.
fn test_new_server_ignores_sigpipe_only_when_default() ! {
	$if !windows {
		C.signal(C.SIGPIPE, voidptr(sigpipe_probe_handler))
		mut a := new_server(ServerConfig{
			port:    0
			workers: 1
			handler: dummy_handler
		})!
		a.shutdown(0)
		kept := C.signal(C.SIGPIPE, C.SIG_DFL)
		assert kept == voidptr(sigpipe_probe_handler), 'new_server replaced the application SIGPIPE handler'

		mut b := new_server(ServerConfig{
			port:    0
			workers: 1
			handler: dummy_handler
		})!
		b.shutdown(0)
		set := C.signal(C.SIGPIPE, C.SIG_IGN)
		assert set == C.SIG_IGN, 'new_server left the default SIGPIPE action in place'
	}
}

// lowest_free_fd is the number the kernel gives the next new fd: the same
// value before and after a refused new_server means it opened nothing. POSIX
// only in effect: a Windows socket is not a C file descriptor, so there the
// check sees nothing.
fn lowest_free_fd() !int {
	mut f := os.open(os.executable())!
	fd := f.fd
	f.close()
	return fd
}

// tls_config is served by the Linux epoll backend only. new_server must refuse
// it everywhere else, before it binds anything: io_uring and kqueue used to
// accept it and serve PLAINTEXT to a server configured for HTTPS (#156). An
// empty Config stands in for a certificate (new_server never reads it), so
// the test needs no `-d vanilla_tls`.
fn test_new_server_refuses_tls_where_it_is_not_served() ! {
	cfg := &tls.Config{}
	mut refused := []IOBackend{}
	$if linux {
		refused << .io_uring
	} $else $if darwin {
		refused << .kqueue
	} $else $if windows {
		refused << .iocp
	}
	for backend in refused {
		before := lowest_free_fd()!
		srv := new_server(ServerConfig{
			port:            0
			io_multiplexing: backend
			handler:         dummy_handler
			tls_config:      cfg
		}) or {
			assert err.msg().contains('TLS is not yet supported'), '${backend}: ${err.msg()}'
			assert lowest_free_fd()! == before, '${backend}: the refused config left an fd open'
			continue
		}
		for fd in srv.listener_fds {
			socket.close_socket(fd)
		}
		assert false, 'new_server accepted tls_config on ${backend}, which would serve it plaintext'
	}
	$if linux {
		// The default backend (epoll) still takes it.
		srv := new_server(ServerConfig{
			port:       0
			workers:    1
			handler:    dummy_handler
			tls_config: cfg
		})!
		assert srv.io_multiplexing == .epoll
		for fd in srv.listener_fds {
			socket.close_socket(fd)
		}
	}
}
