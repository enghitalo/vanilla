// vtest build: !windows
module pg_async

#include <sys/socket.h>

fn C.socketpair(domain int, typ int, protocol int, sv &i32) int

// Transactions without a server (vanilla#199): the connection talks to the
// other end of a socketpair, and the test writes PostgreSQL's replies there
// by hand — the ReadyForQuery status bytes (I/T/E), a batch's replies, the
// ROLLBACK release() queues — so each step can be checked before the next
// byte arrives.

const no_params = []?[]u8{}

fn socket_pair() (int, int) {
	mut sv := [2]i32{}
	assert C.socketpair(C.AF_UNIX, C.SOCK_STREAM, 0, &sv[0]) == 0
	return int(sv[0]), int(sv[1])
}

// pair_conn is a live connection over `fd` (one end of a socketpair).
fn pair_conn(fd int) PgConn {
	mut c := PgConn{
		fd:       fd
		recv_buf: []u8{cap: 16 * 1024}
	}
	c.set_nonblocking() or { panic(err) }
	return c
}

// wire is one backend message.
fn wire(typ u8, payload []u8) []u8 {
	mut out := [typ]
	put_u32(mut out, u32(4 + payload.len))
	out << payload
	return out
}

fn cstr_bytes(s string) []u8 {
	mut b := s.bytes()
	b << 0
	return b
}

// reply is one statement's reply (ParseComplete, BindComplete, then `body`).
fn reply(body []u8) []u8 {
	mut out := wire(bt_parse_complete, []u8{})
	out << wire(bt_bind_complete, []u8{})
	out << body
	return out
}

// done_reply is a statement that returns no rows, completed with `tag`.
fn done_reply(tag string) []u8 {
	mut body := wire(bt_no_data, []u8{})
	body << wire(bt_command_complete, cstr_bytes(tag))
	return reply(body)
}

// int_reply is a statement returning one int4 row.
fn int_reply(v int) []u8 {
	mut desc := []u8{}
	put_u16(mut desc, 1)
	desc << cstr_bytes('n')
	put_u32(mut desc, 0)
	put_u16(mut desc, 0)
	put_u32(mut desc, oid_int4)
	put_u16(mut desc, 4)
	put_u32(mut desc, 0xFFFF_FFFF)
	put_u16(mut desc, 1)
	mut row := []u8{}
	put_u16(mut row, 1)
	put_u32(mut row, 4)
	put_u32(mut row, u32(v))
	mut body := wire(bt_row_description, desc)
	body << wire(bt_data_row, row)
	body << wire(bt_command_complete, cstr_bytes('SELECT 1'))
	return reply(body)
}

fn error_msg(code string) []u8 {
	mut p := []u8{}
	p << `S`
	p << cstr_bytes('ERROR')
	p << `V`
	p << cstr_bytes('ERROR')
	p << `C`
	p << cstr_bytes(code)
	p << `M`
	p << cstr_bytes('canned failure')
	p << 0
	return wire(bt_error_response, p)
}

fn ready_msg(status u8) []u8 {
	return wire(bt_ready_for_query, [status])
}

fn send_all(fd int, b []u8) {
	mut off := 0
	for off < b.len {
		n := C.send(fd, unsafe { &u8(b.data) + off }, usize(b.len - off), 0)
		assert n > 0
		off += n
	}
}

// drain reads everything the connection sent so far into `into` (reused).
fn drain(fd int, mut into []u8) {
	unsafe {
		into.len = 0
	}
	for {
		if into.len == into.cap {
			unsafe { into.grow_cap(into.cap) }
		}
		n := C.recv(fd, unsafe { &u8(into.data) + into.len }, usize(into.cap - into.len),
			C.MSG_DONTWAIT)
		if n <= 0 {
			return
		}
		unsafe {
			into.len += n
		}
	}
}

// frontend_types lists the message types in a frontend byte stream.
fn frontend_types(b []u8) string {
	mut out := []u8{}
	mut pos := 0
	for {
		hdr := next_message_at(b, pos) or { break }
		out << hdr.typ
		pos += hdr.total
	}
	return out.bytestr()
}

