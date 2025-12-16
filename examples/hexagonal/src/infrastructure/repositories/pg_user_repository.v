module repositories

import domain
import db.pg
import rand

pub struct PgUserRepository {
	db pg.DB
}

pub fn new_pg_user_repository(db pg.DB) PgUserRepository {
	return PgUserRepository{
		db: db
	}
}

pub fn (r PgUserRepository) find_by_id(id string) !domain.User {
       rows := r.db.query('SELECT id, username, email, password FROM users WHERE id = $1', id)!
       if rows.len == 0 {
	       return error('not found')
       }
       row := rows[0]
       return domain.User{
	       id: row.vals[0]
	       username: row.vals[1]
	       email: row.vals[2]
	       password: row.vals[3]
       }
}

pub fn (r PgUserRepository) find_by_username(username string) !domain.User {
       rows := r.db.query('SELECT id, username, email, password FROM users WHERE username = $1', username)!
       if rows.len == 0 {
	       return error('not found')
       }
       row := rows[0]
       return domain.User{
	       id: row.vals[0]
	       username: row.vals[1]
	       email: row.vals[2]
	       password: row.vals[3]
       }
}

pub fn (r PgUserRepository) create(user domain.User) !domain.User {
	id := if user.id == '' { rand.uuid_v4()! } else { user.id }
	r.db.exec('INSERT INTO users (id, username, email, password) VALUES ($1, $2, $3, $4)', id, user.username, user.email, user.password)!
	return domain.User{
		id: id
		username: user.username
		email: user.email
		password: user.password
	}
}

pub fn (r PgUserRepository) list() ![]domain.User {
	mut users := []domain.User{}
	rows := r.db.query('SELECT id, username, email, password FROM users')!
	for row in rows {
		users << domain.User{
			id: row.vals[0]
			username: row.vals[1]
			email: row.vals[2]
			password: row.vals[3]
		}
	}
	return users
}

