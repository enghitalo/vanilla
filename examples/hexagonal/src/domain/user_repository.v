module domain

pub struct User {
pub:
	id       string
	username string
	email    string
	// argon2id PHC string (`$argon2id$v=19$m=...$<salt>$<hash>`), never the
	// plaintext. `json: '-'` keeps it out of every response that encodes a User.
	password_hash string @[json: '-']
}

// A lookup that finds no user is routine (a mistyped login), so the find
// methods answer `none`, which costs nothing, rather than an error() that
// boxes a message on every miss.
pub interface UserRepository {
	find_by_id(id string) ?User
	find_by_username(username string) ?User
	create(user User) !User
	list() ![]User
}
