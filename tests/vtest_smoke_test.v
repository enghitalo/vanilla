// Smoke tests for the vtest module itself (docs/VTEST.md), against the
// platform-default backend. Standalone on purpose: vtest imports http_server,
// so these tests live outside the http_server module (no import cycle) and use
// only public API. No ports (always ephemeral), no timeouts (the only clock in
// this file is the server's own Limits, in the stall test), no readiness
// plumbing (drive/start own the lifecycle).
import http_server
import http_server.core
import http_server.http1_1.request_parser
import http_server.http1_1.response
import vtest

const get_root = 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
const get_missing = 'GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
const malformed = 'GET/HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

const ok_response = 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK'.bytes()
const notfound_response = 'HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: keep-alive\r\n\r\nNot Found'.bytes()

// Mirrors the real example routers: parseable requests are answered keep-alive,
// a request the parser rejects gets 400 + .close.
fn smoke_handler(req []u8, mut res []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step {
	request_parser.decode_http_request(req) or {
		res << response.tiny_bad_request_response
		return .close
	}
	if req.bytestr().contains('/notfound') {
		res << notfound_response
		return .done
	}
	res << ok_response
	return .done
}

fn pipeline(req []u8, n int) []u8 {
	mut out := []u8{cap: req.len * n}
	for _ in 0 .. n {
		out << req
	}
	return out
}

// 64 concurrent connections, each pipelining 8 requests in one write: 512
// responses, spread across every worker. Position = identity, order per conn
// guaranteed by HTTP/1.1.
fn test_pipelined_storm() ! {
	out := vtest.drive(http_server.ServerConfig{ handler: smoke_handler }, vtest.repeat(64, vtest.Script{
		rounds: [vtest.Round{
			send: pipeline(get_root, 8)
			want: 8
		}]
	}))!
	assert out.conns.len == 64
	for c in out.conns {
		assert c.connect_err == '', c.connect_err
		assert c.frames.len == 8
		for f in c.frames {
			assert f.bytestr().starts_with('HTTP/1.1 200')
		}
	}
	assert out.inflight_after == 0
}

// Heterogeneous traffic in one shot: plain 200, a 404, a pipeliner, and a
// malformed request the router answers 400 + close. All concurrent; each
// asserted by its script index.
fn test_mixed_traffic() ! {
	out := vtest.drive(http_server.ServerConfig{ handler: smoke_handler }, [
		vtest.Script{
			rounds: [vtest.Round{
				send: get_root
			}]
		},
		vtest.Script{
			rounds: [vtest.Round{
				send: get_missing
			}]
		},
		vtest.Script{
			rounds: [vtest.Round{
				send: pipeline(get_root, 3)
				want: 3
			}]
		},
		vtest.Script{
			rounds:   [vtest.Round{
				send: malformed
			}]
			then_eof: true
		},
	])!
	assert out.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200')
	assert out.conns[1].frames[0].bytestr().starts_with('HTTP/1.1 404')
	assert out.conns[2].frames.len == 3
	assert out.conns[3].frames[0].bytestr().starts_with('HTTP/1.1 400')
	assert out.conns[3].eof, 'router returned .close — the server must close after the 400'
	assert out.inflight_after == 0
}

// Rounds sequence WITHIN a connection: the second request goes out only after
// the first response arrived (the keep-alive reuse contract, kqueue-safe).
fn test_keep_alive_rounds() ! {
	out := vtest.drive(http_server.ServerConfig{ handler: smoke_handler }, [
		vtest.Script{
			rounds: [
				vtest.Round{
					send: get_root
				},
				vtest.Round{
					send: get_missing
				},
			]
		},
	])!
	assert out.conns[0].frames.len == 2
	assert out.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200')
	assert out.conns[0].frames[1].bytestr().starts_with('HTTP/1.1 404')
}

// Half-close (RFC 9112 §9.6): client sends the request then SHUT_WR; the
// response must still arrive.
fn test_half_close_still_answered() ! {
	out := vtest.drive(http_server.ServerConfig{ handler: smoke_handler }, [
		vtest.Script{
			rounds:  [vtest.Round{
				send: get_root
			}]
			shut_wr: true
		},
	])!
	assert out.conns[0].frames.len == 1
	assert out.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 200')
}

// 16 stalled (slowloris) connections. want: 0 = fire-and-forget; then_eof means
// completion can ONLY come from the server's own read_timeout reaper — the one
// and only clock in this test, per the design contract.
fn test_stalled_conns_reaped_by_server_clock() ! {
	out := vtest.drive(http_server.ServerConfig{
		handler: smoke_handler
		limits:  http_server.Limits{
			read_timeout_ms: 400
		}
	}, vtest.repeat(16, vtest.Script{
		rounds:   [vtest.Round{
			send: 'GET / HTTP/1.1\r\nHos'.bytes()
			want: 0
		}]
		then_eof: true
	}))!
	for c in out.conns {
		assert c.eof, 'server read_timeout must close a stalled connection'
		assert !c.unmet
	}
}

// Session form: fire() twice with completion-based ordering, then wait() adds a
// late expectation on still-open connections. The second fire only starts after
// the first group finished — no sleeps anywhere.
fn test_session_fire_then_wait() ! {
	mut h := vtest.start(http_server.ServerConfig{ handler: smoke_handler })!
	defer { h.stop() }

	first := h.fire(vtest.repeat(4, vtest.Script{
		rounds: [vtest.Round{
			send: get_root
		}]
	}))!
	assert first.conns.all(it.frames.len == 1)

	second := h.fire([vtest.Script{
		rounds: [vtest.Round{
			send: get_missing
		}]
	}])!
	assert second.conns[0].frames[0].bytestr().starts_with('HTTP/1.1 404')

	// A late expectation over still-open connections, expressed as a wait()
	// predicate — the same mechanism SSE tests use for pushed events.
	third := h.fire(vtest.repeat(2, vtest.Script{
		rounds: [vtest.Round{
			send: pipeline(get_root, 2)
			want: 2
		}]
	}))!
	got := h.wait(third.group, vtest.frames(2))!
	assert got.conns.all(it.frames.len == 2)
}
