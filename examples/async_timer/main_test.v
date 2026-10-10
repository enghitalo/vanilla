// vtest build: linux
// main.v needs <sys/timerfd.h> and the epoll watch reactor (Linux only).
module main

import time
import server
import vtest
import http1_1.request_parser
import http1_1.response

fn get(target string) []u8 {
	return 'GET ${target} HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
}

fn ms_of(target string) int {
	req := request_parser.decode_http_request(get(target)) or { panic(err) }
	return delay_ms(req)
}

fn test_delay_ms_reads_the_query() {
	assert ms_of('/delay?ms=300') == 300
	assert ms_of('/delay?ms=1') == 1
	assert ms_of('/delay?a=1&ms=40&b=2') == 40
	assert ms_of('/delay?ms=10000') == max_ms
}

fn test_delay_ms_defaults_and_caps() {
	assert ms_of('/delay') == default_ms
	assert ms_of('/delay?') == default_ms
	assert ms_of('/delay?ms=') == default_ms
	assert ms_of('/delay?ms=0') == default_ms
	assert ms_of('/delay?ms=abc') == default_ms
	assert ms_of('/delay?ms=-5') == default_ms
	assert ms_of('/delay?ms=12x') == default_ms
	assert ms_of('/delay?xms=50') == default_ms
	assert ms_of('/delay?ms=10001') == max_ms
	assert ms_of('/delay?ms=99999999999999999999999') == max_ms
}

fn test_route_is_ignores_the_query_only() {
	for target, want in {
		'/delay':        true
		'/delay?ms=5':   true
		'/delay/':       false
		'/delays':       false
		'/x/delay':      false
		'/x?next=delay': false
	} {
		req := request_parser.decode_http_request(get(target)) or { panic(err) }
		assert route_is(req, '/delay') == want, target
	}
}

// On the wire: the timer must use the requested delay. The old handler always
// waited 200 ms, so this lower bound failed for any ms above ~300.
fn test_delay_waits_the_requested_ms() ! {
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
			send: get('/delay?ms=500')
		}]
	}])!
	elapsed := time.ticks() - t0
	c := out.conns[0]
	assert c.connect_err == '', c.connect_err
	assert c.frames.len == 1
	assert c.frames[0].bytestr() == resp_delayed
	assert elapsed >= 500, 'answered after ${elapsed} ms, before the 500 ms timer'
}

fn test_other_paths_answer_at_once_and_bad_requests_close() ! {
	out := vtest.drive(server.ServerConfig{
		io_multiplexing: .epoll
		handler:         handle
	}, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: get('/')
				},
				vtest.Round{
					send: get('/delays')
				},
				vtest.Round{
					send: get('/delay?ms=1')
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
	assert c.frames.len == 3
	assert c.frames[0].bytestr() == resp_ok
	assert c.frames[1].bytestr() == resp_ok
	assert c.frames[2].bytestr() == resp_delayed
	bad := out.conns[1]
	assert bad.eof
	assert bad.frames.len == 1
	assert bad.frames[0] == response.tiny_bad_request_response
	assert out.inflight_after == 0
	assert out.active_after == 0
}
