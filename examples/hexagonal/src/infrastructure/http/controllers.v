module http

import application
import x.json2 as json

// User registration handler
pub fn handle_register(user_uc application.UserUseCase, username string, email string, password string) []u8 {
	user := user_uc.register(username, email, password) or { return http_bad_request }
	body := json.encode(user)
	return build_basic_response(201, body.bytes(), 'application/json'.bytes())
}

// User list handler
pub fn handle_list_users(user_uc application.UserUseCase) []u8 {
	users := user_uc.list_users() or { return http_server_error }
	body := json.encode(users)
	return build_basic_response(200, body.bytes(), 'application/json'.bytes())
}

// Product add handler
pub fn handle_add_product(product_uc application.ProductUseCase, name string, price f64) []u8 {
	product := product_uc.add_product(name, price) or { return http_bad_request }
	body := json.encode(product)
	return build_basic_response(201, body.bytes(), 'application/json'.bytes())
}

// Product list handler
pub fn handle_list_products(product_uc application.ProductUseCase) []u8 {
	products := product_uc.list_products() or { return http_server_error }
	body := json.encode(products)
	return build_basic_response(200, body.bytes(), 'application/json'.bytes())
}

// Login handler
pub fn handle_login(auth_uc application.AuthUseCase, username string, password string) []u8 {
	user := auth_uc.login(username, password) or { return http_not_found }

	body := json.encode(user)
	return build_basic_response(200, body.bytes(), 'application/json'.bytes())
}
