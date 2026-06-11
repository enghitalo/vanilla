module repositories

import domain
import db.pg
import rand

pub struct PgUserRepository {
	get_conn     fn () !pg.DB @[required]
	release_conn fn (pg.DB) ! @[required]
}

pub fn new_pg_user_repository(get_conn fn () !pg.DB, release_conn fn (pg.DB) !) PgUserRepository {
	return PgUserRepository{
		get_conn:     get_conn
		release_conn: release_conn
	}
}

pub fn (r PgUserRepository) find_by_id(id string) !domain.User {
	mut db := r.get_conn()!
	defer { r.release_conn(db) or { panic(err) } }
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
	mut db := r.get_conn()!
	defer { r.release_conn(db) or { panic(err) } }
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
	mut db := r.get_conn()!
	defer { r.release_conn(db) or { panic(err) } }
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
	mut db := r.get_conn()!
	defer { r.release_conn(db) or { panic(err) } }
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
