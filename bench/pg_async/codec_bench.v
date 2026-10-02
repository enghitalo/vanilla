module main

// pg_async codec micro-benchmark — the per-query CPU cost of the native
// PostgreSQL client WITHOUT a server: query serialization, reply framing,
// row iteration and the binary decoders. Replies are canned bytes in the
// async-db shape (9 columns, 10 rows per query), fed through a socketpair(2)
// so async_on_readable runs its real recv + framing path. Build with the
// benchmark hooks (`-d pg_async_bench`) and drive ONE phase per run through
// bench/measure.sh (pinned core, min / median / spread):
//
//   v -prod -gc none -d pg_async_bench -o /tmp/pgcodec bench/pg_async/codec_bench.v
//   bench/measure.sh /tmp/pgcodec submit   # async_submit: 8 pipelined queries
//   bench/measure.sh /tmp/pgcodec frame    # submit + the replies' socketpair
//                                          # write + recv + framing
//   bench/measure.sh /tmp/pgcodec rows     # Result.rows() + every accessor
//   bench/measure.sh /tmp/pgcodec decode   # the decoders alone
//
// `frame` minus `submit` per query is the framing plus this harness writing
// the canned replies into the socketpair (a real server's kernel does that
// part). BENCH_ITERS overrides the work per phase, in that phase's unit:
// queries (submit, frame; rounded to whole rounds of 8), rows (rows) or decoder
// calls (decode). The default (no argument) is `all`: every phase once, each
// timed. bench/ci_bench.sh A/Bs submit, frame and rows, one phase per run.
// Under -gc none a phase that allocated per query would show in the RSS
// printed at the end.
import benchmark
import os
import pg_async

#include <sys/socket.h>

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int
fn C.send(fd int, buf voidptr, len usize, flags int) int

const depth = 8 // queries per round: pg_async's max_inflight

const rows_per_query = 10

const query = 'select id, name, category, price, quantity, active, tags, rating_score, rating_count from items where price between $1 and $2 limit $3'

fn main() {
	phase := if os.args.len > 1 { os.args[1] } else { 'all' }
	if phase !in ['submit', 'frame', 'rows', 'decode', 'all'] {
		eprintln('usage: codec_bench [submit|frame|rows|decode|all]')
		exit(2)
	}
	reply := canned_reply()
	mut acc := u64(0)
	mut b := benchmark.start()
	if phase in ['submit', 'all'] {
		queries := iters(800_000)
		acc += bench_submit(queries / depth)
		b.measure('submit: ${queries} async_submit, ${depth} per round')
	}
	if phase in ['frame', 'all'] {
		queries := iters(400_000)
		acc += bench_frame(reply, queries / depth)
		b.measure('frame:  ${queries} queries, ${depth} per round (submit + recv + framing)')
	}
	if phase in ['rows', 'all'] {
		rows := iters(3_000_000)
		acc += bench_rows(reply, rows / rows_per_query)
		b.measure('rows:   ${rows} rows x 9 columns')
	}
	if phase in ['decode', 'all'] {
		calls := iters(50_000_000)
		acc += bench_decode(calls / 7)
		b.measure('decode: ${calls} decoder calls')
	}
	println('acc=${acc} (ignore; keeps the optimizer honest)')
	println('VmRSS: ${vm_rss_kib()} KiB')
}

// iters is BENCH_ITERS when set, else the phase's default amount of work.
fn iters(dflt int) int {
	n := os.getenv('BENCH_ITERS').int()
	return if n > 0 { n } else { dflt }
}

fn params() []?[]u8 {
	return [?[]u8('10'.bytes()), ?[]u8('60'.bytes()), ?[]u8('10'.bytes())]
}

// bench_submit: async_submit's serialization (Parse/Bind/Describe/Execute/
// Sync into the per-connection scratch, then into the send buffer) and its
// in-flight bookkeeping, `depth` queries per round, nothing sent.
fn bench_submit(rounds int) u64 {
	fds := pair()
	mut c := pg_async.bench_conn_on_fd(fds[0])
	ps := params()
	mut acc := u64(0)
	for _ in 0 .. rounds {
		for _ in 0 .. depth {
			if !c.async_submit(query, ps) {
				panic('submit shed')
			}
		}
		acc += u64(c.inflight_count())
		c.bench_discard_inflight()
	}
	return acc
}

// bench_frame: per round, `depth` queries submitted (unsent), their canned
// replies written into the socketpair in one send, then async_on_readable
// until every query completed: recv straight into the receive buffer plus
// the per-message framing into each query's accumulator.
fn bench_frame(reply []u8, rounds int) u64 {
	fds := pair()
	mut c := pg_async.bench_conn_on_fd(fds[0])
	c.set_nonblocking() or { panic(err) }
	ps := params()
	mut burst := []u8{cap: reply.len * depth}
	for _ in 0 .. depth {
		burst << reply
	}
	mut acc := u64(0)
	for _ in 0 .. rounds {
		for _ in 0 .. depth {
			if !c.async_submit(query, ps) {
				panic('submit shed')
			}
		}
		c.bench_discard_sends()
		send_all(fds[1], burst)
		mut done := 0
		for done < depth {
			poll := c.async_on_readable() or { panic(err) }
			if poll.ready {
				acc += poll.result.rows_affected
				done++
			}
		}
	}
	return acc
}

