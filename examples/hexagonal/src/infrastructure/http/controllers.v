module http

import application
import core
import x.json2 as json

// Each handler appends its complete response to `out`, the caller's reused
// write buffer, as a vanilla handler does: the JSON body is encoded straight
// into `out` and build_basic_response frames it in place. No body string, no
// returned buffer for the caller to copy. `dates` is the caller's Date cache
// (one per worker behind a server).

// User registration handler
pub fn handle_register(user_uc application.UserUseCase, username string, email string, password string, mut out []u8, mut dates DateCache) {
	user := user_uc.register(username, email, password) or {
		core.append_str(mut out, http_bad_request)
		return
	}
	mark := out.len
	json.encode_append(user, mut out)
	build_basic_response(mut out, mark, 201, mut dates)
}

// User list handler
pub fn handle_list_users(user_uc application.UserUseCase, mut out []u8, mut dates DateCache) {
	users := user_uc.list_users() or {
		core.append_str(mut out, http_server_error)
		return
	}
	mark := out.len
	json.encode_append(users, mut out)
	build_basic_response(mut out, mark, 200, mut dates)
}

// Product add handler
pub fn handle_add_product(product_uc application.ProductUseCase, name string, price f64, mut out []u8, mut dates DateCache) {
	product := product_uc.add_product(name, price) or {
		core.append_str(mut out, http_bad_request)
		return
	}
	mark := out.len
	json.encode_append(product, mut out)
	build_basic_response(mut out, mark, 201, mut dates)
}

// Product list handler
pub fn handle_list_products(product_uc application.ProductUseCase, mut out []u8, mut dates DateCache) {
	products := product_uc.list_products() or {
		core.append_str(mut out, http_server_error)
		return
	}
	mark := out.len
	json.encode_append(products, mut out)
	build_basic_response(mut out, mark, 200, mut dates)
}

// Login handler
pub fn handle_login(auth_uc application.AuthUseCase, username string, password string, mut out []u8, mut dates DateCache) {
	// Wrong password and unknown user get the same 401: the response must not
	// tell which usernames exist.
	user := auth_uc.login(username, password) or {
		core.append_str(mut out, http_unauthorized)
		return
	}
	mark := out.len
	json.encode_append(user, mut out)
	build_basic_response(mut out, mark, 200, mut dates)
}
