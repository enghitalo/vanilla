module repositories

import domain
import db.sqlite
import pool
import rand

pub struct SqliteUserRepository {
	get_conn     fn () !&pool.ConnectionPoolable @[required]
	release_conn fn (&pool.ConnectionPoolable) ! @[required]
}

pub fn new_sqlite_user_repository(get_conn fn () !&pool.ConnectionPoolable, release_conn fn (&pool.ConnectionPoolable) !) SqliteUserRepository {
	return SqliteUserRepository{
		get_conn:     get_conn
		release_conn: release_conn
	}
}

// lookup_failed logs why a find_* query could not run and answers none, as
// for a missing row (both user repositories use it): the callers treat the two
// alike (a failed login is a 401 either way), and the detail stays server-side
// (BEST_PRACTICES §8).
fn lookup_failed(op string, err IError) ?domain.User {
	eprintln('users.${op}: ${err}')
	return none
}

// create_table creates the `users` table the queries below use, unless it
// already exists — idempotent, so it is safe to run on every start.
// exec_param_many, unlike exec, reports a failed step (e.g. SQLITE_BUSY).
pub fn (r SqliteUserRepository) create_table() ! {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	db := conn as sqlite.DB
	db.exec_param_many('CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, email TEXT NOT NULL, password_hash TEXT NOT NULL)',
		[]string{})!
}

pub fn (r SqliteUserRepository) find_by_id(id string) ?domain.User {
	conn := r.get_conn() or { return lookup_failed('find_by_id', err) }
	defer { r.release_conn(conn) or { panic(err) } }
	db := conn as sqlite.DB
	rows := db.exec_param_many('SELECT id, username, email, password_hash FROM users WHERE id = ?', [
		id,
	]) or { return lookup_failed('find_by_id', err) }
	if rows.len == 0 {
		return none
	}
	row := rows[0]
	return domain.User{
		id:            row.vals[0]
		username:      row.vals[1]
		email:         row.vals[2]
		password_hash: row.vals[3]
	}
}

pub fn (r SqliteUserRepository) find_by_username(username string) ?domain.User {
	conn := r.get_conn() or { return lookup_failed('find_by_username', err) }
	defer { r.release_conn(conn) or { panic(err) } }
	db := conn as sqlite.DB
	rows := db.exec_param_many('SELECT id, username, email, password_hash FROM users WHERE username = ?', [
		username,
	]) or { return lookup_failed('find_by_username', err) }
	if rows.len == 0 {
		return none
	}
	row := rows[0]
	return domain.User{
		id:            row.vals[0]
		username:      row.vals[1]
		email:         row.vals[2]
		password_hash: row.vals[3]
	}
}

pub fn (r SqliteUserRepository) create(user domain.User) !domain.User {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	db := conn as sqlite.DB
	id := if user.id == '' { rand.uuid_v4() } else { user.id }
	db.exec_param_many('INSERT INTO users (id, username, email, password_hash) VALUES (?, ?, ?, ?)', [
		id,
		user.username,
		user.email,
		user.password_hash,
	])!
	return domain.User{
		id:            id
		username:      user.username
		email:         user.email
		password_hash: user.password_hash
	}
}

pub fn (r SqliteUserRepository) list() ![]domain.User {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	db := conn as sqlite.DB
	mut users := []domain.User{}
	rows := db.exec('SELECT id, username, email, password_hash FROM users')!
	for row in rows {
		users << domain.User{
			id:            row.vals[0]
			username:      row.vals[1]
			email:         row.vals[2]
			password_hash: row.vals[3]
		}
	}
	return users
}
