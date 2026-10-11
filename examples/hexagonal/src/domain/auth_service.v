module domain

pub struct AuthCredentials {
pub:
	username string
	password string
}

pub interface AuthService {
	// authenticate answers none when the credentials do not match a user.
	authenticate(credentials AuthCredentials) ?User
}
