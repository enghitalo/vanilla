// vtest build: linux
// An interim 100 Continue must not land inside a core.queue_file body still
// owed to an earlier response (vanilla#275 gap 1). The plain epoll worker
// sends the pending region first, with sendfile(2), and holds the 100 until
// the region is out (send_file_first), as it already did over TLS
// (tests/tls_async_test.v). Two shapes:
//   * one write carries GET /file and the head of a POST with
//     `Expect: 100-continue` whose body is not sent: the worker answers the
//     GET, stops at the incomplete POST, and owes it a 100;
//   * the GET's 512 KiB region goes through a 4 KiB SO_SNDBUF, so it is
//     still mid-send (parked on EPOLLOUT) when the POST head arrives on a
//     later edge.
// Either way the client must read the GET response whole (head, then the
// file), then the 100, then, once it sends the body, the POST's answer.
// queue_file is inert under tcc: run with gcc, as CI does.
import os
import server
import core
import sync.stdatomic
import vtest

#include <sys/socket.h>

fn C.setsockopt(fd int, level int, optname int, optval voidptr, optlen u32) int

const ec_small_len = 64
const ec_small_head = 'HTTP/1.1 200 OK\r\nContent-Length: 64\r\nConnection: keep-alive\r\n\r\n'.bytes()
const ec_big_len = 512 * 1024
const ec_big_head = 'HTTP/1.1 200 OK\r\nContent-Length: 524288\r\nConnection: keep-alive\r\n\r\n'.bytes()
const ec_post_resp = 'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\npost'.bytes()
const ec_continue = 'HTTP/1.1 100 Continue\r\n\r\n'.bytes()
const ec_get = 'GET /file HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
const ec_post_head = 'POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n'.bytes()
const ec_body = 'hello'.bytes()

// ec_file is an `n`-byte file of `f` bytes, unlinked right away: the fd keeps
// it alive, and nothing is left behind whatever the check does.
fn ec_file(tag string, n int) !os.File {
	path := os.join_path(os.temp_dir(), 'vanilla_expect100_${tag}_${os.getpid()}.bin')
	os.write_file_array(path, []u8{len: n, init: `f`})!
	f := os.open(path)!
	os.rm(path)!
	return f
}

// ec_handler answers the POST with ec_post_resp, and GET /file with `head`
// and the file's first `n` bytes handed off with core.queue_file (or, where
// queue_file refuses, read into `res`), counting every accepted hand-off.
// small_sndbuf pins the client socket's send buffer to 4 KiB first.
fn ec_handler(file_fd int, n int, head []u8, small_sndbuf bool, accepted &core.Counter) core.Handler {
	return fn [file_fd, n, head, small_sndbuf, accepted] (req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
		if req[0] == `P` {
			res << ec_post_resp
			return .done
		}
		if small_sndbuf {
			sz := i32(4096)
			C.setsockopt(client_fd, C.SOL_SOCKET, C.SO_SNDBUF, &sz, u32(sizeof(i32)))
		}
		res << head
		if core.queue_file(file_fd, 0, n) {
			stdatomic.add_i64(&accepted.n, 1)
		} else {
			core.append_file_region(mut res, file_fd, 0, n)
		}
		return .done
	}
}

// ec_want is the whole conversation: the GET response (head, then `n` file
// bytes), the 100, then the POST's answer.
fn ec_want(head []u8, n int) []u8 {
	mut want := []u8{cap: head.len + n + ec_continue.len + ec_post_resp.len}
	want << head
	want << []u8{len: n, init: `f`}
	want << ec_continue
	want << ec_post_resp
	return want
}

// ec_check returns an error unless c received exactly `want`, naming where the
// 100 Continue landed. It returns instead of asserting so that the caller's
// defers run when it fails (docs/VTEST.md).
fn ec_check(what string, c vtest.ConnResult, want []u8, accepted &core.Counter) ! {
	if c.connect_err != '' {
		return error(c.connect_err)
	}
	$if !tinyc {
		got := stdatomic.load_i64(&accepted.n)
		if got != 1 {
			return error('${what}: ${got} core.queue_file hand-offs accepted, want 1')
		}
	}
	if c.raw != want {
		at := c.raw.bytestr().index('HTTP/1.1 100 Continue') or { -1 }
		body_end := want.len - ec_continue.len - ec_post_resp.len
		return error('${what}: ${c.raw.len} of ${want.len} bytes; the 100 Continue starts at byte ${at}, the GET body ends at byte ${body_end}')
	}
}

// One write: GET /file, then the POST head.
fn test_epoll_expect_100_behind_file_region_same_write() ! {
	mut f := ec_file('burst', ec_small_len)!
	defer {
		f.close()
	}
	accepted := &core.Counter{}
	mut burst := []u8{cap: ec_get.len + ec_post_head.len}
	burst << ec_get
	burst << ec_post_head
	want := ec_want(ec_small_head, ec_small_len)
	interim_end := want.len - ec_post_resp.len
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         ec_handler(f.fd, ec_small_len, ec_small_head, false, accepted)
		workers:         1
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  burst
					until: fn [interim_end] (acc []u8) bool {
						return acc.len >= interim_end
					}
				},
				vtest.Round{
					send:  ec_body
					until: fn [want] (acc []u8) bool {
						return acc.len >= want.len
					}
				},
			]
		},
	])!
	ec_check('GET + Expect head in one write', out.conns[0], want, accepted)!
	assert out.active_after == 0
}

// The GET's 512 KiB region is still mid-send (parked on EPOLLOUT) when the
// POST head arrives on a later edge.
fn test_epoll_expect_100_while_file_region_parked() ! {
	mut f := ec_file('parked', ec_big_len)!
	defer {
		f.close()
	}
	accepted := &core.Counter{}
	want := ec_want(ec_big_head, ec_big_len)
	interim_end := want.len - ec_post_resp.len
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         ec_handler(f.fd, ec_big_len, ec_big_head, true, accepted)
		workers:         1
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send:  ec_get
					until: vtest.headers_seen
				},
				vtest.Round{
					send:  ec_post_head
					until: fn [interim_end] (acc []u8) bool {
						return acc.len >= interim_end
					}
				},
				vtest.Round{
					send:  ec_body
					until: fn [want] (acc []u8) bool {
						return acc.len >= want.len
					}
				},
			]
		},
	])!
	ec_check('Expect head while the region is parked', out.conns[0], want, accepted)!
	assert out.active_after == 0
}
