module main

// Helper to create controller for tests
fn new_test_controller() App {
	return App{}
}

fn test_static_routes() {
	println('Testing static routes...')

	user_controller := new_test_controller()

	// Test GET /users
	req1 := 'GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response1 := handle_request(req1, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response1_str := response1.bytestr()
	assert response1_str.contains('200 OK'), 'Expected 200 OK for GET /users'
	println('  ✅ GET /users returns 200 OK')

	// Test POST /users
	req2 := 'POST /users HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response2 := handle_request(req2, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response2_str := response2.bytestr()
	assert response2_str.contains('201 Created'), 'Expected 201 Created for POST /users'
	assert response2_str.contains('"id": 1'), 'Expected {"id": 1} in response'
	println('  ✅ POST /users returns 201 Created with body')
}

fn test_single_parameter_route() {
	println('Testing single parameter routes...')

	user_controller := new_test_controller()

	// Test GET /users/123/get
	req := 'GET /users/123/get HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response := handle_request(req, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response_str := response.bytestr()
	assert response_str.contains('200 OK'), 'Expected 200 OK'
	assert response_str.contains('"id": "123"'), 'Expected id=123 in response body'
	println('  ✅ GET /users/123/get extracts id=123')

	// Test with different ID
	req2 := 'GET /users/abc/get HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response2 := handle_request(req2, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response2_str := response2.bytestr()
	assert response2_str.contains('"id": "abc"'), 'Expected id=abc in response body'
	println('  ✅ GET /users/abc/get extracts id=abc')
}

fn test_multiple_parameter_route() {
	println('Testing multiple parameter routes...')

	user_controller := new_test_controller()

	// Test GET /users/456/posts/789
	req := 'GET /users/456/posts/789 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response := handle_request(req, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response_str := response.bytestr()
	assert response_str.contains('200 OK'), 'Expected 200 OK'
	assert response_str.contains('"id": "456"'), 'Expected id=456 in response body'
	assert response_str.contains('"post_id": "789"'), 'Expected post_id=789 in response body'
	println('  ✅ GET /users/456/posts/789 extracts id=456 and post_id=789')
}

fn test_route_not_found() {
	println('Testing 404 not found...')

	user_controller := new_test_controller()

	// Test non-existent route
	req := 'GET /nonexistent HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response := handle_request(req, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response_str := response.bytestr()
	assert response_str.contains('404 Not Found'), 'Expected 404 Not Found'
	println('  ✅ GET /nonexistent returns 404 Not Found')

	// Test partial match should also fail
	req2 := 'GET /users/123 HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response2 := handle_request(req2, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response2_str := response2.bytestr()
	assert response2_str.contains('404 Not Found'), 'Expected 404 Not Found for partial match'
	println('  ✅ GET /users/123 (no /get suffix) returns 404 Not Found')
}

fn test_route_with_query_string() {
	println('Testing routes with query strings...')

	user_controller := new_test_controller()

	// Test with query string
	req := 'GET /users/999/get?format=json&pretty=true HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response := handle_request(req, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response_str := response.bytestr()
	assert response_str.contains('200 OK'), 'Expected 200 OK'
	assert response_str.contains('"id": "999"'), 'Expected id=999 extracted despite query string'
	println('  ✅ GET /users/999/get?format=json extracts id=999 (ignores query string)')
}

fn test_method_mismatch() {
	println('Testing method mismatch...')

	user_controller := new_test_controller()

	// Try POST on GET-only route
	req := 'POST /users/123/get HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()
	response := handle_request(req, -1, user_controller) or {
		panic('Failed to handle request: ${err}')
	}
	response_str := response.bytestr()
	assert response_str.contains('404 Not Found'), 'Expected 404 for method mismatch'
	println('  ✅ POST /users/123/get returns 404 (method mismatch)')
}