fn test_ready_for_query_status_byte_is_tracked() {
	cli, srv := socket_pair()
	mut c := pair_conn(cli)
	defer {
		c.teardown()
		C.close(srv)
	}
	assert c.tx_status() == tx_idle
	assert !c.in_transaction()
	assert c.async_submit('begin', no_params)
	assert c.async_submit('select 1/0', no_params)
	assert c.async_submit('rollback', no_params)
	assert c.async_flush()!

	mut r := done_reply('BEGIN')
	r << ready_msg(tx_in_block)
	send_all(srv, r)
	assert c.async_on_readable()!.ready
	assert c.tx_status() == tx_in_block
	assert c.in_transaction()

	mut failed := reply(error_msg('22012'))
	failed << ready_msg(tx_failed)
	send_all(srv, failed)
	if _ := c.async_on_readable() {
		assert false, 'the statement must fail'
	} else {
		assert err is PgError
	}
	assert c.tx_status() == tx_failed
	assert c.in_transaction()

	mut rb := done_reply('ROLLBACK')
	rb << ready_msg(tx_idle)
	send_all(srv, rb)
	assert c.async_on_readable()!.ready
	assert c.tx_status() == tx_idle
	assert !c.in_transaction()
}

fn test_batch_is_one_sync_and_splits_per_statement() {
	cli, srv := socket_pair()
	mut c := pair_conn(cli)
	defer {
		c.teardown()
		C.close(srv)
	}
	batch := [
		Stmt{
			sql: 'select 1'
		},
		Stmt{
			sql:    r'insert into t values ($1)'
			params: [?[]u8('7'.bytes())]
		},
		Stmt{
			sql: 'update t set v = 1'
		},
	]
	assert c.async_submit_batch(batch)!
	assert c.inflight_count() == 1, 'a batch is ONE entry of the in-flight FIFO'
	assert frontend_types(c.send_buf[c.send_off..c.send_len]) == 'PBDEPBDEPBDES'
	assert c.async_flush()!

	mut r := int_reply(1)
	r << done_reply('INSERT 0 1')
	r << done_reply('UPDATE 4')
	r << ready_msg(tx_idle)
	send_all(srv, r)
	poll := c.async_on_readable()!
	assert poll.ready
	res := poll.result
	assert res.rows_affected == 4, "a batch's rows_affected is its last statement's"
	s0 := res.statement(0)!
	mut it := s0.rows()
	assert (it.next() or { panic('statement 0 has a row') }).int4(0)! == 1
	if _ := it.next() {
		assert false, 'statement 0 has one row'
	}
	assert (s0.columns()!).len() == 1
	s1 := res.statement(1)!
	assert s1.rows_affected == 1
	mut it1 := s1.rows()
	if _ := it1.next() {
		assert false, 'an insert has no rows'
	}
	assert res.statement(2)!.rows_affected == 4
	if _ := res.statement(3) {
		assert false, 'there is no statement 3'
	}
	if _ := res.statement(-1) {
		assert false, 'there is no statement -1'
	}
	assert !c.in_transaction()
}

fn test_batch_error_carries_the_failing_statement_index() {
	cli, srv := socket_pair()
	mut c := pair_conn(cli)
	defer {
		c.teardown()
		C.close(srv)
	}
	two := [Stmt{
		sql: 'insert into t values (1)'
	}, Stmt{
		sql: 'insert into t values (1)'
	}]
	// The second insert fails; the server skips nothing more (it was the last).
	assert c.async_submit_batch(two)!
	assert c.async_flush()!
	mut r := done_reply('INSERT 0 1')
	r << reply(error_msg('23505'))
	r << ready_msg(tx_idle)
	send_all(srv, r)
	if _ := c.async_on_readable() {
		assert false, 'the batch must fail'
	} else {
		assert err is PgError
		if err is PgError {
			assert err.sqlstate == '23505'
			assert err.statement == 1
		}
		assert !is_serialization_failure(err)
	}
	// A failure at the commit (after every statement completed): index = len.
	assert c.async_submit_batch(two)!
	assert c.async_flush()!
	mut r2 := done_reply('INSERT 0 1')
	r2 << done_reply('INSERT 0 1')
	r2 << error_msg('40001')
	r2 << ready_msg(tx_idle)
	send_all(srv, r2)
	if _ := c.async_on_readable() {
		assert false, 'the commit must fail'
	} else {
		assert is_serialization_failure(err)
		if err is PgError {
			assert err.statement == 2
		}
	}
	// A single query's error is statement 0.
	assert c.async_submit('select 1/0', no_params)
	assert c.async_flush()!
	mut r3 := reply(error_msg('22012'))
	r3 << ready_msg(tx_idle)
	send_all(srv, r3)
	if _ := c.async_on_readable() {
		assert false
	} else {
		if err is PgError {
			assert err.statement == 0
		}
	}
	// And the connection is still in step: the next query is fine.
	assert c.async_submit('select 5', no_params)
	assert c.async_flush()!
	mut r4 := int_reply(5)
	r4 << ready_msg(tx_idle)
	send_all(srv, r4)
	assert c.async_on_readable()!.ready
}

