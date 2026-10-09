module database

import pool
import db.pg
import db.sqlite

// Pool wrapper for both backends
pub struct DbPool {
mut:
	pool &pool.ConnectionPool
}

// Factory for PostgreSQL pool
pub fn new_pg_pool(config pg.Config, pool_cfg pool.ConnectionPoolConfig) !DbPool {
	factory := fn [config] () !&pool.ConnectionPoolable {
		// pg.connect already returns a `&pg.DB`; `&db` of it would hand the
		// pool a `&&pg.DB`, which does not implement ConnectionPoolable.
		return pg.connect(config)!
	}
	mut p := pool.new_connection_pool(factory, pool_cfg)!
	return DbPool{
		pool: p
	}
}

// Factory for SQLite pool
pub fn new_sqlite_pool(path string, pool_cfg pool.ConnectionPoolConfig) !DbPool {
	factory := fn [path] () !&pool.ConnectionPoolable {
		mut db := sqlite.connect(path)!
		// The pooled connections share one file: wait for a lock another one
		// (or the pool's background validation) holds, instead of failing the
		// statement at once with SQLITE_BUSY.
		db.busy_timeout(5000)
		return &db
	}
	mut p := pool.new_connection_pool(factory, pool_cfg)!
	return DbPool{
		pool: p
	}
}

// acquire checks a connection out of the pool. Cast it to the backend's DB
// (`conn as sqlite.DB`) to run queries, and hand this same handle to release:
// the pool tracks its connections by handle, so a copy (or the cast DB) put
// back is "unmanaged" — the pool closes it and returns an error.
pub fn (mut p DbPool) acquire() !&pool.ConnectionPoolable {
	return p.pool.get()!
}

// release returns a handle from acquire to the pool.
pub fn (mut p DbPool) release(conn &pool.ConnectionPoolable) ! {
	p.pool.put(conn)!
}

pub fn (mut p DbPool) close() ! {
	p.pool.close()
}
