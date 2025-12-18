module domain

pub struct User {
pub:
	id       string
	username string
	email    string
	password string // hashed
}

pub interface UserRepository {
	find_by_id(id string) !User
	find_by_username(username string) !User
	create(user User) !User
	list() ![]User
}
