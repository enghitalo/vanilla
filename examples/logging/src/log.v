module main

// The per-worker log: lines are formatted into a buffer on the request path
// (record) and drained by the worker's timer (tick), which writes them to the
// file (file.v) and queues them for the collector (ship.v).
import core
import strconv
import time
import tls
import sync.stdatomic
import http1_1.request_parser
import http1_1.upstream

#include <sys/timerfd.h>

fn C.timerfd_create(clockid int, flags int) int
fn C.timerfd_settime(fd int, flags int, new_value voidptr, old_value voidptr) int

// A line carries at most this many input bytes of a field (a longer one is
// cut), so its worst-case size is known before a byte is written: each input
// byte escapes to at most 6 (`\u00XX`, `\ufffd`).
const max_method = 32
const max_path = 2048
const max_ua = 512
// line_fixed bounds the rest of a line: keys, quotes, the timestamp and four
// numbers of at most 20 digits (183 bytes).
const line_fixed = 256

// Counts are what a worker did since its last tick, published to Shared.total
// at the tick (atomics, once per tick: the request path touches no shared
// memory).
struct Counts {
mut:
	lines         i64 // lines formatted
	dropped       i64 // lines that never reached the file: the buffer was full, or a write failed
	written       i64 // bytes written to the file
	write_errors  i64 // failed opens and writes
	reopens       i64 // reopens after SIGHUP or a rotation
	rotations     i64 // size rotations (worker 0)
	shipped       i64 // lines the collector accepted (2xx)
	ship_dropped  i64 // lines never shipped: the queue was full, or the collector refused the batch (4xx)
	ship_failures i64 // batches that failed (no answer, 5xx, 408, 429: retried)
}

// Shared is the process-wide half, built once by main before new_server: the
// configuration (read-only) and the atomics that the workers, the SIGHUP
// handler and the shutdown thread meet on. No worker ever waits on another.
@[heap]
struct Shared {
	path      string   // the log file; '' = none
	rotated   []string // path.1 … path.<keep>
	max_bytes i64      // rotate when the file reaches this size; 0 = never
	flush_ms  int = 200        // the tick: how long a line can wait in a worker's buffer
	buf_bytes int = 256 * 1024 // a worker's line buffer (never grown)
	flush_at  int = 64 * 1024  // a buffer this full kicks the tick at once
	// shipping (collector.host == '': off)
	collector   upstream.Origin
	tls_cfg     &tls.Config = unsafe { nil }
	target      string      = '/ingest'
	queue_bytes int         = 1024 * 1024 // a worker's shipping queue (never grown)
	batch_bytes int         = 256 * 1024  // at most this much NDJSON per POST
	retry_ms    int         = 500         // the first backoff after a failed batch (doubles, up to 30 s)
mut:
	reopen_gen i64    // SIGHUP and a rotation bump it: every worker reopens before its next write
	stop       i64    // set at shutdown: every worker flushes at its next tick and acks
	flushed    i64    // workers that acked
	workers    i64    // workers that ran make_state
	total      Counts // every worker's counts (atomic adds)
}

// Worker is one worker's log (its make_state value): only this worker's
// thread touches it, so nothing in it is locked.
@[heap]
struct Worker {
	sh &Shared = unsafe { nil }
	id int
mut:
	buf      []u8 // lines waiting for the tick; never grown past its cap
	lines    int  // lines in buf
	kicked   bool // the timer was asked to fire now
	timer_fd int = -1
	fd       int = -1 // the log file, this worker's own O_APPEND descriptor
	gen      i64 // the reopen_gen fd was opened at
	acked    bool
	sec      i64     // the second `ts` holds
	ts       [19]u8  // YYYY-MM-DDTHH:MM:SS for `sec`
	counts   Counts  // not yet published
	ship     Shipper // the collector link (ship.v)
	body     []u8    // /stats scratch
}

// new_worker builds one worker's state (make_state): every buffer at its
// final size, so the request path never allocates.
fn new_worker(sh &Shared) voidptr {
	mut w := &Worker{
		sh:   sh
		id:   int(stdatomic.add_i64(&sh.workers, 1)) - 1
		buf:  []u8{cap: sh.buf_bytes}
		body: []u8{cap: 512}
	}
	if sh.collector.host != '' {
		w.ship.pool = upstream.Pool.new(sh.collector, sh.tls_cfg) or { panic(err) }
		w.ship.q = []u8{cap: sh.queue_bytes}
	}
	return voidptr(w)
}

