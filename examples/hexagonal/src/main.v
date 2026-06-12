module main

import db.pg
import db.sqlite
import domain
import infrastructure.database
import infrastructure.repositories
import infrastructure.http
import application
import pool
import time

fn main() {
	// Choose database backend: "pg" or "sqlite"
	db_backend := 'sqlite' // change to 'pg' for PostgreSQL

	// Pool config
	pool_cfg := pool.ConnectionPoolConfig{
		max_conns:      10
		min_idle_conns: 2
		max_lifetime:   1 * time.hour
		idle_timeout:   10 * time.minute
		get_timeout:    5 * time.second
	}

	if db_backend != 'pg' && db_backend != 'sqlite' {
		panic('Unknown db_backend: ${db_backend}')
	}

	// User repository (switchable)
	user_repo := if db_backend == 'pg' {
		config := pg.Config{
			host:     'localhost'
			port:     5432
			user:     'postgres'
			password: 'postgres'
			dbname:   'hexagonal'
		}
		mut dbpool := database.new_pg_pool(config, pool_cfg) or {
			panic('Failed to create PG pool: ' + err.msg())
		}
		defer { dbpool.close() or { panic('Failed to close PG pool: ' + err.msg()) } }
		get_conn := fn [mut dbpool] () !pg.DB {
			conn := dbpool.acquire()!
			return conn as pg.DB
		}
		release_conn := fn [mut dbpool] (conn pg.DB) ! {
			dbpool.release(conn)!
		}
		domain.UserRepository(repositories.new_pg_user_repository(get_conn, release_conn))
	} else {
		mut dbpool := database.new_sqlite_pool('hexagonal.db', pool_cfg) or {
			panic('Failed to create SQLite pool: ' + err.msg())
		}
		defer { dbpool.close() or { panic('Failed to close SQLite pool: ' + err.msg()) } }
		get_conn := fn [mut dbpool] () !sqlite.DB {
			conn := dbpool.acquire()!
			return conn as sqlite.DB
		}
		release_conn := fn [mut dbpool] (conn sqlite.DB) ! {
			dbpool.release(conn)!
		}
		domain.UserRepository(repositories.new_sqlite_user_repository(get_conn, release_conn))
	}

	product_repo := repositories.DummyProductRepository{}

	// Infrastructure: auth service
	auth_service := http.new_simple_auth_service(user_repo)

	// Application: use cases
	user_uc := application.new_user_usecase(user_repo)
	product_uc := application.new_product_usecase(product_repo)
	auth_uc := application.new_auth_usecase(auth_service)

	// Example usage (replace with real HTTP server integration)
	println('Register user:')
	resp := http.handle_register(user_uc, 'alice', 'alice@example.com', 'password123')
	println(resp.bytestr())

	println('Login:')
	resp2 := http.handle_login(auth_uc, 'alice', 'password123')
	println(resp2.bytestr())

	println('List users:')
	resp3 := http.handle_list_users(user_uc)
	println(resp3.bytestr())

	println('Add product:')
	resp4 := http.handle_add_product(product_uc, 'Laptop', 999.99)
	println(resp4.bytestr())
}
