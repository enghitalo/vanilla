// vtest build: !windows
module pg_async

import testkit
import time

#include <sys/socket.h>

fn C.setsockopt(fd int, level int, optname int, optval voidptr, optlen u32) int

// The backpressure contract (shed.v, vanilla#51): a shed, a frame that can
// never fit and a lost connection are told apart, and acquire_pipelined_for
// picks a connection that can take the frame now.

fn shed_pool(port int, size int, depth int) !&PgPool {
	return new_pool(ConnConfig{
		host:         '127.0.0.1'
		port:         port
		user:         'vanilla'
		password:     'secret'
		database:     'vanilla'
		max_inflight: depth
	}, size)
}

// shed_reason is the reason of a Shed error, or fails the test.
fn shed_reason(err IError) ShedReason {
	if err is Shed {
		return err.reason
	}
	panic('expected a Shed, got ${err.type_name()}: ${err.msg()}')
}

// submit_err is the error submit returns, or fails the test.
fn submit_err(mut c PgConn, query string, params []?[]u8) IError {
	c.submit(query, params) or { return err }
	panic('submit `${query}` was accepted')
}

// batch_err is the error submit_batch returns, or fails the test.
fn batch_err(mut c PgConn, stmts []Stmt) IError {
	c.submit_batch(stmts) or { return err }
	panic('submit_batch was accepted')
}

// echo_param is a text parameter of `n` bytes, for a frame of a known size.
fn echo_param(n int) []?[]u8 {
	return [?[]u8([]u8{len: n, init: `x`})]
}

// pump_one flushes, then pumps readable until the front query completes,
// for up to 10 s (a paused fake server answers late).
fn pump_one(mut c PgConn) !Result {
	deadline := time.sys_mono_now() + 10 * u64(time.second)
	for !c.async_flush()! {
		if time.sys_mono_now() > deadline {
			return error('the query was not sent')
		}
	}
	for time.sys_mono_now() < deadline {
		poll := c.async_on_readable()!
		if poll.ready {
			return poll.result
		}
	}
	return error('query did not complete')
}

// drain_all flushes connection `c` and collects every query in flight on it,
// checking each one completed.
fn drain_all(mut c PgConn) ! {
	for c.inflight.len > 0 {
		res := pump_one(mut c)!
		mut it := res.rows()
		it.next() or { return error('expected a row') }
	}
}

fn test_frame_len_matches_what_submit_writes() {
	cases := [
		Stmt{
			sql: 'select 1'
		},
		Stmt{
			sql:    'select \$1::text, \$2::int4, \$3::text'
			params: [?[]u8('abc'.bytes()), ?[]u8(none), ?[]u8([]u8{})]
		},
	]
	mut c := PgConn{}
	c.state = .ready
	for s in cases {
		c.reset_scratch()
		write_parse(mut c.submit_scratch, '', s.sql)
		write_bind(mut c.submit_scratch, '', '', s.params)
		write_describe_portal(mut c.submit_scratch, '')
		write_execute(mut c.submit_scratch, '', 0)
		write_sync(mut c.submit_scratch)
		assert query_frame_len(s.sql, s.params) == c.submit_scratch.len
	}
	c.reset_scratch()
	for s in cases {
		write_parse(mut c.submit_scratch, '', s.sql)
		write_bind(mut c.submit_scratch, '', '', s.params)
		write_describe_portal(mut c.submit_scratch, '')
		write_execute(mut c.submit_scratch, '', 0)
	}
	write_sync(mut c.submit_scratch)
	assert batch_frame_len(cases) == c.submit_scratch.len
	// What submit queues is exactly that many bytes.
	c.submit(cases[1].sql, cases[1].params)!
	assert c.send_len == query_frame_len(cases[1].sql, cases[1].params)
}

