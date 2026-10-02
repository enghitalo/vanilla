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
	db.exec('CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, email TEXT NOT NULL, password TEXT NOT NULL)')!
}

pub fn (r PgUserRepository) find_by_id(id string) !domain.User {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	rows := db.exec_param_many('SELECT id, username, email, password FROM users WHERE id = $1', [
		id,
	])!
	if rows.len == 0 {
		return error('not found')
	}
	row := rows[0]
	return domain.User{
		id:       row.vals[0] or { '' }
		username: row.vals[1] or { '' }
		email:    row.vals[2] or { '' }
		password: row.vals[3] or { '' }
	}
}

pub fn (r PgUserRepository) find_by_username(username string) !domain.User {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	rows := db.exec_param_many('SELECT id, username, email, password FROM users WHERE username = $1', [
		username,
	])!
	if rows.len == 0 {
		return error('not found')
	}
	row := rows[0]
	return domain.User{
		id:       row.vals[0] or { '' }
		username: row.vals[1] or { '' }
		email:    row.vals[2] or { '' }
		password: row.vals[3] or { '' }
	}
}

pub fn (r PgUserRepository) create(user domain.User) !domain.User {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	id := if user.id == '' { rand.uuid_v4() } else { user.id }
	db.exec_param_many('INSERT INTO users (id, username, email, password) VALUES ($1, $2, $3, $4)', [
		id,
		user.username,
		user.email,
		user.password,
	])!
	return domain.User{
		id:       id
		username: user.username
		email:    user.email
		password: user.password
	}
}

pub fn (r PgUserRepository) list() ![]domain.User {
	conn := r.get_conn()!
	defer { r.release_conn(conn) or { panic(err) } }
	mut db := conn as pg.DB
	mut users := []domain.User{}
	rows := db.exec_param_many('SELECT id, username, email, password FROM users', [])!
	for row in rows {
		users << domain.User{
			id:       row.vals[0] or { '' }
			username: row.vals[1] or { '' }
			email:    row.vals[2] or { '' }
			password: row.vals[3] or { '' }
		}
	}
	return users
}
