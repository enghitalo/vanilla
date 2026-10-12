module main

// Where a stream cannot be kept (a backend without takeover: kqueue, IOCP,
// io_uring; or a tcc build), a live server answers GET /events with 501 and
// closes, POST /broadcast still answers 200, and nothing breaks. This runs on
// every OS lane: on macOS (kqueue) and Windows (IOCP) with the example's own
// backend, on Linux on io_uring when the host has it (the epoll worker keeps
// streams: server_end_to_end_test.v).
import server
import vtest

const fallback_subscribe = 'GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()

const fallback_broadcast = 'POST /broadcast HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\nhi'.bytes()

fn test_events_is_501_without_takeover() ! {
	mut cfg := new_config(0, 1, new_hub(15_000))
	$if linux {
		if !server.iou_backend_available() {
			eprintln('[test] io_uring unavailable; skipping (Linux streams run on epoll)')
			return
		}
		cfg = server.ServerConfig{
			...cfg
			io_multiplexing: .io_uring
		}
	}
	out := vtest.drive(cfg, [
		vtest.Script{
			rounds:   [vtest.Round{
				send: fallback_subscribe
			}]
			then_eof: true
		},
		vtest.Script{
			rounds: [vtest.Round{
				send: fallback_broadcast
			}]
		},
	])!
	sub := out.conns[0]
	assert sub.connect_err == '', sub.connect_err
	assert sub.eof
	assert sub.raw.bytestr() == not_implemented
	ack := out.conns[1]
	assert ack.connect_err == '', ack.connect_err
	assert ack.frames.len == 1 && ack.frames[0].bytestr() == ok_response
}
