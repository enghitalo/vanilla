module main

// Password-handling regression (#193): register, login and list run through
// the real use cases, auth service, HTTP handlers and SQLite adapter, against a
// throwaway database file. Asserts that no response carries the password or its
// hash, and that the database stores an argon2id hash, not the plaintext.
// (Each register/login pays one argon2id: a few seconds in a debug build.)
import application
import db.sqlite
import domain
import infrastructure.http
import infrastructure.repositories
import os

const plaintext = 'correct horse battery staple'

fn temp_db() !(string, sqlite.DB) {
	path := os.join_path(os.temp_dir(), 'vanilla_hexagonal_test_${os.getpid()}.db')
	os.rm(path) or {}
	mut db := sqlite.connect(path)!
	db.exec('CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, email TEXT NOT NULL, password_hash TEXT NOT NULL)')!
	return path, db
}

fn test_password_is_hashed_and_never_serialized() ! {
	path, mut db := temp_db()!
	defer {
		db.close() or {}
		os.rm(path) or {}
	}
	repo := domain.UserRepository(repositories.new_sqlite_user_repository(fn [db] () !sqlite.DB {
		return db
	}, fn (_ sqlite.DB) ! {}))
	user_uc := application.new_user_usecase(repo)
	auth_uc := application.new_auth_usecase(http.new_simple_auth_service(repo))

	reg := http.handle_register(user_uc, 'alice', 'alice@example.com', plaintext).bytestr()
	assert reg.starts_with('HTTP/1.1 201'), reg
	assert reg.contains('"username":"alice"')

	// Stored: an argon2id PHC string, never the plaintext.
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

fn test_login_rejects_wrong_password_and_unknown_user() ! {
	path, mut db := temp_db()!
	defer {
		db.close() or {}
		os.rm(path) or {}
	}
	repo := domain.UserRepository(repositories.new_sqlite_user_repository(fn [db] () !sqlite.DB {
		return db
	}, fn (_ sqlite.DB) ! {}))
	user_uc := application.new_user_usecase(repo)
	auth_uc := application.new_auth_usecase(http.new_simple_auth_service(repo))
	assert http.handle_register(user_uc, 'bob', 'bob@example.com', plaintext).bytestr().starts_with('HTTP/1.1 201')

	assert http.handle_login(auth_uc, 'bob', 'wrong password').bytestr().starts_with('HTTP/1.1 404')
	assert http.handle_login(auth_uc, 'bob', '').bytestr().starts_with('HTTP/1.1 404')
	// Unknown user: same answer (and the same argon2id cost, via the dummy hash).
	assert http.handle_login(auth_uc, 'mallory', plaintext).bytestr().starts_with('HTTP/1.1 404')
}
