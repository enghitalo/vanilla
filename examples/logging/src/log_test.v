// vtest build: linux
module main

// In-process tests: the handler, the line format, the escaping, the file
// (flush, rotation, SIGHUP) and the tick, driven directly — no socket. The
// collector is tested end to end in ship_e2e_test.v.
import os
import json2
import time
import core
import sync.stdatomic

#include <signal.h>

fn C.raise(sig int) int

struct LogLine {
	ts     string
	worker int
	method string
	path   string
	status int
	bytes  int
	dur_us i64
	ua     string
}

fn scratch_dir(name string) string {
	dir := os.join_path(os.temp_dir(), 'vanilla_logging_${name}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn new_shared(path string, max_bytes i64, keep int) &Shared {
	return &Shared{
		path:      path
		rotated:   rotated_names(path, keep)
		max_bytes: max_bytes
	}
}

fn worker_of(sh &Shared) &Worker {
	return unsafe { &Worker(new_worker(sh)) }
}

// serve runs one raw request through the handler, as a worker would.
fn serve(mut w Worker, raw string) (string, core.Step) {
	mut out := []u8{cap: 1024}
	mut el := core.EventLoop{}
	step := handle(raw.bytes(), mut out, -1, voidptr(w), mut el)
	return out.bytestr(), step
}

fn get(path string, ua string) string {
	return 'GET ${path} HTTP/1.1\r\nHost: x\r\nUser-Agent: ${ua}\r\n\r\n'
}

fn buffered(w &Worker) []LogLine {
	mut lines := []LogLine{}
	for l in w.buf.bytestr().split_into_lines() {
		lines << json2.decode[LogLine](l) or { panic('not JSON: ${l}') }
	}
	return lines
}

fn file_lines(path string) []string {
	return (os.read_file(path) or { '' }).split_into_lines()
}

fn test_one_json_line_per_request() {
	mut w := worker_of(new_shared('', 0, 1))
	resp, step := serve(mut w, get('/', 'curl/8.5.0'))
	assert step == .done
	assert resp == resp_hello
	serve(mut w, get('/nope?q=1', 'curl/8.5.0'))
	serve(mut w, 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n')
	bad, bad_step := serve(mut w, 'garbage\r\n\r\n')
	assert bad_step == .close
	assert bad.starts_with('HTTP/1.1 400')
	assert w.lines == 4
	lines := buffered(w)
	assert lines.len == 4
	assert lines[0].method == 'GET'
	assert lines[0].path == '/'
	assert lines[0].status == 200
	assert lines[0].bytes == resp_hello.len
	assert lines[0].ua == 'curl/8.5.0'
	assert lines[0].worker == 0
	assert lines[0].dur_us >= 0
	assert lines[1].path == '/nope?q=1'
	assert lines[1].status == 404
	assert lines[2].method == 'POST'
	assert lines[2].status == 405
	assert lines[2].ua == ''
	assert lines[3].status == 400
	// The timestamp is RFC 3339 UTC with milliseconds, and it is now.
	ts := lines[0].ts
	assert ts.len == 24 && ts[10] == `T` && ts.ends_with('Z')
	t := time.parse_rfc3339(ts) or { panic(err) }
	skew := time.utc().unix() - t.unix()
	assert skew >= -5 && skew <= 5
}

fn test_timestamp_matches_the_calendar() {
	mut w := worker_of(new_shared('', 0, 1))
	// The epoch, leap days, century years, and a sweep over four centuries.
	mut secs := [i64(0), 951782400, 951868799, 1709251199, 4102444800, 4107542399]
	for s := i64(12345); s < 13_000_000_000; s += 86400 * 37 + 4321 {
		secs << s
	}
	for s in secs {
		w.set_second(s)
		got := unsafe { tos(&w.ts[0], w.ts.len) }
		want := time.unix(s).format_rfc3339()[..19]
		assert got == want, 'second ${s}'
	}
}

fn escaped(s string) string {
	mut b := []u8{cap: 6 * s.len + 1}
	put_json_str(mut b, s.bytes(), 0, s.len)
	return b.bytestr()
}

fn test_json_escaping() {
	assert escaped('/plain/path?a=1&b=2') == '/plain/path?a=1&b=2'
	assert escaped('a"b\\c') == 'a\\"b\\\\c'
	assert escaped('\x01\n\r\t\x1f\x7f') == '\\u0001\\n\\r\\t\\u001f\x7f'
	// Valid UTF-8 is copied as is (2, 3 and 4 bytes).
	assert escaped('é€😀') == 'é€😀'
	// Each byte of an ill-formed sequence becomes U+FFFD: a stray byte, an
	// overlong form, a surrogate, past U+10FFFF, a truncated sequence.
	bad := [u8(0xff), 0xc0, 0xaf, 0xed, 0xa0, 0x80, 0xf4, 0x90, 0x80, 0x80, 0xe2, 0x82]
	mut out := []u8{cap: 6 * bad.len}
	put_json_str(mut out, bad, 0, bad.len)
	assert out.bytestr() == '\\ufffd'.repeat(bad.len)
	// A window into a larger buffer.
	mut win := []u8{cap: 64}
	put_json_str(mut win, 'xx"yy'.bytes(), 2, 2)
	assert win.bytestr() == '\\"y'
	// Whatever goes in, the result is a valid JSON string.
	for s in ['a"b\\c', '\x01\n\x1f', 'é€😀', bad.bytestr(), '\xe2\x82\xac\xe2\x82'] {
		decoded := json2.decode[string]('"' + escaped(s) + '"') or { panic('${s}: ${err}') }
		assert decoded.len > 0
	}
}

fn test_hostile_fields_stay_one_valid_line() {
	mut w := worker_of(new_shared('', 0, 1))
	// A user agent with quotes, backslashes, a tab and invalid UTF-8; a
	// path at the cap and beyond.
	ua := 'evil"\\ua\t\xff\xfe end'
	serve(mut w, get('/x', ua))
	long := '/' + 'a'.repeat(max_path + 100)
	serve(mut w, get(long, 'u'))
	assert w.buf.bytestr().count('\n') == 2
	lines := buffered(w)
	assert lines[0].ua == 'evil"\\ua\t\ufffd\ufffd end'
	assert lines[1].path.len == max_path
	assert lines[1].status == 404
}

fn test_flush_writes_whole_lines_from_every_worker() {
	dir := scratch_dir('flush')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'access.log')
	sh := new_shared(path, 0, 1)
	mut w0 := worker_of(sh)
	mut w1 := worker_of(sh)
	assert w1.id == 1
	for i in 0 .. 30 {
		serve(mut w0, get('/a/${i}', 'w0'))
		serve(mut w1, get('/b/${i}', 'w1'))
	}
	w0.flush()
	w1.flush()
	w0.publish()
	w1.publish()
	assert w0.buf.len == 0 && w1.buf.len == 0
	lines := file_lines(path)
	assert lines.len == 60
	mut per := [0, 0]
	for l in lines {
		ll := json2.decode[LogLine](l) or { panic('not JSON: ${l}') }
		per[ll.worker]++
	}
	assert per == [30, 30]
	assert stdatomic.load_i64(&sh.total.lines) == 60
	assert stdatomic.load_i64(&sh.total.written) == os.file_size(path)
	assert stdatomic.load_i64(&sh.total.dropped) == 0
}

fn test_full_buffer_drops_and_counts() {
	sh := &Shared{
		path:      ''
		buf_bytes: 4096
	}
	mut w := worker_of(sh)
	for _ in 0 .. 100 {
		serve(mut w, get('/', 'ua'))
	}
	kept := w.lines
	assert kept > 0 && kept < 100
	assert w.counts.dropped == 100 - kept
	assert w.buf.len <= w.buf.cap // never grown
	assert w.buf.cap == 4096
	assert buffered(w).len == kept // only whole lines
	w.flush()
	w.publish()
	resp, _ := serve(mut w, get('/stats', 'ua'))
	assert resp.contains('"lines":${kept},"dropped":${100 - kept},')
}

fn test_rotation_by_size_keeps_n_files() {
	dir := scratch_dir('rotate')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'access.log')
	sh := new_shared(path, 2000, 2)
	mut w0 := worker_of(sh)
	mut w1 := worker_of(sh)
	for round in 0 .. 12 {
		for i in 0 .. 5 {
			serve(mut w0, get('/r${round}/${i}', 'w0'))
			serve(mut w1, get('/r${round}/${i}', 'w1'))
		}
		w0.flush()
		w1.flush()
		w0.check_rotation() // what worker 0's tick does after its flush
	}
	// The live file is reopened lazily, by each worker's next write.
	serve(mut w0, get('/final', 'w0'))
	serve(mut w1, get('/final', 'w1'))
	w0.flush()
	w1.flush()
	w0.publish()
	w1.publish()
	assert os.exists(path + '.1')
	assert os.exists(path + '.2')
	assert !os.exists(path + '.3')
	rotations := stdatomic.load_i64(&sh.total.rotations)
	assert rotations >= 3
	assert stdatomic.load_i64(&sh.total.reopens) >= 2 * rotations - 1
	// A rotated file reached the limit; every file holds whole JSON lines.
	assert os.file_size(path + '.1') >= 2000
	assert os.file_size(path + '.2') >= 2000
	for f in [path, path + '.1', path + '.2'] {
		content := os.read_file(f) or { panic(err) }
		assert content.ends_with('\n')
		for l in content.split_into_lines() {
			json2.decode[LogLine](l) or { panic('${f}: not JSON: ${l}') }
		}
	}
	// Both workers reopened the fresh file after the last rotation.
	live := file_lines(path)
	assert live.len >= 2
	assert live.any(it.contains('"worker":0') && it.contains('"path":"/final"'))
	assert live.any(it.contains('"worker":1') && it.contains('"path":"/final"'))
}

