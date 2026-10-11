module main

// Regressions in the demo's wiring (main.v), on the SQLite adapter behind the
// connection pool, against a throwaway database file: the pool stays open and
// gets every connection back, a fresh database gets its `users` table (and a
// second start keeps it), a failed login answers 401, and passwords are stored
// as argon2id hashes that no response carries (#193).
// (Each register/login pays one argon2id: a few seconds in a debug build.)
import application
import db.sqlite
import hash as wyhash
import infrastructure.database
import infrastructure.http
import infrastructure.repositories
import os
import pool
import time

const plaintext = 'correct horse battery staple'

// Two idle connections, as in main(): the pooled connections share one file
// while the pool validates idle ones in the background.
const test_pool_cfg = pool.ConnectionPoolConfig{
	max_conns:      4
	min_idle_conns: 2
	get_timeout:    2 * time.second
}

// temp_db_path names a database file that does not exist yet.
fn temp_db_path(name string) string {
	path := os.join_path(os.temp_dir(), 'vanilla_hexagonal_${name}_${os.getpid()}.db')
	os.rm(path) or {}
	return path
}

// serve_register, serve_login and serve_list_users run one HTTP handler into
// a fresh buffer and return the response it appended.
fn serve_register(user_uc application.UserUseCase, username string, email string, password string) string {
	mut out := []u8{}
	mut dates := http.new_date_cache()
	http.handle_register(user_uc, username, email, password, mut out, mut dates)
	return out.bytestr()
}

fn serve_login(auth_uc application.AuthUseCase, username string, password string) string {
	mut out := []u8{}
	mut dates := http.new_date_cache()
	http.handle_login(auth_uc, username, password, mut out, mut dates)
	return out.bytestr()
}

fn serve_list_users(user_uc application.UserUseCase) string {
	mut out := []u8{}
	mut dates := http.new_date_cache()
	http.handle_list_users(user_uc, mut out, mut dates)
	return out.bytestr()
}

// The HTTP adapter frames the JSON body it encoded into `out` in place: the
// head goes in front of this response's body (not at the start of `out`, which
// may hold earlier pipelined responses), with the exact Content-Length, an
// ETag of the body and the cached Date line.
fn test_response_is_framed_in_place() {
	product_uc := application.new_product_usecase(repositories.DummyProductRepository{})
	mut dates := http.new_date_cache()
	mut out := []u8{cap: 16} // small: the framing must survive a grow of `out`
	out << 'previous'.bytes()
	http.handle_add_product(product_uc, 'Laptop', 999.5, mut out, mut dates)
	resp := out.bytestr()
	assert resp.starts_with('previousHTTP/1.1 201 Created\r\nDate: '), resp
	head := resp.all_before('\r\n\r\n')
	body := resp.all_after('\r\n\r\n')
	assert body == '{"id":"","name":"Laptop","price":999.5}', resp
	assert head.contains('\r\nContent-Type: application/json\r\n'), resp
	assert head.contains('\r\nContent-Length: ${body.len}\r\n'), resp
	etag := wyhash.wyhash_c(body.str, u64(body.len), 0).hex_full()
	assert head.contains('\r\nEtag: "${etag}"\r\n'), resp
	assert head.ends_with('\r\nConnection: close'), resp
	date := head.all_after('\r\nDate: ').all_before('\r\n')
	assert date.len == 29 && date.ends_with(' GMT'), resp

	// A second response into the same buffer, through the same Date cache.
	out.clear()
	http.handle_list_products(product_uc, mut out, mut dates)
	list := out.bytestr()
	assert list.starts_with('HTTP/1.1 200 OK\r\nDate: '), list
	assert list.all_after('\r\nDate: ').all_before('\r\n').len == 29, list
	assert list.ends_with('\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]'), list
}

// Framing allocates nothing: the product list (an empty array from the dummy
// repository, so the use case allocates nothing either) runs 20k times through
// one reused buffer. The other handlers allocate in the layers below the
// adapter — argon2, the database rows, json2's number formatting — not in
// the framing.
fn test_framing_allocates_nothing() {
	$if gcboehm ? {
		product_uc := application.new_product_usecase(repositories.DummyProductRepository{})
		mut dates := http.new_date_cache()
		mut out := []u8{cap: 1024}
		http.handle_list_products(product_uc, mut out, mut dates) // warm-up
		rounds := 20_000
		before := gc_heap_usage().total_bytes
		for _ in 0 .. rounds {
			unsafe {
				out.len = 0
			}
			http.handle_list_products(product_uc, mut out, mut dates)
		}
		grown := gc_heap_usage().total_bytes - before
		assert grown < 4096, 'allocated ${grown} bytes over ${rounds} responses'
	}
}