fn test_empty_query_counts_as_a_statement() {
	mut frames := reply(wire(bt_empty_query_response, []u8{}))
	frames << int_reply(9)
	frames << ready_msg(tx_idle)
	res := Result{
		frames: frames
	}
	mut it := res.statement(1)!.rows()
	assert (it.next() or { panic('statement 1 has a row') }).int4(0)! == 9
	assert res.statement(0)!.rows_affected == 0
}

// A batch that can never be sent is an error on every connection, never a
// shed (vanilla#51); a full connection sheds it like a query (false).
fn test_batch_that_cannot_fit_is_an_error_not_a_shed() {
	cli, srv := socket_pair()
	mut c := pair_conn(cli)
	defer {
		c.teardown()
		C.close(srv)
	}
	if _ := c.async_submit_batch([]Stmt{}) {
		assert false, 'an empty batch is an error'
	}
	huge := [Stmt{
		sql: 'select ' + 'x'.repeat(send_buf_cap)
	}]
	if _ := c.async_submit_batch(huge) {
		assert false, 'a batch past send_buf_cap can never be sent'
	}
	assert c.inflight_count() == 0
	// 40 KiB fits an empty send buffer, but not one still holding 40 KiB: a shed.
	big := [Stmt{
		sql: 'select ' + 'y'.repeat(40 * 1024)
	}]
	assert c.async_submit_batch(big)!
	assert !c.async_submit_batch(big)!, 'a momentarily full send buffer is a shed'
	assert c.inflight_count() == 1
	// A full pipeline sheds too.
	for c.inflight_count() < max_inflight {
		assert c.async_submit('select 1', no_params)
	}
	assert !c.async_submit_batch([Stmt{
		sql: 'select 1'
	}])!
	// And on a broken connection the oversized batch is still an error.
	c.lose('test')
	assert !c.async_submit_batch([Stmt{
		sql: 'select 1'
	}])!
	if _ := c.async_submit_batch(huge) {
		assert false, 'oversized must not turn into a shed on a broken connection'
	}
}

fn test_tx_retry_policy() {
	p := TxRetry{}
	conflict := IError(PgError{
		severity: 'ERROR'
		sqlstate: '40001'
	})
	unique := IError(PgError{
		severity: 'ERROR'
		sqlstate: '23505'
	})
	assert is_serialization_failure(conflict)
	assert !is_serialization_failure(unique)
	assert !is_serialization_failure(error('pg: connection closed by server'))
	assert p.retry(1, conflict)
	assert p.retry(4, conflict)
	assert !p.retry(5, conflict), 'max_attempts counts the first run'
	assert !p.retry(1, unique), 'only a serialization failure is retried'
	// Full jitter: [1, cap], cap doubling from base, at most max.
	mut seen := map[int]bool{}
	for seed in 0 .. 2000 {
		b1 := p.backoff_from(1, u64(seed))
		assert b1 >= 1 && b1 <= 10
		b3 := p.backoff_from(3, u64(seed))
		assert b3 >= 1 && b3 <= 40
		b9 := p.backoff_from(9, u64(seed))
		assert b9 >= 1 && b9 <= 500
		seen[b1] = true
	}
	assert seen.len == 10, 'every wait in [1, 10] comes up: ${seen.keys()}'
	assert p.backoff_from(30, 12345) <= 500, 'no overflow on a large attempt'
	assert TxRetry{
		base_backoff_ms: 0
	}.backoff_from(3, 7) == 1, 'a wait is never 0 (a 0 timerfd expiry disarms it)'
	b := p.backoff_ms(2)
	assert b >= 1 && b <= 20
}

// pair_pool is a pool over socketpair connections; srvs[i] is conns[i]'s peer.
// Its cfg points at a closed port, in case a test ever re-dials.
fn pair_pool(n int) (PgPool, []int) {
	mut conns := []PgConn{}
	mut srvs := []int{}
	for _ in 0 .. n {
		cli, srv := socket_pair()
		conns << pair_conn(cli)
		srvs << srv
	}
	return PgPool{
		conns: conns
		idle:  []bool{len: n, init: true}
		cfg:   ConnConfig{
			host: '127.0.0.1'
			port: 1
		}
	}, srvs
}

