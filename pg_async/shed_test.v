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

// buf_cfg is the fake server's config with a send buffer of `cap` bytes
// (ConnConfig.send_buf_cap).
fn buf_cfg(port int, cap int) ConnConfig {
	return ConnConfig{
		host:         '127.0.0.1'
		port:         port
		user:         'vanilla'
		password:     'secret'
		database:     'vanilla'
		send_buf_cap: cap
	}
}

// shed_reason is the reason of a Shed error, or fails the test.
fn shed_reason(err IError) ShedReason {
	if err is Shed {
		return err.reason
	}
	panic('expected a Shed, got ${err.type_name()}: ${err.msg()}')
}

// too_large_cap is the send-buffer size a FrameTooLarge error names, or
// fails the test.
fn too_large_cap(err IError) int {
	if err is FrameTooLarge {
		return err.cap
	}
	panic('expected a FrameTooLarge, got ${err.type_name()}: ${err.msg()}')
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
		if mut one := PgConn.connect(ConnConfig{
			host:         '127.0.0.1'
			port:         fake.port
			user:         'vanilla'
			password:     'secret'
			database:     'vanilla'
			max_inflight: bad
		})
		{
			one.close()
			assert false, 'PgConn.connect took max_inflight ${bad}'
		} else {
			assert err.msg().contains('max_inflight'), err.msg()
		}
	}
	for good in [1, max_inflight_limit] {
		mut p := shed_pool(fake.port, 1, good)!
		assert p.conn(0).inflight_limit() == good
		p.close()
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
	assert C.setsockopt(pool.fd(0), C.SOL_SOCKET, C.SO_SNDBUF, &small, sizeof(int)) == 0
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
	room := pool.conn(0).send_room()
	n := query_frame_len(sql, echo_param(room))
	assert pool.acquire_pipelined_for(n)! == 1
	assert pool.acquire_pipelined()? == 0
	// A frame of exactly the room left is taken there, and its submit
	// succeeds: what append_send compacts is what send_room counted.
	exact := echo_param(room - query_frame_len(sql, echo_param(0)))
	assert query_frame_len(sql, exact) == room
	assert pool.acquire_pipelined_for(room)! == 0
	pool.conn(0).submit(sql, exact)!
	assert pool.conn(0).send_room() == 0
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

// echo_len pumps the front query to completion and returns the length of the
// text it echoed.
fn echo_len(mut c PgConn) !int {
	res := pump_one(mut c)!
	mut it := res.rows()
	row := it.next() or { return error('expected the echo') }
	return row.col(0)!.bytes.len
}

// ConnConfig.send_buf_cap sizes each connection's send buffer, and so the
// largest frame it takes (vanilla#355). A 100 KiB frame is FrameTooLarge on
// the default 64 KiB buffer; on a 128 KiB one it is sent and answered on
// every submit path, and the bound is 128 KiB to the byte.
fn test_send_buf_cap_sets_the_largest_frame() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	sql := 'select \$1::text'
	p100 := echo_param(100 * 1024)
	n100 := query_frame_len(sql, p100)
	mut narrow := shed_pool(fake.port, 1, 8)!
	defer {
		narrow.close()
	}
	assert narrow.conn(0).max_frame_len() == max_frame_len
	if i := narrow.acquire_pipelined_for(n100) {
		assert false, 'acquire_pipelined_for returned ${i} for 100 KiB on a 64 KiB send buffer'
	} else {
		assert too_large_cap(err) == max_frame_len
	}
	assert too_large_cap(submit_err(mut narrow.conn(0), sql, p100)) == max_frame_len
	assert !narrow.conn(0).async_submit(sql, p100)

	wide_cap := 128 * 1024
	mut wide := new_pool(buf_cfg(fake.port, wide_cap), 1)!
	defer {
		wide.close()
	}
	mut c := wide.conn(wide.acquire_pipelined_for(n100)!)
	assert c.max_frame_len() == wide_cap
	c.submit(sql, p100)!
	assert echo_len(mut c)! == 100 * 1024
	assert c.async_submit(sql, p100)
	assert echo_len(mut c)! == 100 * 1024
	assert c.async_submit_batch([Stmt{ sql: sql, params: p100 }])!
	assert echo_len(mut c)! == 100 * 1024
	// A frame of exactly 128 KiB is taken; one byte more is FrameTooLarge,
	// naming the connection's own buffer.
	room := wide_cap - query_frame_len(sql, echo_param(0))
	exact := echo_param(room)
	assert query_frame_len(sql, exact) == wide_cap
	assert wide.acquire_pipelined_for(wide_cap)! == 0
	c.submit(sql, exact)!
	assert echo_len(mut c)! == room
	over := echo_param(room + 1)
	if i := wide.acquire_pipelined_for(wide_cap + 1) {
		assert false, 'acquire_pipelined_for returned ${i} past the 128 KiB buffer'
	} else {
		assert too_large_cap(err) == wide_cap
	}
	assert too_large_cap(submit_err(mut c, sql, over)) == wide_cap
	assert too_large_cap(batch_err(mut c, [Stmt{ sql: sql, params: over }])) == wide_cap
	if _ := c.async_submit_batch([Stmt{ sql: sql, params: over }]) {
		assert false, 'async_submit_batch took a batch past the 128 KiB buffer'
	}
	assert c.inflight.len == 0, 'nothing past the buffer was submitted'
}

