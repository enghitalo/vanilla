module main

// Regressions in the demo's wiring (main.v), on the SQLite adapter behind the
// connection pool, against a throwaway database file: the pool stays open and
// gets every connection back, a fresh database gets its `users` table (and a
// second start keeps it), a failed login answers 401, and passwords are stored
// as argon2id hashes that no response carries (#193).
// (Each register/login pays one argon2id: a few seconds in a debug build.)
import application
import db.sqlite
import infrastructure.database
import infrastructure.http
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

	reg := http.handle_register(user_uc, 'alice', 'alice@example.com', 'password123').bytestr()
	assert reg.starts_with('HTTP/1.1 201 Created\r\n'), reg
	login := http.handle_login(auth_uc, 'alice', 'password123').bytestr()
	assert login.starts_with('HTTP/1.1 200 OK\r\n'), login
	assert login.contains('"username":"alice"'), login
	list := http.handle_list_users(user_uc).bytestr()
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
	reg := http.handle_register(user_uc, 'carol', 'carol@example.com', 'password123').bytestr()
	assert reg.starts_with('HTTP/1.1 201 Created\r\n'), reg

	// Wrong password and unknown user: the same 401, not a 404 (and the same
	// argon2id cost, via the dummy hash, for the unknown user).
	for resp in [
		http.handle_login(auth_uc, 'carol', 'wrong password'),
		http.handle_login(auth_uc, 'carol', ''),
		http.handle_login(auth_uc, 'mallory', 'password123'),
	] {
		assert resp.bytestr().starts_with('HTTP/1.1 401 Unauthorized\r\n'), resp.bytestr()
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

	reg := http.handle_register(user_uc, 'alice', 'alice@example.com', plaintext).bytestr()
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

	login := http.handle_login(auth_uc, 'alice', plaintext).bytestr()
	assert login.starts_with('HTTP/1.1 200'), login
	assert login.contains('"username":"alice"')

	list := http.handle_list_users(user_uc).bytestr()
	assert list.starts_with('HTTP/1.1 200'), list
	assert list.contains('"username":"alice"')

	// No `password` / `password_hash` key, no plaintext, no hash — anywhere.
	for resp in [reg, login, list] {
		assert !resp.contains('password'), resp
		assert !resp.contains(plaintext), resp
		assert !resp.contains('argon2'), resp
	}
}