fn test_sighup_reopens_after_a_rename() ! {
	dir := scratch_dir('hup')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'access.log')
	sh := new_shared(path, 0, 1)
	install_reopen_on_hup(sh)!
	mut w := worker_of(sh)
	serve(mut w, get('/before', 'ua'))
	w.flush()
	// logrotate: move the file away, then SIGHUP.
	os.mv(path, path + '.old')!
	serve(mut w, get('/between', 'ua')) // still goes to the moved file: not lost
	w.flush()
	C.raise(C.SIGHUP)
	assert stdatomic.load_i64(&sh.reopen_gen) == 1
	serve(mut w, get('/after', 'ua'))
	w.flush()
	w.publish()
	old := file_lines(path + '.old')
	assert old.len == 2
	assert old[0].contains('"path":"/before"')
	assert old[1].contains('"path":"/between"')
	now := file_lines(path)
	assert now.len == 1
	assert now[0].contains('"path":"/after"')
	assert stdatomic.load_i64(&sh.total.reopens) == 1
}

fn fake_register(mut el core.EventLoop, fd int, _ core.WatchInterest, _ core.WakeFn, _ voidptr) {
	el.last_watched = fd
}

fn test_tick_flushes_rearms_and_acks_shutdown() {
	dir := scratch_dir('tick')
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'access.log')
	sh := new_shared(path, 0, 1)
	mut w0 := worker_of(sh)
	mut w1 := worker_of(sh)
	serve(mut w0, get('/0', 'ua'))
	serve(mut w1, get('/1', 'ua'))
	assert !sh.final_flush(1) // nobody ticked: no ack
	mut el := core.EventLoop{
		register: fake_register
	}
	mut scratch := []u8{}
	for w in [w0, w1] {
		assert tick(mut scratch, 1234, false, unsafe { nil }, voidptr(w), mut el) == .suspend
		assert el.last_watched == 1234 // the timer keeps its watch
	}
	assert stdatomic.load_i64(&sh.flushed) == 2
	assert sh.final_flush(1)
	assert file_lines(path).len == 2
	assert stdatomic.load_i64(&sh.total.lines) == 2
}