// begin_on runs BEGIN on connection idx, answered by its peer.
fn begin_on(mut pool PgPool, idx int, srv int, mut scratch []u8, begin_reply []u8) {
	mut c := pool.conn(idx)
	assert c.async_submit('begin', no_params)
	assert c.async_flush() or { false }
	drain(srv, mut scratch)
	send_all(srv, begin_reply)
	poll := c.async_on_readable() or { panic(err) }
	assert poll.ready
	assert c.in_transaction()
}

fn test_release_rolls_back_and_the_slot_waits_for_ready_for_query() {
	mut pool, srvs := pair_pool(1)
	defer {
		pool.close()
		C.close(srvs[0])
	}
	mut scratch := []u8{cap: 4096}
	mut begin_reply := done_reply('BEGIN')
	begin_reply << ready_msg(tx_in_block)
	mut rollback_reply := done_reply('ROLLBACK')
	rollback_reply << ready_msg(tx_idle)

	i := pool.acquire() or { panic('the connection is free') }
	begin_on(mut pool, i, srvs[0], mut scratch, begin_reply)
	pool.release(i)
	// The ROLLBACK went out at once...
	drain(srvs[0], mut scratch)
	assert frontend_types(scratch) == 'PBDES'
	assert scratch.bytestr().contains('rollback')
	// ...and until its ReadyForQuery arrives the connection is nobody's.
	assert !pool.idle[i]
	for _ in 0 .. 3 {
		if j := pool.acquire() {
			assert false, 'acquire() handed out connection ${j} mid-ROLLBACK'
		}
		if j := pool.acquire_pipelined() {
			assert false, 'acquire_pipelined() handed out connection ${j} mid-ROLLBACK'
		}
	}
	assert pool.maintain() == maintenance_busy_ms, 'a ROLLBACK in flight asks for a fast tick'
	// The reply arrives: the next acquire reads it and takes the connection.
	send_all(srvs[0], rollback_reply)
	j := pool.acquire() or { panic('the rolled-back connection should be free') }
	assert j == i
	assert !pool.conns[j].in_transaction()
	assert pool.conns[j].rollback_deadline == 0
	assert !pool.conns[j].is_broken()
	pool.release(j)
	assert pool.idle[j], 'releasing an idle session is just the flag'
	drain(srvs[0], mut scratch)
	assert scratch.len == 0, 'no ROLLBACK for a session not in a transaction'

	// A failed transaction block ('E') is rolled back the same way, and
	// maintain() alone finishes it.
	k := pool.acquire() or { panic('free') }
	begin_on(mut pool, k, srvs[0], mut scratch, begin_reply)
	mut c := pool.conn(k)
	assert c.async_submit('select 1/0', no_params)
	assert c.async_flush()!
	mut failed := reply(error_msg('22012'))
	failed << ready_msg(tx_failed)
	send_all(srvs[0], failed)
	if _ := c.async_on_readable() {
		assert false
	}
	assert c.tx_status() == tx_failed
	pool.release(k)
	send_all(srvs[0], rollback_reply)
	pool.maintain()
	assert pool.idle[k]
	assert c.tx_status() == tx_idle
	assert !c.is_broken()
}

fn test_a_failed_release_rollback_breaks_the_connection() {
	mut pool, srvs := pair_pool(1)
	defer {
		pool.close()
		C.close(srvs[0])
	}
	mut scratch := []u8{cap: 4096}
	mut begin_reply := done_reply('BEGIN')
	begin_reply << ready_msg(tx_in_block)

	// No answer within rollback_timeout: broken, and the slot is back to be re-dialed.
	begin_on(mut pool, 0, srvs[0], mut scratch, begin_reply)
	pool.release(0)
	assert !pool.finish_rollback(0), 'not answered yet'
	pool.conns[0].rollback_deadline = 1 // long past
	assert pool.finish_rollback(0)
	assert pool.conns[0].is_broken()
	assert pool.idle[0]
	assert pool.conns[0].inflight_count() == 0, 'nothing left for the re-dial to wait on'
	assert pool.conns[0].rollback_deadline == 0
}

fn test_release_rollback_fails_when_the_server_goes_away() {
	mut pool, srvs := pair_pool(1)
	defer {
		pool.close()
	}
	mut scratch := []u8{cap: 4096}
	mut begin_reply := done_reply('BEGIN')
	begin_reply << ready_msg(tx_in_block)
	begin_on(mut pool, 0, srvs[0], mut scratch, begin_reply)
	pool.release(0)
	C.close(srvs[0]) // the server is gone before it answers
	assert pool.finish_rollback(0)
	assert pool.conns[0].is_broken()
	assert pool.idle[0]
	assert pool.conns[0].inflight_count() == 0
}

