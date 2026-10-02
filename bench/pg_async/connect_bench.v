module main

// What a (re-)dial costs the worker, against a local PostgreSQL (the PG* env
// vars; pg_async/testdata/throwaway_pg.sh starts one):
//   - a BLOCKING connect (PgConn.connect: TCP + SCRAM-SHA-256), which a
//     re-dial on the request path would stall the worker for;
//   - PBKDF2 alone, the SCRAM part of it (ScramCache computes it once per pool);
//   - the pool's non-blocking re-dial (PgPool.maintain() called every 2 ms,
//     as its timer does): how long a broken slot takes to be healthy again,
//     and the longest single maintain() call, the worker's actual stall.
//
//   v -prod run bench/pg_async/connect_bench.v
import os
import time
import pg_async
import crypto.pbkdf2
import crypto.sha256

const reps = 20

fn main() {
	cfg := pg_async.ConnConfig{
		host:     '127.0.0.1'
		port:     os.getenv('PGPORT').int()
		user:     os.getenv('PGUSER')
		password: os.getenv('PGPASSWORD')
		database: os.getenv('PGDATABASE')
	}
	mut best := i64(1) << 62
	mut total := i64(0)
	for _ in 0 .. reps {
		sw := time.new_stopwatch()
		mut c := pg_async.PgConn.connect(cfg) or { panic(err) }
		el := sw.elapsed().microseconds()
		c.close()
		total += el
		if el < best {
			best = el
		}
	}
	println('PgConn.connect (blocking, TCP + SCRAM-SHA-256, loopback): min ${best} us, mean ${total / reps} us')
	mut pbest := i64(1) << 62
	for _ in 0 .. reps {
		sw := time.new_stopwatch()
		k := pbkdf2.key('benchpw'.bytes(), 'saltsaltsaltsalt'.bytes(), 4096, 32, sha256.new()) or {
			panic(err)
		}
		el := sw.elapsed().microseconds()
		if el < pbest {
			pbest = el
		}
		_ = k
	}
	println('pbkdf2-sha256 4096 iterations: min ${pbest} us')
	mut p := pg_async.PgPool.connect(cfg, 1) or { panic(err) }
	defer {
		p.close()
	}
	mut rbest := i64(1) << 62
	mut rtotal := i64(0)
	mut stall := i64(0)
	for _ in 0 .. reps {
		p.conn(0).mark_broken()
		sw := time.new_stopwatch()
		for p.is_broken(0) {
			call := time.new_stopwatch()
			p.maintain()
			c := call.elapsed().microseconds()
			if c > stall {
				stall = c
			}
			if p.is_broken(0) {
				time.sleep(2 * time.millisecond)
			}
		}
		el := sw.elapsed().microseconds()
		rtotal += el
		if el < rbest {
			rbest = el
		}
	}
	println('pool re-dial (maintain() every 2 ms): broken -> healthy min ${rbest} us, mean ${rtotal / reps} us; longest maintain() call ${stall} us')
}
