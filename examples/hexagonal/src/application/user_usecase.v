module application

import crypto.argon2
import domain

pub struct UserUseCase {
	repo domain.UserRepository
}

pub fn new_user_usecase(repo domain.UserRepository) UserUseCase {
	return UserUseCase{
		repo: repo
	}
}

pub fn (u UserUseCase) register(username string, email string, password string) !domain.User {
	// Only an argon2id hash is stored, the scheme examples/auth uses: RFC 9106
	// defaults, a random per-user salt, parameters embedded in the PHC string.
	// The plaintext goes no further than this call (a view, not a copy).
	// SLOW AND MEMORY-HARD BY DESIGN (~200 ms, 64 MiB). This example calls its
	// use cases directly, so it hashes inline; behind a vanilla server, run it
	// OFF the event loop like examples/auth's offload pool (offload_nix.c.v),
	// or one sign-up stalls every connection on that worker.
	hash := argon2.generate_from_password(unsafe { password.str.vbytes(password.len) })!
	user := domain.User{
		id:            '' // generate UUID in infra
		username:      username
		email:         email
		password_hash: hash
	}
	return u.repo.create(user)
}

pub fn (u UserUseCase) list_users() ![]domain.User {
	return u.repo.list()
}