// on_worker_start arms this worker's timer, and the collector pool's
// maintenance (its deadlines and idle expiry), on the worker's own loop.
fn on_worker_start(worker_state voidptr, mut el core.EventLoop) {
	mut w := unsafe { &Worker(worker_state) }
	if w.ship.pool != unsafe { nil } {
		w.ship.pool.start_maintenance(mut el) or { eprintln('logging: ${err}') }
	}
	fd := C.timerfd_create(C.CLOCK_MONOTONIC, C.TFD_NONBLOCK | C.TFD_CLOEXEC)
	if fd < 0 {
		eprintln('logging: timerfd_create failed; worker ${w.id} keeps its lines')
		return
	}
	el.watch_fd(fd, .readable, tick, unsafe { nil })
	if el.last_watched != fd {
		C.close(fd)
		eprintln('logging: worker ${w.id} cannot watch a timer (the epoll plain worker can)')
		return
	}
	w.timer_fd = fd
	arm_timer(fd, w.sh.flush_ms, w.sh.flush_ms)
}

// record appends one JSON line for the request just answered into the
// worker's buffer. It never writes and never allocates: when the buffer has
// no room for the line's worst case (the tick is behind, a slow disk) the
// line is dropped and counted.
fn (mut w Worker) record(req []u8, method request_parser.Slice, path request_parser.Slice, ua request_parser.Slice, out []u8, start int, dur_ns u64) {
	m := if method.len < max_method { method.len } else { max_method }
	p := if path.len < max_path { path.len } else { max_path }
	u := if ua.len < max_ua { ua.len } else { max_ua }
	if w.buf.cap - w.buf.len < line_fixed + 6 * (m + p + u) {
		w.counts.dropped++
		w.kick()
		return
	}
	mut now := C.timespec{}
	C.clock_gettime(C.CLOCK_REALTIME, &now)
	if now.tv_sec != w.sec {
		w.set_second(now.tv_sec)
	}
	ms := now.tv_nsec / 1_000_000
	core.append_str(mut w.buf, '{"ts":"')
	unsafe { w.buf.push_many(&w.ts[0], w.ts.len) }
	w.buf << `.`
	w.buf << u8(48 + ms / 100)
	w.buf << u8(48 + ms / 10 % 10)
	w.buf << u8(48 + ms % 10)
	core.append_str(mut w.buf, 'Z","worker":')
	wi(mut w.buf, w.id)
	core.append_str(mut w.buf, ',"method":"')
	put_json_str(mut w.buf, req, method.start, m)
	core.append_str(mut w.buf, '","path":"')
	put_json_str(mut w.buf, req, path.start, p)
	core.append_str(mut w.buf, '","status":')
	wi(mut w.buf, status_of(out, start))
	core.append_str(mut w.buf, ',"bytes":')
	wi(mut w.buf, out.len - start)
	core.append_str(mut w.buf, ',"dur_us":')
	wi(mut w.buf, i64(dur_ns / 1000))
	core.append_str(mut w.buf, ',"ua":"')
	put_json_str(mut w.buf, req, ua.start, u)
	core.append_str(mut w.buf, '"}\n')
	w.lines++
	if w.buf.len >= w.sh.flush_at {
		w.kick()
	}
}

// status_of reads the status code at its fixed offset in the response the
// handler appended at `start` ("HTTP/1.1 NNN"); 0 if there is none.
@[direct_array_access]
fn status_of(out []u8, start int) int {
	if out.len - start < 12 {
		return 0
	}
	return int(out[start + 9] - `0`) * 100 + int(out[start + 10] - `0`) * 10 + int(out[start +
		11] - `0`)
}

const hex = '0123456789abcdef'

// put_json_str appends src[start..start + n] as the inside of a JSON string
// (RFC 8259 §7): `"` and `\` escaped, control bytes as \n \r \t or \u00XX,
// valid UTF-8 copied as is, and each byte of an invalid sequence as \ufffd,
// so a line is always valid JSON and a client can never start a new line in
// it. The caller has made room for 6 * n bytes.
@[direct_array_access]
fn put_json_str(mut buf []u8, src []u8, start int, n int) {
	if n <= 0 {
		return
	}
	unsafe {
		s := &src[start]
		mut d := &u8(buf.data) + buf.len
		mut i := 0
		for i < n {
			c := s[i]
			if c >= 0x20 && c < 0x80 && c != `"` && c != `\\` {
				*d = c
				d++
				i++
				continue
			}
			if c >= 0x80 {
				l := utf8_len(s, i, n)
				if l > 0 {
					vmemcpy(d, s + i, l)
					d += l
					i += l
				} else {
					vmemcpy(d, c'\\ufffd', 6)
					d += 6
					i++
				}
				continue
			}
			d[0] = `\\`
			match c {
				`"` {
					d[1] = `"`
					d += 2
				}
				`\\` {
					d[1] = `\\`
					d += 2
				}
				`\n` {
					d[1] = `n`
					d += 2
				}
				`\r` {
					d[1] = `r`
					d += 2
				}
				`\t` {
					d[1] = `t`
					d += 2
				}
				else {
					d[1] = `u`
					d[2] = `0`
					d[3] = `0`
					d[4] = hex[c >> 4]
					d[5] = hex[c & 15]
					d += 6
				}
			}
			i++
		}
		buf.len = int(d - &u8(buf.data))
	}
}

