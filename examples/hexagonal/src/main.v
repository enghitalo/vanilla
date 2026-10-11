module main

import db.pg
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
		panic('Unknown db_backend: ' + db_backend)
	}

	// The pool is opened, and its close deferred, at function scope: a `defer`
	// runs when its enclosing scope ends, so inside the `if` that picks the
	// backend it would close the pool before any use case below runs.
	mut dbpool := if db_backend == 'pg' {
		config := pg.Config{
			host:     'localhost'
			port:     5432
			user:     'postgres'
			password: 'postgres'
			dbname:   'hexagonal'
		}
		database.new_pg_pool(config, pool_cfg) or { panic('Failed to create PG pool: ' + err.msg()) }
	} else {
		database.new_sqlite_pool('hexagonal.db', pool_cfg) or {
			panic('Failed to create SQLite pool: ' + err.msg())
		}
	}
	defer { dbpool.close() or { panic('Failed to close DB pool: ' + err.msg()) } }

	// User repository (switchable)
	user_repo := new_user_repository(db_backend, mut dbpool) or {
		panic('Failed to create the users table: ' + err.msg())
	}

	product_repo := repositories.DummyProductRepository{}

	// Infrastructure: auth service
	auth_service := http.new_simple_auth_service(user_repo)

	// Application: use cases
	user_uc := application.new_user_usecase(user_repo)
	product_uc := application.new_product_usecase(product_repo)
	auth_uc := application.new_auth_usecase(auth_service)

	// Example usage (replace with real HTTP server integration). The handlers
	// append into one reused buffer, as a server's write buffer; behind a
	// server, `out` is the connection's and `dates` is per-worker state.
	mut dates := http.new_date_cache()
	mut out := []u8{cap: 1024}

	println('Register user:')
	http.handle_register(user_uc, 'alice', 'alice@example.com', 'password123', mut out, mut
		dates)
	println(out.bytestr())

	println('Login:')
	out.clear()
	http.handle_login(auth_uc, 'alice', 'password123', mut out, mut dates)
	println(out.bytestr())

	println('List users:')
	out.clear()
	http.handle_list_users(user_uc, mut out, mut dates)
	println(out.bytestr())

	println('Add product:')
	out.clear()
	http.handle_add_product(product_uc, 'Laptop', 999.99, mut out, mut dates)
	println(out.bytestr())
}

// new_user_repository wires the `db_backend` user adapter to `dbpool` and
// creates its `users` table if it does not exist yet. The repository borrows
// connections from the pool, so keep the pool open while the repository is used.
fn new_user_repository(db_backend string, mut dbpool database.DbPool) !domain.UserRepository {
	get_conn := fn [mut dbpool] () !&pool.ConnectionPoolable {
		return dbpool.acquire()!
	}
	release_conn := fn [mut dbpool] (conn &pool.ConnectionPoolable) ! {
		dbpool.release(conn)!
	}
	if db_backend == 'pg' {
		repo := repositories.new_pg_user_repository(get_conn, release_conn)
		repo.create_table()!
		return repo
	}
	repo := repositories.new_sqlite_user_repository(get_conn, release_conn)
	repo.create_table()!
	return repo
}
