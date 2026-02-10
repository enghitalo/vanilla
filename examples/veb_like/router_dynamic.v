// wrk --connection 512 --threads 16 --duration 60s http://localhost:3000/users/1/posts/2
// Running 1m test @ http://localhost:3000/users/1/posts/2
//   16 threads and 512 connections
//   Thread Stats   Avg      Stdev     Max   +/- Stdev
//     Latency     1.16ms   17.05ms 886.58ms   99.86%
//     Req/Sec    19.53k     3.84k   45.15k    64.27%
//   18667131 requests in 1.00m, 1.70GB read
//   Socket errors: connect 0, read 0, write 0, timeout 416
// Requests/sec: 310602.62
// Transfer/sec:     29.03MB
module main

import http_server.http1_1.request_parser { Slice }

// try_dynamic_route attempts to match a dynamic route (path with parameters like :id)
// Uses a two-pass approach to avoid temporary allocations:
// Pass 1: Validate route matches without extracting parameters
// Pass 2: Extract parameters only if route matched
pub fn try_dynamic_route(parsed_req request_parser.HttpRequest, attr string, attr_len int, mut params map[string]Slice) bool {
	// Find the first colon in the attribute (indicates a parameter)
	colon_pos := find_byte(attr.str, attr_len, `:`) or { return false }

	// Check if the prefix before the colon matches
	if unsafe {
		C.memcmp(attr.str, &parsed_req.buffer[0], colon_pos)
	} != 0 {
		return false
	}

	// Pass 1: Validate the route matches (without extracting parameters)
	if !validate_route_match(parsed_req, attr, attr_len, colon_pos) {
		return false
	}

	// Pass 2: Extract parameters (we know the route matches)
	extract_route_params(parsed_req, attr, attr_len, colon_pos, mut params)
	return true
}

// validate_route_match checks if the route pattern matches without extracting parameters
fn validate_route_match(parsed_req request_parser.HttpRequest, attr string, attr_len int, colon_pos int) bool {
	unsafe {
		mut attr_pos := colon_pos
		mut req_pos := colon_pos
		req_path_end := parsed_req.method.len + 1 + parsed_req.path.len

		for attr_pos < attr_len {
			if attr.str[attr_pos] == `:` {
				attr_pos++ // skip the ':'

				// Skip parameter name (until '/' or end)
				for attr_pos < attr_len && attr.str[attr_pos] != `/` {
					attr_pos++
				}

				// Skip parameter value in request (until '/' or '?' or end)
				for req_pos < req_path_end && parsed_req.buffer[req_pos] != `/`
					&& parsed_req.buffer[req_pos] != `?` && parsed_req.buffer[req_pos] != ` ` {
					req_pos++
				}

				// Check if we're at the end of pattern
				if attr_pos >= attr_len {
					return req_pos >= req_path_end || parsed_req.buffer[req_pos] == `?`
						|| parsed_req.buffer[req_pos] == ` `
				}

				// Both should be at '/' now
				if attr.str[attr_pos] == `/` && parsed_req.buffer[req_pos] == `/` {
					attr_pos++
					req_pos++
				} else {
					return false
				}
			} else {
				// Match literal character
				if req_pos >= req_path_end || attr.str[attr_pos] != parsed_req.buffer[req_pos] {
					return false
				}
				attr_pos++
				req_pos++
			}
		}

		// Check if we consumed the entire request path
		return req_pos >= req_path_end || parsed_req.buffer[req_pos] == `?`
			|| parsed_req.buffer[req_pos] == ` `
	}
}

// extract_route_params extracts parameters from a matched route
fn extract_route_params(parsed_req request_parser.HttpRequest, attr string, attr_len int, colon_pos int, mut params map[string]Slice) {
	unsafe {
		mut attr_pos := colon_pos
		mut req_pos := colon_pos
		req_path_end := parsed_req.method.len + 1 + parsed_req.path.len

		for attr_pos < attr_len {
			if attr.str[attr_pos] == `:` {
				attr_pos++ // skip the ':'

				// Find parameter name
				param_name_start := attr_pos
				for attr_pos < attr_len && attr.str[attr_pos] != `/` {
					attr_pos++
				}
				param_name_len := attr_pos - param_name_start

				// Extract parameter value
				param_value_start := req_pos
				for req_pos < req_path_end && parsed_req.buffer[req_pos] != `/`
					&& parsed_req.buffer[req_pos] != `?` && parsed_req.buffer[req_pos] != ` ` {
					req_pos++
				}
				param_value_len := req_pos - param_value_start

				// Store the parameter
				param_name := tos(attr.str + param_name_start, param_name_len)
				param_key := ':' + param_name
				params[param_key] = Slice{
					start: param_value_start
					len:   param_value_len
				}

				// Move past the '/' if not at end
				if attr_pos < attr_len && req_pos < req_path_end {
					attr_pos++
					req_pos++
				}
			} else {
				// Skip literal character
				attr_pos++
				req_pos++
			}
		}
	}
}

@[inline]
pub fn count_char(buf &u8, len int, c u8) int {
	mut count := 0
	$if gcc {
		unsafe {
			for i in 0 .. len {
				count += if buf[i] == c { 1 } else { 0 }
			}
		}
		return count
	} $else {
		unsafe {
			mut p := buf
			end := buf + len

			for {
				p = C.memchr(p, c, end - p)
				if isnil(p) {
					break
				}
				count++
				p++ // move past the found '/'
			}
		}
	}

	return count
}

@[inline]
fn find_byte(buf &u8, len int, c u8) !int {
	unsafe {
		p := C.memchr(buf, c, len)
		if p == nil {
			return error('byte not found')
		}
		return int(&u8(p) - buf)
	}
}