fn test_kick_fires_the_timer_once() {
	mut w := worker_of(&Shared{
		path:     ''
		flush_at: 600
		flush_ms: 60_000
	})
	tfd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC)
	assert tfd >= 0
	defer {
		C.close(tfd)
	}
	w.timer_fd = tfd
	arm_timer(tfd, 60_000, 60_000)
	for w.buf.len < 600 {
		serve(mut w, get('/', 'ua'))
	}
	assert w.kicked // passing flush_at asked for an early tick ...
	time.sleep(5 * time.millisecond)
	mut n := u64(0)
	assert C.read(tfd, &n, 8) == 8 // ... and the timer fired, long before its period
	assert n == 1
}

fn test_enqueue_keeps_whole_lines_and_counts_the_rest() {
	mut w := worker_of(new_shared('', 0, 1))
	w.ship.q = []u8{cap: 700}
	for i in 0 .. 10 {
		serve(mut w, get('/${i}', 'ua'))
	}
	total := w.lines
	w.enqueue()
	q := w.ship.q.bytestr()
	assert q.len <= 700 && q.ends_with('\n')
	queued := q.count('\n')
	assert queued > 0 && queued < total
	assert w.counts.ship_dropped == total - queued
	assert w.ship.q.cap == 700 // never grown
}

