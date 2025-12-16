module database

import db.pg

import db.sqlite

// SQLite connection pool (trivial, as SQLite is file-based and thread-safe for most use cases)
pub struct SqliteConnectionPool {
	db sqlite.DB
}

pub fn new_sqlite_connection_pool(path string) !SqliteConnectionPool {
	db := sqlite.connect(path)!
	return SqliteConnectionPool{
		db: db
	}
}

pub fn (mut pool SqliteConnectionPool) acquire() !sqlite.DB {
	return pool.db
}

pub fn (mut pool SqliteConnectionPool) release(_ sqlite.DB) {
	// No-op for SQLite
}

pub fn (mut pool SqliteConnectionPool) close() {
	pool.db.close()
}

pub struct ConnectionPool {
mut:
	connections chan pg.DB
	config      pg.Config
}

pub fn new_connection_pool(config pg.Config, size int) !ConnectionPool {
	mut connections := chan pg.DB{cap: size}
	for _ in 0 .. size {
		conn := pg.connect(config)!
		connections <- conn
	}
	return ConnectionPool{
		connections: connections
		config:      config
	}
}

pub fn (mut pool ConnectionPool) acquire() !pg.DB {
	return <-pool.connections or { return error('Connection pool exhausted') }
}

pub fn (mut pool ConnectionPool) release(conn pg.DB) {
	pool.connections <- conn
}

pub fn (mut pool ConnectionPool) close() {
	for _ in 0 .. pool.connections.len {
		mut conn := <-pool.connections or { break }
		conn.close()
	}
}