fn test_fresh_database_serves_register_login_and_list() ! {
	path := temp_db_path('fresh')
	mut dbpool := database.new_sqlite_pool(path, test_pool_cfg)!
	defer {
		dbpool.close() or {}
		os.rm(path) or {}
	}
	// What main() does: the repository borrows the pool and creates the table.
	repo := new_user_repository('sqlite', mut dbpool)!
	user_uc := application.new_user_usecase(repo)
	auth_uc := application.new_auth_usecase(http.new_simple_auth_service(repo))

	reg := serve_register(user_uc, 'alice', 'alice@example.com', 'password123')
	assert reg.starts_with('HTTP/1.1 201 Created\r\n'), reg
	login := serve_login(auth_uc, 'alice', 'password123')
	assert login.starts_with('HTTP/1.1 200 OK\r\n'), login
	assert login.contains('"username":"alice"'), login
	list := serve_list_users(user_uc)
	assert list.starts_with('HTTP/1.1 200 OK\r\n'), list
	assert list.contains('"username":"alice"'), list

	// More calls than the pool has connections: each one must go back to the
	// pool, or get() runs dry and times out.
	for _ in 0 .. 2 * test_pool_cfg.max_conns {
		users := user_uc.list_users()!
		assert users.len == 1
	}
}

fn test_users_table_creation_is_idempotent() ! {
	path := temp_db_path('restart')
	defer {
		os.rm(path) or {}
	}
	mut first := database.new_sqlite_pool(path, test_pool_cfg)!
	repo := new_user_repository('sqlite', mut first)!
	application.new_user_usecase(repo).register('bob', 'bob@example.com', 'password123')!
	first.close()!

	// A second start on the same file: CREATE TABLE IF NOT EXISTS is a no-op
	// that keeps the rows.
	mut second := database.new_sqlite_pool(path, test_pool_cfg)!
	defer {
		second.close() or {}
	}
	again := new_user_repository('sqlite', mut second)!
	users := application.new_user_usecase(again).list_users()!
	assert users.len == 1
	assert users[0].username == 'bob'
}

fn test_failed_login_is_401() ! {
	path := temp_db_path('login')
	mut dbpool := database.new_sqlite_pool(path, test_pool_cfg)!
	defer {
		dbpool.close() or {}
		os.rm(path) or {}
	}
	repo := new_user_repository('sqlite', mut dbpool)!
	user_uc := application.new_user_usecase(repo)
	auth_uc := application.new_auth_usecase(http.new_simple_auth_service(repo))
	reg := serve_register(user_uc, 'carol', 'carol@example.com', 'password123')
	assert reg.starts_with('HTTP/1.1 201 Created\r\n'), reg

	// Wrong password and unknown user: the same 401, not a 404 (and the same
	// argon2id cost, via the dummy hash, for the unknown user).
	for resp in [
		serve_login(auth_uc, 'carol', 'wrong password'),
		serve_login(auth_uc, 'carol', ''),
		serve_login(auth_uc, 'mallory', 'password123'),
	] {
		assert resp.starts_with('HTTP/1.1 401 Unauthorized\r\n'), resp
	}
}

// Password-handling regression (#193): register, login and list run through
// the real use cases, auth service, HTTP handlers and SQLite adapter. Asserts
// that no response carries the password or its hash, and that the database
// stores an argon2id hash, not the plaintext.
fn test_password_is_hashed_and_never_serialized() ! {
	path := temp_db_path('hash')
	mut dbpool := database.new_sqlite_pool(path, test_pool_cfg)!
	defer {
		dbpool.close() or {}
		os.rm(path) or {}
	}
	repo := new_user_repository('sqlite', mut dbpool)!
	user_uc := application.new_user_usecase(repo)
	auth_uc := application.new_auth_usecase(http.new_simple_auth_service(repo))

	reg := serve_register(user_uc, 'alice', 'alice@example.com', plaintext)
	assert reg.starts_with('HTTP/1.1 201'), reg
	assert reg.contains('"username":"alice"')

	// Stored: an argon2id PHC string, never the plaintext.
	conn := dbpool.acquire()!
	defer {
		dbpool.release(conn) or {}
	}
	db := conn as sqlite.DB
	rows := db.exec('SELECT password_hash FROM users')!
	assert rows.len == 1
	stored := rows[0].vals[0]
	assert stored != plaintext
	assert stored.starts_with('$argon2id$')

	login := serve_login(auth_uc, 'alice', plaintext)
	assert login.starts_with('HTTP/1.1 200'), login
	assert login.contains('"username":"alice"')

	list := serve_list_users(user_uc)
	assert list.starts_with('HTTP/1.1 200'), list
	assert list.contains('"username":"alice"')

	// No `password` / `password_hash` key, no plaintext, no hash — anywhere.
	for resp in [reg, login, list] {
		assert !resp.contains('password'), resp
		assert !resp.contains(plaintext), resp
		assert !resp.contains('argon2'), resp
	}
}