fn test_settle_consumes_retries_or_drops() {
	mut w := worker_of(&Shared{
		path:     ''
		retry_ms: 100
	})
	w.ship.q = []u8{cap: 256}
	w.ship.q << 'one\ntwo\nthree\n'.bytes()
	// 503: kept for a retry, with a doubling backoff.
	w.ship.sent = 8 // 'one\ntwo\n'
	w.ship.status = 503
	w.settle(1000)
	assert w.ship.q.bytestr() == 'one\ntwo\nthree\n'
	assert w.ship.backoff_ms == 100
	assert w.ship.retry_at == 1000 + 100 * u64(time.millisecond)
	w.ship.status = 0 // no answer
	w.settle(1000)
	assert w.ship.backoff_ms == 200
	for _ in 0 .. 20 {
		w.settle(1000)
	}
	assert w.ship.backoff_ms == max_backoff_ms
	assert w.counts.ship_failures == 22
	// 202: consumed and counted.
	w.ship.status = 202
	w.settle(1000)
	assert w.ship.q.bytestr() == 'three\n'
	assert w.counts.shipped == 2
	assert w.ship.backoff_ms == 0 && w.ship.retry_at == 0
	// 400: never accepted, so dropped (and counted) instead of retried forever.
	w.ship.sent = 6
	w.ship.status = 400
	w.settle(1000)
	assert w.ship.q.len == 0
	assert w.counts.ship_dropped == 1
}

// The point of the design: recording a line, the routes, the flush to the
// file, the kick and the publish allocate nothing, as a worker would run them
// for every request and every tick. (Under `-gc none`, vanilla's production
// build, any allocation here would be a permanent leak.)
fn test_logging_allocates_nothing() {
	$if gcboehm ? {
		dir := scratch_dir('alloc')
		defer {
			os.rmdir_all(dir) or {}
		}
		path := os.join_path(dir, 'access.log')
		sh := &Shared{
			path:     path
			rotated:  rotated_names(path, 1)
			flush_at: 16 * 1024
		}
		mut w := worker_of(sh)
		tfd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC)
		defer {
			C.close(tfd)
		}
		w.timer_fd = tfd
		reqs := [
			get('/', 'curl/8.5.0'),
			get('/healthz', 'kube-probe/1.30'),
			get('/stats', 'prometheus'),
			get('/nope?x="y"', 'evil"\\\x01\xff'),
			'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n',
			'garbage\r\n\r\n',
		].map(it.bytes())
		mut out := []u8{cap: 4096}
		mut el := core.EventLoop{}
		round := fn [reqs] (mut w Worker, mut out []u8, mut el core.EventLoop) {
			for r in reqs {
				unsafe {
					out.len = 0
				}
				handle(r, mut out, -1, voidptr(w), mut el)
			}
			if w.kicked {
				w.kicked = false
				w.flush()
				w.publish()
			}
		}
		for _ in 0 .. 200 { // warm-up: buffers reach their high-water marks
			round(mut w, mut out, mut el)
		}
		rounds := 5000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			round(mut w, mut out, mut el)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'logging allocated ${grown} bytes over ${rounds * reqs.len} requests'
		w.flush()
		assert file_lines(path).len == (rounds + 200) * reqs.len
	}
}
