module repositories

import domain
import db.sqlite
import rand

pub struct SqliteUserRepository {
	get_conn     fn () !sqlite.DB @[required]
	release_conn fn (sqlite.DB) ! @[required]
}

pub fn new_sqlite_user_repository(get_conn fn () !sqlite.DB, release_conn fn (sqlite.DB) !) SqliteUserRepository {
	return SqliteUserRepository{
		get_conn:     get_conn
		release_conn: release_conn
	}
}

pub fn (r SqliteUserRepository) find_by_id(id string) !domain.User {
	mut db := r.get_conn()!
	defer { r.release_conn(db) or { panic(err) } }
	rows := db.exec_param_many('SELECT id, username, email, password FROM users WHERE id = ?', [
		id,
	])!
	if rows.len == 0 {
		return error('not found')
	}
	row := rows[0]
	return domain.User{
		id:       row.vals[0]
		username: row.vals[1]
		email:    row.vals[2]
		password: row.vals[3]
	}
}

pub fn (r SqliteUserRepository) find_by_username(username string) !domain.User {
	mut db := r.get_conn()!
	defer { r.release_conn(db) or { panic(err) } }
	rows := db.exec_param_many('SELECT id, username, email, password FROM users WHERE username = ?', [
		username,
	])!
	if rows.len == 0 {
		return error('not found')
	}
	row := rows[0]
	return domain.User{
		id:       row.vals[0]
		username: row.vals[1]
		email:    row.vals[2]
		password: row.vals[3]
	}
}

pub fn (r SqliteUserRepository) create(user domain.User) !domain.User {
	mut db := r.get_conn()!
	defer { r.release_conn(db) or { panic(err) } }
	id := if user.id == '' { rand.uuid_v4() } else { user.id }
	db.exec_param_many('INSERT INTO users (id, username, email, password) VALUES (?, ?, ?, ?)', [
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

pub fn (r SqliteUserRepository) list() ![]domain.User {
	mut db := r.get_conn()!
	defer { r.release_conn(db) or { panic(err) } }
	mut users := []domain.User{}
	rows := db.exec('SELECT id, username, email, password FROM users')!
	for row in rows {
		users << domain.User{
			id:       row.vals[0]
			username: row.vals[1]
			email:    row.vals[2]
			password: row.vals[3]
		}
	}
	return users
}