// send_buf_cap defaults to max_frame_len (64 KiB). A value out of
// min_send_buf_cap..max_send_buf_cap is refused before anything is dialed,
// as max_inflight is.
fn test_send_buf_cap_defaults_to_max_frame_len_and_is_bounded() {
	cfg := ConnConfig{}
	assert cfg.send_buf_cap == max_frame_len
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	for bad in [0, -1, min_send_buf_cap - 1, max_send_buf_cap + 1] {
		if mut p := new_pool(buf_cfg(fake.port, bad), 1) {
			p.close()
			assert false, 'send_buf_cap ${bad} was accepted'
		} else {
			assert err.msg().contains('send_buf_cap'), err.msg()
		}
		if mut one := PgConn.connect(buf_cfg(fake.port, bad)) {
			one.close()
			assert false, 'PgConn.connect took send_buf_cap ${bad}'
		} else {
			assert err.msg().contains('send_buf_cap'), err.msg()
		}
	}
	assert fake.stat('accepted') == 0, 'a refused send_buf_cap dialed the server'
	for good in [min_send_buf_cap, max_send_buf_cap] {
		mut p := new_pool(buf_cfg(fake.port, good), 1)!
		mut pc := p.conn(0)
		assert pc.max_frame_len() == good
		pc.submit('select 1', []?[]u8{})!
		drain_all(mut pc)!
		assert pc.max_frame_len() == good, 'a submit swapped the send buffer'
		p.close()
		mut one := PgConn.connect(buf_cfg(fake.port, good))!
		assert one.max_frame_len() == good
		one.close()
	}
}

// open_conn connects to the fake server as a pool does: brought up, then
// non-blocking.
fn open_conn(cfg ConnConfig) !PgConn {
	mut c := PgConn.connect(cfg)!
	c.set_nonblocking() or {
		c.close()
		return err
	}
	return c
}