// utf8_len is the length of the well-formed UTF-8 sequence at s[i] (RFC 3629
// §4: no overlong forms, no surrogates, nothing past U+10FFFF), or 0.
@[direct_array_access]
fn utf8_len(s &u8, i int, n int) int {
	unsafe {
		c := s[i]
		mut l := 0
		mut lo := u8(0x80)
		mut hi := u8(0xbf)
		if c >= 0xc2 && c <= 0xdf {
			l = 2
		} else if c >= 0xe0 && c <= 0xef {
			l = 3
			if c == 0xe0 {
				lo = 0xa0
			} else if c == 0xed {
				hi = 0x9f
			}
		} else if c >= 0xf0 && c <= 0xf4 {
			l = 4
			if c == 0xf0 {
				lo = 0x90
			} else if c == 0xf4 {
				hi = 0x8f
			}
		} else {
			return 0
		}
		if i + l > n || s[i + 1] < lo || s[i + 1] > hi {
			return 0
		}
		for k in 2 .. l {
			if s[i + k] < 0x80 || s[i + k] > 0xbf {
				return 0
			}
		}
		return l
	}
}

// set_second formats `sec` (Unix time, UTC) as YYYY-MM-DDTHH:MM:SS into
// w.ts: once a second, not once a line. Days to a civil date with H. Hinnant's
// algorithm (no time.Time, no allocation).
fn (mut w Worker) set_second(sec i64) {
	w.sec = sec
	z := sec / 86400 + 719468
	era := z / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	day := doy - (153 * mp + 2) / 5 + 1
	month := if mp < 10 { mp + 3 } else { mp - 9 }
	year := if month <= 2 { yoe + era * 400 + 1 } else { yoe + era * 400 }
	rem := sec % 86400
	put_digits(mut w.ts, 0, year, 4)
	w.ts[4] = `-`
	put_digits(mut w.ts, 5, month, 2)
	w.ts[7] = `-`
	put_digits(mut w.ts, 8, day, 2)
	w.ts[10] = `T`
	put_digits(mut w.ts, 11, rem / 3600, 2)
	w.ts[13] = `:`
	put_digits(mut w.ts, 14, rem / 60 % 60, 2)
	w.ts[16] = `:`
	put_digits(mut w.ts, 17, rem % 60, 2)
}

fn put_digits(mut a [19]u8, at int, v i64, width int) {
	mut x := v
	for k := width - 1; k >= 0; k-- {
		a[at + k] = u8(48 + x % 10)
		x /= 10
	}
}

// wi appends n's decimal digits into `out`: strconv.write_dec writes at its
// buffer's index 0 (it does not append), so the digits go to a stack scratch
// first. No allocation, no `.str()`.
fn wi(mut out []u8, n i64) {
	mut scratch := [24]u8{}
	mut view := unsafe { (&scratch[0]).vbytes(scratch.len) }
	written := strconv.write_dec(n, mut view)
	if written > 0 {
		unsafe { out.push_many(&scratch[0], written) }
	}
}

// kick makes the timer fire now instead of at its next period: the buffer is
// filling faster than the period drains it. One timerfd_settime per kick (a
// buffer crossing flush_at), never one per line.
fn (mut w Worker) kick() {
	if w.kicked || w.timer_fd < 0 {
		return
	}
	w.kicked = true
	arm_timer(w.timer_fd, 0, w.sh.flush_ms)
}

// arm_timer fires the timer in first_ms (0: now), then every period_ms.
fn arm_timer(fd int, first_ms int, period_ms int) {
	mut spec := [4]i64{} // struct itimerspec: it_interval {sec, nsec}, it_value {sec, nsec}
	spec[0] = i64(period_ms / 1000)
	spec[1] = i64(period_ms % 1000) * 1_000_000
	spec[2] = i64(first_ms / 1000)
	spec[3] = i64(first_ms % 1000) * 1_000_000
	if first_ms <= 0 {
		spec[3] = 1 // an all-zero it_value disarms: 1 ns is "now"
	}
	C.timerfd_settime(fd, 0, unsafe { voidptr(&spec[0]) }, unsafe { nil })
}

