module repositories

import domain
import db.pg
import pool
import rand

pub struct PgUserRepository {
	get_conn     fn () !&pool.ConnectionPoolable @[required]
	release_conn fn (&pool.ConnectionPoolable) ! @[required]
}

pub fn new_pg_user_repository(get_conn fn () !&pool.ConnectionPoolable, release_conn fn (&pool.ConnectionPoolable) !) PgUserRepository {
	return PgUserRepository{
		get_conn:     get_conn
		release_conn: release_conn
	}
}

// create_table creates the `users` table the queries below use, unless it
// already exists — idempotent, so it is safe to run on every start.
pub fn (r PgUserRepository) create_table() ! {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	db.exec('CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, email TEXT NOT NULL, password_hash TEXT NOT NULL)')!
}

pub fn (r PgUserRepository) find_by_id(id string) ?domain.User {
	conn := r.get_conn() or { return lookup_failed('find_by_id', err) }
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	rows := db.exec_param_many('SELECT id, username, email, password_hash FROM users WHERE id = $1', [
		id,
	]) or { return lookup_failed('find_by_id', err) }
	if rows.len == 0 {
		return none
	}
	row := rows[0]
	return domain.User{
		id:            row.vals[0] or { '' }
		username:      row.vals[1] or { '' }
		email:         row.vals[2] or { '' }
		password_hash: row.vals[3] or { '' }
	}
}

pub fn (r PgUserRepository) find_by_username(username string) ?domain.User {
	conn := r.get_conn() or { return lookup_failed('find_by_username', err) }
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	rows := db.exec_param_many('SELECT id, username, email, password_hash FROM users WHERE username = $1', [
		username,
	]) or { return lookup_failed('find_by_username', err) }
	if rows.len == 0 {
		return none
	}
	row := rows[0]
	return domain.User{
		id:            row.vals[0] or { '' }
		username:      row.vals[1] or { '' }
		email:         row.vals[2] or { '' }
		password_hash: row.vals[3] or { '' }
	}
}

pub fn (r PgUserRepository) create(user domain.User) !domain.User {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	id := if user.id == '' { rand.uuid_v4() } else { user.id }
	db.exec_param_many('INSERT INTO users (id, username, email, password_hash) VALUES ($1, $2, $3, $4)', [
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

pub fn (r PgUserRepository) list() ![]domain.User {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	mut users := []domain.User{}
	rows := db.exec_param_many('SELECT id, username, email, password_hash FROM users', [])!
	for row in rows {
		users << domain.User{
			id:            row.vals[0] or { '' }
			username:      row.vals[1] or { '' }
			email:         row.vals[2] or { '' }
			password_hash: row.vals[3] or { '' }
		}
	}
	return users
}