fn test_a_rollback_that_leaves_a_transaction_breaks_the_connection() {
	mut pool, srvs := pair_pool(1)
	defer {
		pool.close()
		C.close(srvs[0])
	}
	mut scratch := []u8{cap: 4096}
	mut begin_reply := done_reply('BEGIN')
	begin_reply << ready_msg(tx_in_block)
	begin_on(mut pool, 0, srvs[0], mut scratch, begin_reply)
	pool.release(0)
	mut odd := done_reply('ROLLBACK')
	odd << ready_msg(tx_in_block)
	send_all(srvs[0], odd)
	assert pool.finish_rollback(0)
	assert pool.conns[0].is_broken()
}

fn test_acquire_skips_a_session_left_in_a_transaction() {
	mut pool, srvs := pair_pool(2)
	defer {
		pool.close()
		C.close(srvs[0])
		C.close(srvs[1])
	}
	mut scratch := []u8{cap: 4096}
	mut begin_reply := done_reply('BEGIN')
	begin_reply << ready_msg(tx_in_block)
	// A BEGIN sent through acquire_pipelined() (what the docs forbid).
	j := pool.acquire_pipelined() or { panic('free') }
	assert j == 0
	begin_on(mut pool, j, srvs[0], mut scratch, begin_reply)
	for _ in 0 .. 4 {
		k := pool.acquire_pipelined() or { panic('connection 1 is free') }
		assert k == 1, 'acquire_pipelined() shared a session in a transaction'
	}
	held := pool.acquire() or { panic('connection 1 is free') }
	assert held == 1, 'acquire() took a session in a transaction'
	if k := pool.acquire_pipelined() {
		assert false, 'nothing is shareable, got ${k}'
	}
	if k := pool.acquire() {
		assert false, 'nothing is free, got ${k}'
	}
	// Its COMMIT ends the transaction: shareable again.
	mut c := pool.conn(j)
	assert c.async_submit('commit', no_params)
	assert c.async_flush()!
	mut commit_reply := done_reply('COMMIT')
	commit_reply << ready_msg(tx_idle)
	send_all(srvs[0], commit_reply)
	assert c.async_on_readable()!.ready
	k := pool.acquire_pipelined() or { panic('the committed connection is shareable') }
	assert k == j
	pool.release(held)
}

// The transaction paths allocate nothing once warm: BEGIN, the release-time
// ROLLBACK and its completion by acquire(), a batch and its per-statement
// split. (gc_heap_usage counts bytes allocated since the last collection.)
fn test_transaction_paths_allocate_nothing() {
	mut pool, srvs := pair_pool(1)
	defer {
		pool.close()
		C.close(srvs[0])
	}
	srv := srvs[0]
	mut scratch := []u8{cap: 64 * 1024}
	mut begin_reply := done_reply('BEGIN')
	begin_reply << ready_msg(tx_in_block)
	mut rollback_reply := done_reply('ROLLBACK')
	rollback_reply << ready_msg(tx_idle)
	batch := [Stmt{
		sql:    r'insert into t values ($1)'
		params: [?[]u8('1'.bytes())]
	}, Stmt{
		sql: 'select 2'
	}]
	mut batch_reply := done_reply('INSERT 0 1')
	batch_reply << int_reply(2)
	batch_reply << ready_msg(tx_idle)
	mut sink := u64(0)
	for round in 0 .. 2 {
		before := gc_heap_usage().bytes_since_gc
		for _ in 0 .. 300 {
			i := pool.acquire() or { panic('free') }
			mut c := pool.conn(i)
			c.async_submit('begin', no_params)
			c.async_flush() or { panic(err) }
			drain(srv, mut scratch)
			send_all(srv, begin_reply)
			c.async_on_readable() or { panic(err) }
			pool.release(i) // ROLLBACK
			drain(srv, mut scratch)
			send_all(srv, rollback_reply)
			j := pool.acquire() or { panic('rolled back') }
			mut cj := pool.conn(j)
			cj.async_submit_batch(batch) or { panic(err) }
			cj.async_flush() or { panic(err) }
			drain(srv, mut scratch)
			send_all(srv, batch_reply)
			poll := cj.async_on_readable() or { panic(err) }
			sink += (poll.result.statement(0) or { panic(err) }).rows_affected
			sink += u64((poll.result.statement(1) or { panic(err) }).frames.len)
			pool.release(j)
		}
		after := gc_heap_usage().bytes_since_gc
		if round == 1 { // the first round warms the buffers up
			assert after == before, '${after - before} bytes allocated'
		}
	}
	assert sink > 0
}
