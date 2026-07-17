// Pre-rewrite record (measured before the const-framing / lazy-params-map
// rewrite; re-measure with -prod before quoting):
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

import http1_1.request_parser { Slice }

// match_dynamic_route matches a parameterized route (e.g. `/users/:id`) and, on
// a match, returns the extracted params. `path_len` is the request path length
// WITHOUT the `?query`, so route boundaries never bleed into the query string.
// Two passes (validate, then extract) mean a NON-match allocates nothing — not
// even the params map, which is created only here, after validation, right
// before extraction fills it.
pub fn match_dynamic_route(parsed_req request_parser.HttpRequest, attr string, attr_len int, path_len int) ?map[string]Slice {
	// Find the first colon in the attribute (indicates a parameter)
	colon_pos := find_byte(attr.str, attr_len, `:`) or { return none }

	// Check if the prefix before the colon matches (this includes "METHOD SP",
	// so the method must match too).
	if unsafe {
		C.memcmp(attr.str, &parsed_req.buffer[0], colon_pos)
	} != 0 {
		return none
	}

	// Pass 1: Validate the route matches (without extracting parameters)
	if !validate_route_match(parsed_req, attr, attr_len, colon_pos, path_len) {
		return none
	}

	// Pass 2: Extract parameters (we know the route matches)
	mut params := map[string]Slice{}
	extract_route_params(parsed_req, attr, attr_len, colon_pos, path_len, mut params)
	return params
}

// validate_route_match checks if the route pattern matches without extracting parameters
fn validate_route_match(parsed_req request_parser.HttpRequest, attr string, attr_len int, colon_pos int, path_len int) bool {
	unsafe {
		mut attr_pos := colon_pos
		mut req_pos := colon_pos
		req_path_end := parsed_req.method.len + 1 + path_len

		for attr_pos < attr_len {
			if attr.str[attr_pos] == `:` {
				attr_pos++ // skip the ':'

				// Skip parameter name (until '/' or end)
				for attr_pos < attr_len && attr.str[attr_pos] != `/` {
					attr_pos++
				}

				// Skip parameter value in request (until '/' or end of path)
				for req_pos < req_path_end && parsed_req.buffer[req_pos] != `/` {
					req_pos++
				}

				// Check if we're at the end of pattern
				if attr_pos >= attr_len {
					return req_pos >= req_path_end
				}

				// Both should be at '/' now
				if attr.str[attr_pos] == `/` && req_pos < req_path_end
					&& parsed_req.buffer[req_pos] == `/` {
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

		// Match only if we consumed the entire request path
		return req_pos >= req_path_end
	}
}

// extract_route_params extracts parameters from a matched route
fn extract_route_params(parsed_req request_parser.HttpRequest, attr string, attr_len int, colon_pos int, path_len int, mut params map[string]Slice) {
	unsafe {
		mut attr_pos := colon_pos
		mut req_pos := colon_pos
		req_path_end := parsed_req.method.len + 1 + path_len

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
				for req_pos < req_path_end && parsed_req.buffer[req_pos] != `/` {
					req_pos++
				}
				param_value_len := req_pos - param_value_start

				// Store the parameter. The key ":name" is a zero-copy view over
				// the attribute INCLUDING the ':' — it sits at
				// param_name_start-1, guaranteed present because this branch was
				// entered on attr.str[attr_pos] == `:` before attr_pos++. The
				// old `':' + name` concat allocated per param per request; the
				// view is free. Lifetime-safe: attrs are comptime literals
				// (static), and V maps clone string keys on insert anyway
				// (vlib/builtin/map.v, map_clone_string).
				param_key := tos(attr.str + param_name_start - 1, param_name_len + 1)
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
fn find_byte(buf &u8, len int, c u8) !int {
	unsafe {
		hit := C.memchr(buf, c, len)
		if hit == nil {
			return error('byte not found')
		}
		return int(&u8(hit) - buf)
	}
}

// scan_attr walks a route attribute ONCE and returns (slash count, index of the
// first '*' or -1). Folding both into a single pass keeps the hot loop's
// per-route cost the same as before while letting it recognize wildcard routes.
@[inline]
fn scan_attr(buf &u8, len int) (int, int) {
	mut slashes := 0
	mut star := -1
	unsafe {
		for i in 0 .. len {
			c := buf[i]
			if c == `/` {
				slashes++
			} else if c == `*` && star < 0 {
				star = i
			}
		}
	}
	return slashes, star
}

// match_wildcard_route matches a catch-all route ("METHOD /prefix/*name"): the
// literal prefix up to '*' must match, and EVERYTHING remaining in the path —
// slashes included — is captured under the key "*name". `star` is the '*' index
// in attr (from scan_attr), so there's no rescan. Wildcards bypass the
// slash-count gate because '*' spans a variable number of segments. The params
// map is created only after the prefix matched, so a non-match allocates
// nothing.
fn match_wildcard_route(req request_parser.HttpRequest, attr string, attr_len int, star int, path_len int) ?map[string]Slice {
	req_path_end := req.method.len + 1 + path_len
	// The request must be at least as long as the literal prefix.
	if req_path_end < star {
		return none
	}
	// Prefix ("METHOD /prefix/") must match byte-for-byte.
	if unsafe { C.memcmp(attr.str, &req.buffer[0], star) } != 0 {
		return none
	}
	// The key "*name" is a zero-copy view over the attribute starting AT the
	// '*' (attr.str + star), so no `'*' + name` concat. Lifetime-safe: attrs
	// are comptime literals (static), and V maps clone string keys on insert
	// anyway (vlib/builtin/map.v, map_clone_string).
	key := unsafe { tos(attr.str + star, attr_len - star) }
	mut params := map[string]Slice{}
	params[key] = Slice{
		start: star
		len:   req_path_end - star
	}
	return params
}
