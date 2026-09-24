module database

import pool
import db.pg
import db.sqlite

// Abstract DB connection type for pooling
pub type DbConn = pg.DB | sqlite.DB

// // ConnectionPoolable defines the interface for connection objects
// pub interface ConnectionPoolable {
// mut:
// 	// validate checks if the connection is still usable
// 	validate() !bool
// 	// close terminates the physical connection
// 	close() !
// 	// reset returns the connection to initial state for reuse
// 	reset() !
// }
// Statement-form matches: `return match ...` needs every arm to yield a
// value, and `close() !` yields none - the current checker rejects both
// shapes (older V let them through).
fn (c DbConn) validate() !bool {
	match c {
		pg.DB {
			// db.pg has no cheap liveness probe (a ping is a full round-trip),
			// so a pooled pg connection is assumed live until a query fails.
			return true
		}
		sqlite.DB {
			// For SQLite, we can assume the connection is always valid
			return true
		}
	}
}

fn (mut c DbConn) close() ! {
	match mut c {
		pg.DB {
			c.close()!
		}
		sqlite.DB {
			c.close()!
		}
	}
}

fn (mut c DbConn) reset() ! {
	// No-op for now, can add logic if needed
}

// Pool wrapper for both backends
pub struct DbPool {
mut:
	pool    &pool.ConnectionPool
	backend string
}

// Factory for PostgreSQL pool
pub fn new_pg_pool(config pg.Config, pool_cfg pool.ConnectionPoolConfig) !DbPool {
	factory := fn [config] () !&pool.ConnectionPoolable {
		mut db := pg.connect(config)!
		return &db
	}
	mut p := pool.new_connection_pool(factory, pool_cfg)!
	return DbPool{
		pool:    p
		backend: 'pg'
	}
}

// Factory for SQLite pool
pub fn new_sqlite_pool(path string, pool_cfg pool.ConnectionPoolConfig) !DbPool {
	factory := fn [path] () !&pool.ConnectionPoolable {
		mut db := sqlite.connect(path)!
		return &db
	}
	mut p := pool.new_connection_pool(factory, pool_cfg)!
	return DbPool{
		pool:    p
		backend: 'sqlite'
	}
}

// Acquire a DB connection from the pool
pub fn (mut p DbPool) acquire() !DbConn {
	mut conn := p.pool.get()!
	if p.backend == 'pg' {
		return conn as pg.DB
	} else {
		return conn as sqlite.DB
	}
}

// Return a DB connection to the pool
pub fn (mut p DbPool) release(conn DbConn) ! {
	p.pool.put(conn)!
}

pub fn (mut p DbPool) close() ! {
	p.pool.close()
}
