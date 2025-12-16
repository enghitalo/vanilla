module http

import strings
import application
import domain
import json

const http_ok = 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'.bytes()
const http_created = 'HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n'.bytes()

const http_not_modified = 'HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const http_bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const http_not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()
const http_server_error = 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.bytes()

const content_length_header = 'Content-Length: '.bytes()
const connection_close_header = 'Connection: close\r\n\r\n'.bytes()


// Helper to build HTTP response
fn build_response(header []u8, body string) []u8 {
	mut sb := strings.new_builder(200)
	sb.write(header)!
	sb.write(content_length_header)!
	sb.write_string(body.len.str())!
	sb.write(u8(`\r`))!
	sb.write(u8(`\n`))!
	sb.write_string(body)
	return sb
}

// User registration handler
pub fn handle_register(user_uc application.UserUseCase, username string, email string, password string) []u8 {
	user := user_uc.register(username, email, password) or {
		return http_bad_request
	}
	body := json.encode(user)
	return build_response(http_created, body)
}

// User list handler
pub fn handle_list_users(user_uc application.UserUseCase) []u8 {
	users := user_uc.list_users() or {
		return http_server_error
	}
	body := json.encode(users)
	return build_response(http_ok, body)
}

// Product add handler
pub fn handle_add_product(product_uc application.ProductUseCase, name string, price f64) []u8 {
	product := product_uc.add_product(name, price) or {
		return http_bad_request
	}
	body := json.encode(product)
	return build_response(http_created, body)
}

// Product list handler
pub fn handle_list_products(product_uc application.ProductUseCase) []u8 {
	products := product_uc.list_products() or {
		return http_server_error
	}
	body := json.encode(products)
	return build_response(http_ok, body)
}

// Login handler
pub fn handle_login(auth_uc application.AuthUseCase, username string, password string) []u8 {
	user := auth_uc.login(username, password) or {
		return http_bad_request
	}
	if user == none {
		return http_not_found
	}
	body := json.encode(user)
	return build_response(http_ok, body)
}