// acquire_pipelined_for measures a frame against each connection's own send
// buffer (vanilla#355): the room is what a 128 KiB buffer has left, and in a
// pool whose buffers differ a frame goes only to a connection it fits. It
// sheds while such a connection is busy, and is FrameTooLarge, naming the
// largest buffer, only when it fits none.
fn test_acquire_pipelined_for_sheds_by_each_connection_s_own_capacity() {
	if !testkit.fake_pg_available() {
		return
	}
	mut fake := testkit.start_fake_pg([])!
	defer {
		fake.stop()
	}
	wide_cap := 128 * 1024
	sql := 'select \$1::text'
	p60 := echo_param(60 * 1024)
	n60 := query_frame_len(sql, p60)
	mut pool := new_pool(buf_cfg(fake.port, wide_cap), 2)!
	defer {
		pool.close()
	}
	pool.conn(0).submit(sql, p60)! // depth 1: 68 KiB of room left (4 KiB in a 64 KiB buffer)
	pool.conn(1).submit('select 1', []?[]u8{})!
	pool.conn(1).submit('select 2', []?[]u8{})! // depth 2
	assert pool.conn(0).send_room() == wide_cap - n60
	assert pool.acquire_pipelined_for(n60)! == 0, 'the shortest pipeline has room for 60 KiB more'
	pool.conn(0).submit(sql, p60)! // 8 KiB of room left
	assert pool.acquire_pipelined_for(n60)! == 1
	pool.conn(1).submit(sql, p60)!
	pool.conn(1).submit(sql, p60)! // under 8 KiB left on either
	if i := pool.acquire_pipelined_for(n60) {
		assert false, 'acquire_pipelined_for returned ${i} with no room for 60 KiB'
	} else {
		assert shed_reason(err) == .send_buffer_full
	}
	for i in 0 .. 2 {
		drain_all(mut pool.conn(i))!
	}

	// A 64 KiB and a 128 KiB connection in one pool.
	mut mixed := PgPool{
		conns: [open_conn(buf_cfg(fake.port, max_frame_len))!,
			open_conn(buf_cfg(fake.port, wide_cap))!]
		idle:  [true, true]
		cfg:   buf_cfg(fake.port, max_frame_len)
	}
	defer {
		mixed.close()
	}
	p100 := echo_param(100 * 1024)
	n100 := query_frame_len(sql, p100)
	mixed.conn(1).submit('select 1', []?[]u8{})! // the wide connection is the deeper one
	assert mixed.acquire_pipelined_for(n100)! == 1, '100 KiB goes to the 128 KiB buffer, never the idle 64 KiB one'
	assert mixed.acquire_pipelined_for(query_frame_len('select 2', []?[]u8{}))! == 0
	mixed.conn(1).submit(sql, p60)! // 68 KiB of room left in the wide buffer
	if i := mixed.acquire_pipelined_for(n100) {
		assert false, 'acquire_pipelined_for returned ${i} with no room for 100 KiB'
	} else {
		// The wide buffer takes it once it drains: a shed, not FrameTooLarge.
		assert shed_reason(err) == .send_buffer_full
	}
	if i := mixed.acquire_pipelined_for(wide_cap + 1) {
		assert false, 'acquire_pipelined_for returned ${i} for a frame no buffer holds'
	} else {
		assert too_large_cap(err) == wide_cap, 'FrameTooLarge names the largest buffer'
	}
	drain_all(mut mixed.conn(1))!
	// The only connection the frame fits is in a transaction: a shed, not
	// FrameTooLarge.
	mixed.conns[1].ready_status = tx_in_block
	if i := mixed.acquire_pipelined_for(n100) {
		assert false, 'acquire_pipelined_for returned ${i} with the 128 KiB connection in a transaction'
	} else {
		assert shed_reason(err) == .no_connection
	}
	mixed.conns[1].ready_status = tx_idle
	i := mixed.acquire_pipelined_for(n100)!
	assert i == 1
	mixed.conn(i).submit(sql, p100)!
	assert echo_len(mut mixed.conn(i))! == 100 * 1024
}

// append_send slides the unsent bytes to the front only when the frame has no
// room behind them: a small frame queued while a large one is partly sent
// copies only itself (vanilla#355). When they must move, they move intact and
// in order, and a frame that does not fit even then moves nothing.
fn test_append_moves_the_unsent_bytes_only_when_the_frame_needs_the_room() {
	mut c := PgConn{
		send_buf: []u8{len: min_send_buf_cap}
	}
	c.state = .ready
	big := []u8{len: 12 * 1024, init: u8(index)}
	assert c.append_send(big)
	c.send_off = 10 * 1024 // the socket took 10 KiB of it
	small := []u8{len: 100, init: `s`}
	assert c.append_send(small)
	assert c.send_off == 10 * 1024, 'there was room behind the unsent bytes: nothing moves'
	assert c.send_len == big.len + small.len
	assert !c.append_send([]u8{len: c.send_room() + 1}), 'no room even in front'
	assert c.send_off == 10 * 1024, 'a refused frame moves nothing'
	mid := []u8{len: 5 * 1024, init: `m`} // 3.9 KiB left behind, 13.9 KiB in all
	assert c.append_send(mid)
	assert c.send_off == 0
	mut want := big[10 * 1024..].clone()
	want << small
	want << mid
	assert c.send_buf[..c.send_len] == want
}