// max_inflight comes from the config: depth 2 on two connections takes 4
// pipelined queries, then sheds with .pipeline_full — on the pool and on a
// connection — and the 4 queries still complete.
fn test_shed_when_every_pipeline_is_at_max_inflight() {
	if !testkit.fake_pg_available() {
		eprintln('pg_async: skipping shed tests (no python3)')
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := shed_pool(fake.port, 2, 2)!
	defer {
		pool.close()
	}
	n := query_frame_len('select 5', []?[]u8{})
	mut depth := [0, 0]
	for _ in 0 .. 4 {
		i := pool.acquire_pipelined_for(n)!
		assert pool.conn(i).inflight_limit() == 2
		pool.conn(i).submit('select 5', []?[]u8{})!
		depth[i]++
	}
	assert depth == [2, 2], 'the shortest pipeline is taken each time'
	if i := pool.acquire_pipelined_for(n) {
		assert false, 'acquire_pipelined_for returned ${i} with every pipeline full'
	} else {
		assert shed_reason(err) == .pipeline_full
	}
	if _ := pool.acquire_pipelined() {
		assert false, 'acquire_pipelined agrees: none'
	}
	assert shed_reason(submit_err(mut pool.conn(0), 'select 5', []?[]u8{})) == .pipeline_full
	assert !pool.conn(0).async_submit('select 5', []?[]u8{}), 'async_submit honors the configured max_inflight too'
	assert pool.conn(0).inflight.len == 2
	for i in 0 .. 2 {
		drain_all(mut pool.conn(i))!
	}
	// Drained, the pool takes queries again.
	i := pool.acquire_pipelined_for(n)!
	assert pool.conn(i).inflight.len == 0
}

// The default stays 8 queries per connection.
fn test_max_inflight_defaults_to_8_and_is_bounded() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := new_pool(ConnConfig{
		host:     '127.0.0.1'
		port:     fake.port
		user:     'vanilla'
		password: 'secret'
		database: 'vanilla'
	}, 1)!
	defer {
		pool.close()
	}
	mut c := pool.conn(0)
	assert c.inflight_limit() == 8
	for _ in 0 .. 8 {
		c.submit('select 1', []?[]u8{})!
	}
	assert shed_reason(submit_err(mut c, 'select 1', []?[]u8{})) == .pipeline_full
	drain_all(mut c)!
	for bad in [0, -1, max_inflight_limit + 1] {
		if mut p := shed_pool(fake.port, 1, bad) {
			p.close()
			assert false, 'max_inflight ${bad} was accepted'
		} else {
			assert err.msg().contains('max_inflight'), err.msg()
		}
	}
}

// The shortest pipeline has no room in its send buffer for the frame: the
// deeper connection that has room is chosen, and with no room anywhere the
// frame sheds with .send_buffer_full. The frames are queued and not yet
// flushed, as when the socket is full.
fn test_another_connection_is_chosen_when_the_send_buffer_is_full() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := shed_pool(fake.port, 2, 8)!
	defer {
		pool.close()
	}
	sql := 'select \$1::text'
	big := echo_param(60 * 1024)
	pool.conn(0).submit(sql, big)! // depth 1, 4 KiB of room left
	pool.conn(1).submit('select 1', []?[]u8{})!
	pool.conn(1).submit('select 2', []?[]u8{})! // depth 2, almost all its room left
	mid := echo_param(10 * 1024)
	n := query_frame_len(sql, mid)
	assert pool.conn(0).send_room() < n
	assert pool.acquire_pipelined()? == 0, 'acquire_pipelined picks the shortest pipeline only'
	assert pool.acquire_pipelined_for(n)! == 1
	assert shed_reason(submit_err(mut pool.conn(0), sql, mid)) == .send_buffer_full
	pool.conn(1).submit(sql, big)! // now neither has room for `mid`
	if i := pool.acquire_pipelined_for(n) {
		assert false, 'acquire_pipelined_for returned ${i} with no room on either connection'
	} else {
		assert shed_reason(err) == .send_buffer_full
	}
	// A small frame still fits in what is left on connection 0.
	assert pool.acquire_pipelined_for(query_frame_len('select 3', []?[]u8{}))! == 0
	for i in 0 .. 2 {
		drain_all(mut pool.conn(i))!
	}
}

// The same with a frame the socket would not take: the server reads nothing
// for a while (--pause-ms after the first reply) and the client's socket
// buffer is small, so most of a flushed frame stays in the send buffer.
// The room is counted from what is still unsent.
fn test_room_counts_the_unsent_bytes_after_a_partial_flush() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg(['--pause-ms', '1500', '--rcvbuf', '4096'])!
	defer {
		fake.stop()
	}
	mut pool := shed_pool(fake.port, 2, 8)!
	defer {
		pool.close()
	}
	small := 4096
	C.setsockopt(pool.fd(0), C.SOL_SOCKET, C.SO_SNDBUF, &small, sizeof(int))
	// One reply, then the server reads nothing on connection 0 for 1.5 s.
	pool.conn(0).submit('select 1', []?[]u8{})!
	drain_all(mut pool.conn(0))!
	sql := 'select \$1::text'
	pool.conn(0).submit(sql, echo_param(60 * 1024))!
	assert !(pool.conn(0).async_flush()!), 'the paused server should leave the frame partly unsent'
	assert pool.conn(0).send_off > 0, 'part of it was sent'
	unsent := pool.conn(0).send_len - pool.conn(0).send_off
	assert pool.conn(0).send_room() == send_buf_cap - unsent
	pool.conn(1).submit('select 1', []?[]u8{})!
	pool.conn(1).submit('select 2', []?[]u8{})!
	n := query_frame_len(sql, echo_param(pool.conn(0).send_room()))
	assert pool.acquire_pipelined_for(n)! == 1
	assert pool.acquire_pipelined()? == 0
	for i in 0 .. 2 {
		drain_all(mut pool.conn(i))!
	}
}

