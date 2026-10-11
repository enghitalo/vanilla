// vtest build: linux
module main

// End-to-end tests of the shipping path: the logging server (epoll, one
// worker, its timer and its upstream pool) against a fake collector that runs
// on a thread of this test. Every request is answered while the collector is
// healthy, refuses connections, answers 503, or never answers; what the
// collector accepted and what was dropped is checked against the counts.
import os
import net
import sync
import time
import json2
import server
import vtest
import sync.stdatomic
import http1_1.upstream

struct LogLine {
	path   string
	status int
	ua     string
}

// Collector is a fake log collector: it reads NDJSON POSTs on 127.0.0.1 and
// answers each with the next status of its script (then 200), or, while
// `hang` is set, never.
@[heap]
struct Collector {
mut:
	mu       &sync.Mutex      = sync.new_mutex()
	l        &net.TcpListener = unsafe { nil }
	port     int
	accepted int      // connections
	posts    int      // requests read
	lines    []string // the lines of the batches answered 2xx
	script   []int
	hang     bool
	stopped  bool
}

fn start_collector(script []int, hang bool) !&Collector {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	l.set_accept_timeout(50 * time.millisecond)
	mut c := &Collector{
		l:      l
		port:   int(l.addr()!.port()!)
		script: script
		hang:   hang
	}
	spawn c.accept_loop()
	return c
}

fn (mut c Collector) accept_loop() {
	for {
		c.mu.lock()
		stopped := c.stopped
		c.mu.unlock()
		if stopped {
			return
		}
		mut conn := c.l.accept() or { continue }
		c.mu.lock()
		c.accepted++
		c.mu.unlock()
		spawn c.serve(mut conn)
	}
}

// serve answers the requests of one connection, in order (keep-alive).
fn (mut c Collector) serve(mut conn net.TcpConn) {
	conn.set_read_timeout(10 * time.second)
	mut acc := []u8{}
	mut buf := []u8{len: 65536}
	for {
		mut head_end := -1
		mut end := -1
		for {
			if head_end < 0 {
				s := acc.bytestr()
				if i := s.index('\r\n\r\n') {
					head_end = i + 4
					cl := s[..i].to_lower().all_after('content-length:').all_before('\r\n').trim_space().int()
					end = head_end + cl
				}
			}
			if head_end >= 0 && acc.len >= end {
				break
			}
			n := conn.read(mut buf) or { 0 }
			if n <= 0 {
				conn.close() or {}
				return
			}
			acc << buf[..n]
		}
		body := acc[head_end..end].bytestr()
		acc = acc[end..].clone()
		c.mu.lock()
		c.posts++
		status := if c.posts <= c.script.len { c.script[c.posts - 1] } else { 200 }
		hang := c.hang
		if !hang && status / 100 == 2 {
			c.lines << body.split_into_lines()
		}
		c.mu.unlock()
		if hang {
			// Never answered: wait for the client to give up (or the timeout).
			conn.read(mut buf) or {}
			conn.close() or {}
			return
		}
		conn.write('HTTP/1.1 ${status} X\r\nContent-Length: 0\r\n\r\n'.bytes()) or { return }
	}
}

fn (mut c Collector) set_hang(v bool) {
	c.mu.lock()
	c.hang = v
	c.mu.unlock()
}

// snapshot is (connections, posts, accepted lines).
fn (mut c Collector) snapshot() (int, int, []string) {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	return c.accepted, c.posts, c.lines.clone()
}

fn (mut c Collector) stop() {
	c.mu.lock()
	c.stopped = true
	c.mu.unlock()
}

fn shipping(path string, port int, queue_bytes int, response_timeout_ms int) &Shared {
	return &Shared{
		path:        path
		rotated:     rotated_names(path, 1)
		flush_ms:    20
		retry_ms:    10
		queue_bytes: queue_bytes
		collector:   upstream.Origin{
			host:                '127.0.0.1'
			port:                port
			https:               false
			max_conns:           1
			connect_timeout_ms:  1000
			response_timeout_ms: response_timeout_ms
		}
	}
}

fn start_server(sh &Shared) !&vtest.Harness {
	return vtest.start(server.ServerConfig{
		handler:         handle
		workers:         1
		make_state:      fn [sh] () voidptr {
			return new_worker(sh)
		}
		on_worker_start: on_worker_start
	})
}

fn requests(n int, path string) []vtest.Script {
	return vtest.repeat(n, vtest.Script{
		rounds: [
			vtest.Round{
				send: 'GET ${path} HTTP/1.1\r\nHost: x\r\nUser-Agent: e2e\r\n\r\n'.bytes()
			},
		]
	})
}

// wait_until polls cond for up to ms milliseconds.
fn wait_until(ms int, cond fn () bool) bool {
	for _ in 0 .. ms / 5 {
		if cond() {
			return true
		}
		time.sleep(5 * time.millisecond)
	}
	return cond()
}

