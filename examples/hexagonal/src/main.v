module main

import db.pg
import infrastructure.database
import infrastructure.repositories
import infrastructure.http
import application
// import domain

fn main() {
	// Choose database backend: "pg" or "sqlite"
	db_backend := 'sqlite' // change to 'pg' for PostgreSQL

	// User repository (switchable)
	user_repo := match db_backend {
		'pg' {
			// PostgreSQL connection
			config := pg.Config{
				host:     'localhost'
				port:     5432
				user:     'postgres'
				password: 'postgres'
				dbname:   'hexagonal'
			}
			mut pool := database.new_connection_pool(config, 5) or {
				panic('Failed to create connection pool: ' + err.msg())
			}
			defer {
				pool.close()
			}
			mut db := pool.acquire() or { panic('Failed to acquire DB connection: ' + err.msg()) }
			defer {
				pool.release(db)
			}
			repositories.new_pg_user_repository(db)
		}
		'sqlite' {
			// SQLite connection
			mut pool := database.new_sqlite_connection_pool('hexagonal.db') or {
				panic('Failed to open SQLite DB: ' + err.msg())
			}
			defer {
				pool.close()
			}
			db := pool.acquire() or { panic('Failed to acquire SQLite DB: ' + err.msg()) }
			repositories.new_sqlite_user_repository(db)
		}
		else {
			panic('Unknown db_backend')
		}
	}

	// TODO: implement ProductRepository for real use
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
}