// A frame larger than the send buffer is FrameTooLarge — never a shed — from
// acquire_pipelined_for, submit and submit_batch, on an idle pool. One of
// exactly max_frame_len bytes is accepted.
fn test_a_frame_larger_than_the_send_buffer_is_an_error() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := shed_pool(fake.port, 2, 8)!
	defer {
		pool.close()
	}
	assert max_frame_len == send_buf_cap
	if i := pool.acquire_pipelined_for(max_frame_len + 1) {
		assert false, 'acquire_pipelined_for returned ${i} for a frame that can never fit'
	} else {
		assert err is FrameTooLarge, err.msg()
		if err is FrameTooLarge {
			assert err.len == max_frame_len + 1
			assert err.cap == max_frame_len
		}
	}
	sql := 'select \$1::text'
	exact := echo_param(max_frame_len - query_frame_len(sql, echo_param(0)))
	assert query_frame_len(sql, exact) == max_frame_len
	i := pool.acquire_pipelined_for(max_frame_len)!
	mut c := pool.conn(i)
	over := echo_param(max_frame_len)
	e1 := submit_err(mut c, sql, over)
	assert e1 is FrameTooLarge, e1.msg()
	e2 := batch_err(mut c, [Stmt{ sql: sql, params: over }])
	assert e2 is FrameTooLarge, e2.msg()
	assert c.inflight.len == 0, 'nothing was submitted'
	c.submit(sql, exact)!
	res := pump_one(mut c)!
	mut it := res.rows()
	row := it.next() or { panic('expected the echo') }
	want := exact[0] or { []u8{} }
	assert row.col(0)!.bytes.len == want.len
	e3 := batch_err(mut c, []Stmt{})
	assert e3 !is FrameTooLarge && e3 !is Shed, e3.msg()
}

// A connection held by acquire() is never chosen; with every connection held
// the frame sheds with .no_connection.
fn test_a_connection_held_by_acquire_is_never_chosen() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := shed_pool(fake.port, 2, 8)!
	defer {
		pool.close()
	}
	n := query_frame_len('select 1', []?[]u8{})
	held := pool.acquire() or { panic('expected an idle connection') }
	for _ in 0 .. 6 {
		j := pool.acquire_pipelined_for(n)!
		assert j != held, 'acquire_pipelined_for handed out the exclusively held connection ${held}'
		pool.conn(j).submit('select 1', []?[]u8{})!
	}
	drain_all(mut pool.conn(1 - held))!
	other := pool.acquire() or { panic('expected the second connection') }
	if j := pool.acquire_pipelined_for(n) {
		assert false, 'acquire_pipelined_for returned ${j} while both connections are held'
	} else {
		assert shed_reason(err) == .no_connection
	}
	pool.release(held)
	pool.release(other)
	assert pool.acquire_pipelined_for(n)! >= 0
}

// A submit on a lost connection is ConnBroken, not a shed.
fn test_submit_on_a_lost_connection_is_conn_broken() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	mut pool := shed_pool(fake.port, 1, 8)!
	defer {
		pool.close()
	}
	mut c := pool.conn(0)
	c.lose('test: lost')
	e1 := submit_err(mut c, 'select 1', []?[]u8{})
	assert e1 is ConnBroken, e1.msg()
	assert e1.msg().contains('test: lost')
	e2 := batch_err(mut c, [Stmt{ sql: 'select 1' }])
	assert e2 is ConnBroken, e2.msg()
	assert c.inflight.len == 0
}

// Shedding allocates nothing: the Shed errors are constants.
fn test_shedding_allocates_nothing() {
	mut c := PgConn{}
	c.state = .ready
	c.inflight_cap = 1
	c.submit('select 1', []?[]u8{})!
	mut pool := PgPool{
		conns: [c]
		idle:  [true]
	}
	n := query_frame_len('select 1', []?[]u8{})
	mut sheds := 0
	for round in 0 .. 2 {
		before := gc_heap_usage().bytes_since_gc
		for _ in 0 .. 1000 {
			pool.conns[0].submit('select 1', []?[]u8{}) or {
				if err is Shed {
					sheds++
				}
			}
			_ := pool.acquire_pipelined_for(n) or {
				if err is Shed {
					sheds++
				}
				-1
			}
		}
		grown := gc_heap_usage().bytes_since_gc - before
		if round == 1 {
			assert grown == 0, 'shedding allocated ${grown} bytes over 2000 sheds'
		}
	}
	assert sheds == 4000
	pool.conns[0].inflight.clear()
}