fn count(sh &Shared, field string) i64 {
	t := &sh.total
	return match field {
		'shipped' { stdatomic.load_i64(&t.shipped) }
		'ship_dropped' { stdatomic.load_i64(&t.ship_dropped) }
		'ship_failures' { stdatomic.load_i64(&t.ship_failures) }
		'lines' { stdatomic.load_i64(&t.lines) }
		'dropped' { stdatomic.load_i64(&t.dropped) }
		else { -1 }
	}
}

fn scratch_file(name string) string {
	dir := os.join_path(os.temp_dir(), 'vanilla_logging_${name}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return os.join_path(dir, 'access.log')
}

fn all_answered(o vtest.Outcome) bool {
	return o.conns.all(it.frames.len == 1 && it.frames[0].bytestr().starts_with('HTTP/1.1 404'))
}

fn test_ships_every_line_over_one_kept_connection() {
	mut c := start_collector([], false)!
	defer {
		c.stop()
	}
	path := scratch_file('ship')
	defer {
		os.rmdir_all(os.dir(path)) or {}
	}
	sh := shipping(path, c.port, 1024 * 1024, 2000)
	mut h := start_server(sh)!
	defer {
		h.stop()
	}
	assert all_answered(h.fire(requests(20, '/a'))!)
	assert wait_until(5000, fn [sh] () bool {
		return count(sh, 'shipped') >= 20
	})
	// A second wave after the first batch was answered: it goes out on the
	// same kept connection (the batch's continuation never closes it).
	assert all_answered(h.fire(requests(20, '/b'))!)
	assert wait_until(5000, fn [sh] () bool {
		return count(sh, 'shipped') >= 40
	})
	accepted, posts, lines := c.snapshot()
	assert lines.len == 40
	assert posts >= 2
	assert accepted == 1
	mut a := 0
	for l in lines {
		ll := json2.decode[LogLine](l) or { panic('not JSON: ${l}') }
		assert ll.status == 404 && ll.ua == 'e2e'
		if ll.path == '/a' {
			a++
		}
	}
	assert a == 20
	assert count(sh, 'shipped') == 40
	assert count(sh, 'ship_failures') == 0
	assert count(sh, 'ship_dropped') == 0
	// The file has every line too (written before it was queued).
	assert (os.read_file(path) or { '' }).count('\n') == 40
}

fn test_collector_down_never_blocks_and_counts_the_drops() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	dead_port := int(l.addr()!.port()!)
	l.close()! // nothing listens there now: every connect is refused
	path := scratch_file('down')
	defer {
		os.rmdir_all(os.dir(path)) or {}
	}
	sh := shipping(path, dead_port, 1024, 2000) // a queue of a few lines
	mut h := start_server(sh)!
	defer {
		h.stop()
	}
	assert all_answered(h.fire(requests(60, '/down'))!)
	assert wait_until(5000, fn [sh] () bool {
		return count(sh, 'ship_failures') >= 1 && count(sh, 'ship_dropped') > 0
			&& count(sh, 'lines') == 60
	})
	assert count(sh, 'shipped') == 0
	// The file is the source of truth: nothing is missing there.
	assert count(sh, 'dropped') == 0
	assert (os.read_file(path) or { '' }).count('\n') == 60
}

fn test_a_5xx_batch_is_retried_until_accepted() {
	mut c := start_collector([503, 503], false)!
	defer {
		c.stop()
	}
	sh := shipping('', c.port, 1024 * 1024, 2000)
	mut h := start_server(sh)!
	defer {
		h.stop()
	}
	assert all_answered(h.fire(requests(10, '/retry'))!)
	assert wait_until(5000, fn [sh] () bool {
		return count(sh, 'shipped') >= 10
	})
	_, posts, lines := c.snapshot()
	assert lines.len == 10 // the refused batches were not counted twice
	assert posts >= 3
	assert count(sh, 'ship_failures') == 2
	assert count(sh, 'ship_dropped') == 0
}

fn test_a_hung_collector_times_out_and_the_batch_is_sent_again() {
	mut c := start_collector([], true)!
	defer {
		c.stop()
	}
	sh := shipping('', c.port, 1024 * 1024, 200)
	mut h := start_server(sh)!
	defer {
		h.stop()
	}
	// The worker answers while its batch waits on a collector that never
	// answers ...
	assert all_answered(h.fire(requests(10, '/hang'))!)
	assert all_answered(h.fire(requests(10, '/hang'))!)
	// ... until the pool's deadline fails the batch.
	assert wait_until(5000, fn [sh] () bool {
		return count(sh, 'ship_failures') >= 1
	})
	assert count(sh, 'shipped') == 0
	c.set_hang(false)
	assert wait_until(5000, fn [sh] () bool {
		return count(sh, 'shipped') >= 20
	})
	_, _, lines := c.snapshot()
	assert lines.len == 20
}
