module repositories

import domain
import db.sqlite
import rand

pub struct SqliteUserRepository {
    db sqlite.DB
}

pub fn new_sqlite_user_repository(db sqlite.DB) SqliteUserRepository {
    return SqliteUserRepository{
        db: db
    }
}

pub fn (r SqliteUserRepository) find_by_id(id string) !domain.User {
    rows := r.db.exec('SELECT id, username, email, password FROM users WHERE id = ?', id)!
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

pub fn (r SqliteUserRepository) find_by_username(username string) !domain.User {
    rows := r.db.exec('SELECT id, username, email, password FROM users WHERE username = ?', username)!
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

pub fn (r SqliteUserRepository) create(user domain.User) !domain.User {
    id := if user.id == '' { rand.uuid_v4()! } else { user.id }
    r.db.exec('INSERT INTO users (id, username, email, password) VALUES (?, ?, ?, ?)', id, user.username, user.email, user.password)!
    return domain.User{
        id: id
        username: user.username
        email: user.email
        password: user.password
    }
}

pub fn (r SqliteUserRepository) list() ![]domain.User {
    mut users := []domain.User{}
    rows := r.db.exec('SELECT id, username, email, password FROM users')!
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
