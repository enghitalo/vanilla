module http

import crypto.argon2
import domain

pub struct SimpleAuthService {
	repo domain.UserRepository
}

pub fn new_simple_auth_service(repo domain.UserRepository) SimpleAuthService {
	return SimpleAuthService{
		repo: repo
	}
}

// dummy_password_phc is verified when the username does not exist, so an
// unknown user costs the same argon2id as a wrong password and the response
// time does not reveal which usernames are registered. It hashes random bytes
// nobody kept; an unknown user is rejected whatever its verify returns.
const dummy_password_phc = '$argon2id$v=19$m=65536,t=3,p=4$+HT4+8cnppa9vdY2WNeDeA$i46FiSCvyyEaI/W6Z8X5/sSjmRtSzG5NWcQFEVOuWOc'

// authenticate re-derives the key with the salt and parameters stored in the
// user's PHC string and compares in constant time (argon2 uses hmac.equal) —
// the verify of examples/auth. ~200 ms BY DESIGN: behind a vanilla server, run
// it off the event loop as examples/auth does (offload_nix.c.v).
pub fn (a SimpleAuthService) authenticate(credentials domain.AuthCredentials) !domain.User {
	mut known := true
	user := a.repo.find_by_username(credentials.username) or {
		known = false
		domain.User{
			password_hash: dummy_password_phc
		}
	}
	password := unsafe { credentials.password.str.vbytes(credentials.password.len) } // view
	phc := unsafe { user.password_hash.str.vbytes(user.password_hash.len) } // view
	argon2.compare_hash_and_password(password, phc) or { return error('Authentication failed') }
	if !known {
		return error('Authentication failed')
	}
	return user
}