// tick is the worker's timer: every flush_ms, or at once when kicked, it
// drains the line buffer (to the file, then into the shipping queue), lets
// worker 0 rotate the file, sends the next batch, publishes the counts, and
// at shutdown acks its final flush. It runs between requests on the worker's
// own loop and never waits on another worker.
fn tick(mut _ []u8, ready_fd int, _ bool, _ voidptr, worker_state voidptr, mut el core.EventLoop) core.Step {
	mut expirations := u64(0)
	C.read(ready_fd, &expirations, 8)
	mut w := unsafe { &Worker(worker_state) }
	w.kicked = false
	w.flush()
	if w.id == 0 && w.sh.max_bytes > 0 && w.sh.path != '' {
		w.check_rotation()
	}
	w.send_batch(mut el)
	w.publish()
	if !w.acked && stdatomic.load_i64(&w.sh.stop) != 0 {
		w.acked = true
		stdatomic.add_i64(&w.sh.flushed, 1)
	}
	// Last: the timer is the watch this run keeps (send_batch may have armed
	// the collector's socket before it).
	el.watch_fd(ready_fd, .readable, tick, unsafe { nil })
	return .suspend
}

// flush drains the line buffer to the file and into the shipping queue.
fn (mut w Worker) flush() {
	if w.buf.len == 0 {
		return
	}
	w.counts.lines += w.lines
	if w.sh.path != '' {
		w.write_file()
	}
	if w.ship.pool != unsafe { nil } {
		w.enqueue()
	}
	unsafe {
		w.buf.len = 0
	}
	w.lines = 0
}

// publish adds this worker's counts to the shared totals and zeroes them.
fn (mut w Worker) publish() {
	c := w.counts
	t := &w.sh.total
	add_count(&t.lines, c.lines)
	add_count(&t.dropped, c.dropped)
	add_count(&t.written, c.written)
	add_count(&t.write_errors, c.write_errors)
	add_count(&t.reopens, c.reopens)
	add_count(&t.rotations, c.rotations)
	add_count(&t.shipped, c.shipped)
	add_count(&t.ship_dropped, c.ship_dropped)
	add_count(&t.ship_failures, c.ship_failures)
	w.counts = Counts{}
}

@[inline]
fn add_count(total &i64, n i64) {
	if n != 0 {
		stdatomic.add_i64(total, int(n))
	}
}

// stats_json appends the totals as a JSON object (they lag by up to one
// tick: each worker publishes at its own).
fn (sh &Shared) stats_json(mut b []u8) {
	t := &sh.total
	core.append_str(mut b, '{"lines":')
	wi(mut b, stdatomic.load_i64(&t.lines))
	core.append_str(mut b, ',"dropped":')
	wi(mut b, stdatomic.load_i64(&t.dropped))
	core.append_str(mut b, ',"written":')
	wi(mut b, stdatomic.load_i64(&t.written))
	core.append_str(mut b, ',"write_errors":')
	wi(mut b, stdatomic.load_i64(&t.write_errors))
	core.append_str(mut b, ',"reopens":')
	wi(mut b, stdatomic.load_i64(&t.reopens))
	core.append_str(mut b, ',"rotations":')
	wi(mut b, stdatomic.load_i64(&t.rotations))
	core.append_str(mut b, ',"shipped":')
	wi(mut b, stdatomic.load_i64(&t.shipped))
	core.append_str(mut b, ',"ship_dropped":')
	wi(mut b, stdatomic.load_i64(&t.ship_dropped))
	core.append_str(mut b, ',"ship_failures":')
	wi(mut b, stdatomic.load_i64(&t.ship_failures))
	core.append_str(mut b, '}\n')
}

// final_flush asks every worker to flush at its next tick and waits until all
// of them acked, at most timeout_ms: a worker stuck on a dead disk must not
// hold the exit. A line recorded after its worker's ack is lost with the
// process.
fn (sh &Shared) final_flush(timeout_ms int) bool {
	stdatomic.store_i64(&sh.stop, 1)
	n := stdatomic.load_i64(&sh.workers)
	for _ in 0 .. timeout_ms {
		if stdatomic.load_i64(&sh.flushed) >= n {
			return true
		}
		time.sleep(time.millisecond)
	}
	return stdatomic.load_i64(&sh.flushed) >= n
}