// A frame too large for the send buffer is refused before it is serialized,
// on every submit path: the submit scratch does not grow to its size, as it
// would for a request-sized parameter that is refused anyway.
fn test_a_refused_frame_never_grows_the_scratch() {
	mut c := PgConn{}
	c.state = .ready
	assert c.async_submit('select 1', []?[]u8{})
	scratch := c.submit_scratch.cap
	sql := 'select \$1::text'
	huge := echo_param(1024 * 1024)
	assert !c.async_submit(sql, huge)
	if _ := c.async_submit_batch([Stmt{ sql: sql, params: huge }]) {
		assert false, 'async_submit_batch took 1 MiB on a 64 KiB send buffer'
	}
	c.submit(sql, huge) or {}
	c.submit_batch([Stmt{ sql: sql, params: huge }]) or {}
	assert c.submit_scratch.cap == scratch, 'a refused frame grew the scratch to ${c.submit_scratch.cap} bytes'
	assert c.inflight.len == 1
	c.inflight.clear()
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
	pool.acquire_pipelined_for(n)!
}

// A connection whose session is in a transaction is never chosen either.
fn test_a_connection_in_a_transaction_is_never_chosen() {
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
	pool.conns[0].ready_status = tx_in_block
	for _ in 0 .. 3 {
		assert pool.acquire_pipelined_for(n)! == 1
		pool.conn(1).submit('select 1', []?[]u8{})!
	}
	pool.conns[1].ready_status = tx_failed
	if j := pool.acquire_pipelined_for(n) {
		assert false, 'acquire_pipelined_for returned ${j} with both sessions in a transaction'
	} else {
		assert shed_reason(err) == .no_connection
	}
	pool.conns[0].ready_status = tx_idle
	pool.conns[1].ready_status = tx_idle
	drain_all(mut pool.conn(1))!
}

// One connection's pipeline is full and the other's send buffer is: the
// shed says the buffer, the reason a smaller frame could still pass.
fn test_a_full_buffer_wins_over_a_full_pipeline_in_the_reason() {
	if !testkit.fake_pg_available() {
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
	pool.conn(0).submit('select 1', []?[]u8{})!
	pool.conn(0).submit('select 2', []?[]u8{})!
	sql := 'select \$1::text'
	pool.conn(1).submit(sql, echo_param(60 * 1024))!
	n := query_frame_len(sql, echo_param(10 * 1024))
	if j := pool.acquire_pipelined_for(n) {
		assert false, 'acquire_pipelined_for returned ${j}'
	} else {
		assert shed_reason(err) == .send_buffer_full
	}
	for i in 0 .. 2 {
		drain_all(mut pool.conn(i))!
	}
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

// Refusing allocates nothing: the Shed and FrameTooLarge errors are
// constants, and an oversized frame is never serialized. A connection with a
// send buffer of its own size (send_buf_cap) has its FrameTooLarge boxed when
// it is made, so it refuses for nothing too.
fn test_shedding_allocates_nothing() {
	mut c := PgConn{}
	c.state = .ready
	c.inflight_cap = 1
	c.submit('select 1', []?[]u8{})!
	mut pool := PgPool{
		conns: [c]
		idle:  [true]
	}
	wide_cap := 128 * 1024
	mut wide := PgConn{
		send_buf:        []u8{len: wide_cap}
		frame_too_large: frame_too_large_error(wide_cap)
	}
	wide.state = .ready
	mut wide_pool := PgPool{
		conns: [wide]
		idle:  [true]
	}
	wide_huge := echo_param(wide_cap)
	n := query_frame_len('select 1', []?[]u8{})
	huge := echo_param(max_frame_len)
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
			pool.conns[0].submit('select \$1::text', huge) or {
				if err is FrameTooLarge {
					sheds++
				}
			}
			_ := pool.acquire_pipelined_for(max_frame_len + 1) or {
				if err is FrameTooLarge {
					sheds++
				}
				-1
			}
			wide_pool.conns[0].submit('select \$1::text', wide_huge) or {
				if err is FrameTooLarge && err.cap == wide_cap {
					sheds++
				}
			}
			_ := wide_pool.acquire_pipelined_for(wide_cap + 1) or {
				if err is FrameTooLarge && err.cap == wide_cap {
					sheds++
				}
				-1
			}
		}
		grown := gc_heap_usage().bytes_since_gc - before
		if round == 1 {
			assert grown == 0, 'refusing allocated ${grown} bytes over 6000 refusals'
		}
	}
	assert sheds == 12000
	pool.conns[0].inflight.clear()
}
