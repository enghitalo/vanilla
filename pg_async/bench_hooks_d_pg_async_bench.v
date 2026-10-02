module pg_async

// Benchmark hooks, compiled ONLY with `-d pg_async_bench` (the _d_ file
// suffix): a normal build carries none of this. bench/pg_async/codec_bench.v
// drives the real async_submit / async_on_readable over a socketpair(2) with
// them, without a server: PgConn.connect dials TCP and authenticates, which a
// codec micro-benchmark must neither pay nor depend on.

// bench_conn_on_fd wraps an already-connected socket as a ready connection
// (the state PgConn.connect leaves behind after its handshake).
pub fn bench_conn_on_fd(fd int) PgConn {
	mut c := new_conn()
	c.fd = fd
	c.broken = false
	return c
}

// bench_discard_inflight forgets the in-flight queries and the unsent request
// bytes, as if every query had been sent and answered: the reset between two
// rounds of the serialization benchmark.
pub fn (mut c PgConn) bench_discard_inflight() {
	unsafe {
		c.inflight.len = 0
	}
	c.bench_discard_sends()
}

// bench_discard_sends drops the unsent request bytes only (the queries stay in
// flight, waiting for replies the benchmark feeds through the socketpair).
pub fn (mut c PgConn) bench_discard_sends() {
	c.send_off = 0
	c.send_len = 0
}
