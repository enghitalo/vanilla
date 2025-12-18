module domain

pub struct AuthCredentials {
pub:
	username string
	password string
}

pub interface AuthService {
	authenticate(credentials AuthCredentials) !User
}
