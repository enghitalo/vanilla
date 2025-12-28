struct UserController {
}

@['GET /users']
fn (controller UserController) list_users() []u8 {
	return []u8{}
}

@['POST /users']
fn (controller UserController) create_user() []u8 {
	return []u8{}
}

@['GET /users/:id/get']
fn (controller UserController) get_user() []u8 {
	return []u8{}
}

fn main() {
	http1_1_requests := [
		'GET /users'.bytes(),
		'POST /users'.bytes(),
		'GET /users/123/get'.bytes(),
		'GET /users/321/get'.bytes(),
		'GET /users/321/get?a=b'.bytes(),
	]!

	// Controller: list_users
	// Controller: list_users, Attribute: GET /users
	// Controller: create_user
	// Controller: create_user, Attribute: POST /users
	// Controller: get_user
	// Controller: get_user, Attribute: GET /users/:id/get
	$for method in UserController.methods {
		println('Controller: ${method.name}')
		for attr in method.attrs {
			println('Controller: ${method.name}, Attribute: ${attr}')
		}
	}
}
