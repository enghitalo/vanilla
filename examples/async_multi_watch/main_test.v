// vtest build: linux
// main.v needs <sys/timerfd.h> and the epoll watch reactor (Linux only).
module main

import time
import server
import vtest
import http1_1.response

const chain_req = 'GET /chain HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

// /chain parks on timer A (80 ms), then on timer B (140 ms), then answers with
// a fixed response. Byte-exact: the response used to be built per request with
// `${}`, and its Content-Length must still match its body.
fn test_chain_runs_both_stages_and_answers_byte_exact() ! {
	mut h := vtest.start(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	})!
	defer {
		h.stop()
	}
	t0 := time.ticks()
	out := h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: chain_req
		}]
	}])!
	elapsed := time.ticks() - t0
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1
	assert c.frames[0].bytestr() == resp_chain
	assert elapsed >= 220, 'answered after ${elapsed} ms, before both timers fired'
}

fn test_other_paths_get_404_and_bad_requests_close() ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: 'GET /chains HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
				},
				vtest.Round{
					send: chain_req
				},
			]
		},
		vtest.Script{
			rounds:   [vtest.Round{
				send: 'GET\r\n\r\n'.bytes()
			}]
			then_eof: true
		},
	])!
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 2
	assert c.frames[0].bytestr() == not_found
	assert c.frames[1].bytestr() == resp_chain
	bad := out.conns[1]
	assert bad.eof
	assert bad.frames.len == 1
	assert bad.frames[0] == response.tiny_bad_request_response
	assert out.inflight_after == 0
	assert out.active_after == 0
}
