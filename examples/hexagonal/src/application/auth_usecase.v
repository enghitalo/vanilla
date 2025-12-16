module application

import domain

pub struct AuthUseCase {
	service domain.AuthService
}

pub fn new_auth_usecase(service domain.AuthService) AuthUseCase {
	return AuthUseCase{
		service: service
	}
}

pub fn (a AuthUseCase) login(username string, password string) !domain.User {
	credentials := domain.AuthCredentials{
		username: username
		password: password
	}
	return a.service.authenticate(credentials)
}

