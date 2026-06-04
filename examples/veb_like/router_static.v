// wrk --connection 512 --threads 16 --duration 60s http://localhost:3000/users
// Running 1m test @ http://localhost:3000/users
//   16 threads and 512 connections
//   Thread Stats   Avg      Stdev     Max   +/- Stdev
//     Latency     2.68ms   26.57ms 889.43ms   99.58%
//     Req/Sec    24.69k     2.13k   34.53k    73.38%
//   23591731 requests in 1.00m, 1.52GB read
//   Socket errors: connect 0, read 0, write 0, timeout 416
// Requests/sec: 393008.41
// Transfer/sec:     25.86MB
module main

import http_server.http1_1.request_parser

// try_static_route matches an exact route ("METHOD /path"), comparing only up to
// the end of the path — `path_len` excludes any `?query`, so `/users?foo=bar`
// still matches the static route `GET /users`.
pub fn try_static_route(req request_parser.HttpRequest, attr string, attr_len int, path_len int) bool {
	// attr is "METHOD SP path"; it matches iff its length equals
	// method + 1 (the SP) + the query-stripped path, and the bytes are equal.
	if attr_len == req.method.len + 1 + path_len {
		if unsafe { C.memcmp(attr.str, &req.buffer[0], attr_len) } == 0 {
			return true
		}
	}
	return false
}
