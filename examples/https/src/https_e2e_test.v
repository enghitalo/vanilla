// vtest build: linux && vanilla_tls?
module main

// The example served over HTTPS, end to end, with a client that VERIFIES the
// certificate: what `curl --cacert certs/cert.pem` does. Only with
// `-d vanilla_tls` on Linux (Mbed TLS is opt-in, and TLS is the epoll
// backend's); the build constraint on line 1 makes a default `v test` skip
// the file:
//
//   v -cc gcc -d vanilla_tls test examples/https/src
//
// The client is vlib's net.openssl (not net.mbedtls: its bundled Mbed TLS
// objects clash with the system -lmbedtls the server links).
import os
import time
import net
import net.openssl
import server
import tls
import vtest

// Hang backstop for the client: a regression fails a read instead of
// blocking the test.
const backstop = time.Duration(5 * time.second)

const want_hello = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, HTTPS!'

// start serves `route` over HTTPS with `cfg`, as main does, on port 0.
fn start(cfg &tls.Config) !&vtest.Harness {
	// The openssl client writes without MSG_NOSIGNAL: a write to a connection
	// the server already closed must fail that call, not end the test binary.
	os.signal_ignore(.pipe)
	return vtest.start(server.ServerConfig{
		workers:    1
		handler:    route
		tls_config: unsafe { cfg } // the Config lives on the C heap, for the whole test
		limits:     server.Limits{
			read_timeout_ms: 2_000
		}
	})
}

// dial completes a TLS handshake that checks the server's certificate against
// `ca_file` (the self-signed cert.pem) and its name against `host`.
fn dial(host string, port int, ca_file string) !&openssl.SSLConn {
	mut c := openssl.new_ssl_conn(validate: true, verify: ca_file)!
	c.dial(host, port)!
	c.set_read_timeout(backstop)
	return c
}

// exchange sends `req` and reads until `want_len` bytes arrived (or the
// connection ends) and returns them.
fn exchange(mut c openssl.SSLConn, req string, want_len int) !string {
	c.write_string(req)!
	mut acc := []u8{}
	mut buf := []u8{len: 4096}
	for acc.len < want_len {
		n := c.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		acc << buf[..n]
	}
	return acc.bytestr()
}

fn temp_cert_dir(name string) string {
	return os.join_path(os.temp_dir(), 'vanilla_https_${name}_${os.getpid()}')
}

// A self-signed identity (load_tls with no HTTPS_CERT/HTTPS_KEY) is written
// to the cert dir, and a client that trusts its cert.pem verifies the server
// as localhost, 127.0.0.1 and ::1. Requests on one keep-alive connection get
// the handler's answers.
fn test_self_signed_identity_verifies_and_serves() ! {
	dir := temp_cert_dir('self')
	defer {
		os.rmdir_all(dir) or {}
	}
	cfg := load_tls(dir)!
	ca := os.join_path(dir, 'cert.pem')
	assert os.exists(ca) && os.exists(os.join_path(dir, 'key.pem')), 'load_tls did not persist the identity in ${dir}'
	mut h := start(cfg)!
	defer {
		h.stop()
	}
	mut c := dial('localhost', h.port(), ca)!
	defer {
		c.shutdown() or {}
	}
	get := exchange(mut c, 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n', want_hello.len)!
	assert get == want_hello
	head_want := want_hello.all_before('Hello, HTTPS!')
	head := exchange(mut c, 'HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n', head_want.len)!
	assert head == head_want, 'the keep-alive connection must serve a second request'
	nf_want := 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'
	nf := exchange(mut c, 'GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n', nf_want.len)!
	assert nf == nf_want
	for host in ['127.0.0.1', '::1'] {
		mut c2 := dial(host, h.port(), ca) or {
			if host == '::1' && err.msg().contains('connect') {
				continue // no IPv6 loopback on this host
			}
			return err
		}
		assert exchange(mut c2, 'GET / HTTP/1.1\r\nHost: x\r\n\r\n', want_hello.len)! == want_hello, host
		c2.shutdown() or {}
	}
}

// A restart loads the identity it persisted: the same certificate, so a
// client that pinned cert.pem keeps working.
fn test_restart_keeps_the_identity() ! {
	dir := temp_cert_dir('restart')
	defer {
		os.rmdir_all(dir) or {}
	}
	first := load_tls(dir)!
	second := load_tls(dir)!
	assert first.cert_pem() != ''
	assert second.cert_pem() == first.cert_pem(), 'a restart issued a new certificate'
	mut h := start(second)!
	defer {
		h.stop()
	}
	mut c := dial('localhost', h.port(), os.join_path(dir, 'cert.pem'))!
	assert exchange(mut c, 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n', want_hello.len)! == want_hello
	c.shutdown() or {}
}

// HTTPS_CERT and HTTPS_KEY load a PEM pair (tls.new_from_pem), as for a
// CA-issued certificate. The pair here is a persisted self-signed one.
fn test_pem_files_from_the_environment() ! {
	dir := temp_cert_dir('pem')
	defer {
		os.rmdir_all(dir) or {}
	}
	tls.new_self_signed(persist_dir: dir)!
	ca := os.join_path(dir, 'cert.pem')
	os.setenv('HTTPS_CERT', ca, true)
	os.setenv('HTTPS_KEY', os.join_path(dir, 'key.pem'), true)
	defer {
		os.unsetenv('HTTPS_CERT')
		os.unsetenv('HTTPS_KEY')
	}
	cfg := load_tls('unused')!
	assert !os.exists('unused'), 'with HTTPS_CERT/HTTPS_KEY set, load_tls must not issue a certificate'
	mut h := start(cfg)!
	defer {
		h.stop()
	}
	mut c := dial('localhost', h.port(), ca)!
	assert exchange(mut c, 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n', want_hello.len)! == want_hello
	c.shutdown() or {}
}

// The HTTPS port never answers in plaintext: a cleartext request is a failed
// handshake, and the connection closes with no HTTP response.
fn test_plaintext_request_gets_no_http_answer() ! {
	dir := temp_cert_dir('plain')
	defer {
		os.rmdir_all(dir) or {}
	}
	mut h := start(load_tls(dir)!)!
	defer {
		h.stop()
	}
	mut c := net.dial_tcp('127.0.0.1:${h.port()}')!
	defer {
		c.close() or {}
	}
	c.set_read_timeout(backstop)
	c.write_string('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')!
	mut acc := []u8{}
	mut buf := []u8{len: 4096}
	for {
		n := c.read(mut buf) or { break }
		if n <= 0 {
			break
		}
		acc << buf[..n]
	}
	assert !acc.bytestr().contains('HTTP/1.1'), 'the HTTPS port answered in plaintext: ${acc.bytestr()}'
}