// bench_rows: Result.rows() over one canned result, reading every column of
// every row through the typed accessors (the async-db render loop).
fn bench_rows(reply []u8, rounds int) u64 {
	res := pg_async.Result{
		frames:        reply
		rows_affected: rows_per_query
	}
	mut acc := u64(0)
	for _ in 0 .. rounds {
		mut it := res.rows()
		for {
			row := it.next() or { break }
			acc += u64(row.int4(0) or { 0 })
			acc += u64((row.text(1) or { []u8{} }).len)
			acc += u64((row.text(2) or { []u8{} }).len)
			acc += u64(row.int4(3) or { 0 })
			acc += u64(row.int4(4) or { 0 })
			acc += u64(row.boolean(5) or { false })
			acc += u64(pg_async.jsonb_text(row.text(6) or { []u8{} }).len)
			acc += u64(row.int4(7) or { 0 })
			acc += u64(row.int4(8) or { 0 })
		}
	}
	return acc
}

// bench_decode: the binary decoders alone, over pre-split column bytes.
fn bench_decode(n int) u64 {
	c_i2 := [u8(0x01), 0x02]
	c_i4 := [u8(0x00), 0x01, 0x02, 0x03]
	c_i8 := [u8(0x00), 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05]
	bo := [u8(1)]
	f8 := [u8(0x40), 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18]
	jb := '\x01{"a": 1}'.bytes()
	mut acc := u64(0)
	for i in 0 .. n {
		acc += u64(pg_async.decode_int2(c_i2) or { 0 })
		acc += u64(pg_async.decode_int4(c_i4) or { 0 })
		acc += u64(pg_async.decode_int8(c_i8) or { 0 })
		acc += u64(pg_async.decode_bool(bo) or { false })
		acc += u64(pg_async.decode_float8(f8) or { 0 } > 3.0)
		acc += u64(pg_async.decode_text(jb).len)
		acc += u64(pg_async.jsonb_text(jb).len) + u64(i & 1)
	}
	return acc
}

// canned_reply is one query's complete reply as async_on_readable frames it:
// ParseComplete, BindComplete, RowDescription (9 columns), rows_per_query
// DataRows, CommandComplete, ReadyForQuery.
fn canned_reply() []u8 {
	mut out := []u8{}
	msg(mut out, `1`, []u8{})
	msg(mut out, `2`, []u8{})
	cols := [
		Col{'id', 23, 4},
		Col{'name', 25, -1},
		Col{'category', 25, -1},
		Col{'price', 23, 4},
		Col{'quantity', 23, 4},
		Col{'active', 16, 1},
		Col{'tags', 3802, -1},
		Col{'rating_score', 23, 4},
		Col{'rating_count', 23, 4},
	]
	mut td := []u8{}
	put16(mut td, cols.len)
	for c in cols {
		td << c.name.bytes()
		td << 0
		put32(mut td, 0)
		put16(mut td, 0)
		put32(mut td, c.oid)
		put16(mut td, c.size)
		put32(mut td, -1)
		put16(mut td, 1)
	}
	msg(mut out, `T`, td)
	for i in 1 .. rows_per_query + 1 {
		mut d := []u8{}
		put16(mut d, 9)
		int4_col(mut d, i)
		text_col(mut d, 'item ${i}')
		text_col(mut d, 'category ${i % 5}')
		int4_col(mut d, i * 10)
		int4_col(mut d, i * 2)
		put32(mut d, 1)
		d << u8(i & 1)
		text_col(mut d, '\x01["a", "b", ${i}]')
		int4_col(mut d, i % 100)
		int4_col(mut d, i)
		msg(mut out, `D`, d)
	}
	msg(mut out, `C`, 'SELECT ${rows_per_query}\x00'.bytes())
	msg(mut out, `Z`, [u8(`I`)])
	return out
}

struct Col {
	name string
	oid  int
	size int
}

fn int4_col(mut d []u8, v int) {
	put32(mut d, 4)
	put32(mut d, v)
}

fn text_col(mut d []u8, s string) {
	put32(mut d, s.len)
	d << s.bytes()
}

fn msg(mut out []u8, typ u8, payload []u8) {
	out << typ
	put32(mut out, payload.len + 4)
	out << payload
}

fn put16(mut out []u8, v int) {
	out << u8(v >> 8)
	out << u8(v)
}

fn put32(mut out []u8, v int) {
	out << u8(v >> 24)
	out << u8(v >> 16)
	out << u8(v >> 8)
	out << u8(v)
}

// pair is a connected socketpair(2). C int out-params are i32: V's `int` is
// 64-bit on 64-bit targets.
fn pair() [2]int {
	mut fds := [2]i32{}
	if C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &fds[0]) != 0 {
		panic('socketpair failed')
	}
	return [int(fds[0]), int(fds[1])]!
}

fn send_all(fd int, b []u8) {
	mut off := 0
	for off < b.len {
		n := C.send(fd, unsafe { &u8(b.data) + off }, usize(b.len - off), 0)
		if n <= 0 {
			panic('send failed (errno ${C.errno})')
		}
		off += n
	}
}

fn vm_rss_kib() int {
	status := os.read_file('/proc/self/status') or { return -1 }
	for line in status.split_into_lines() {
		if line.starts_with('VmRSS:') {
			return line.all_after(':').trim_space().all_before(' ').int()
		}
	}
	return -1
}
