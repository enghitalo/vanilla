module application

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
	// Hash password (placeholder, use real hash in production)
	hashed := password // TODO: hash
	user := domain.User{
		id:       '' // generate UUID in infra
		username: username
		email:    email
		password: hashed
	}
	return u.repo.create(user)
}

pub fn (u UserUseCase) list_users() ![]domain.User {
	return u.repo.list()
}
