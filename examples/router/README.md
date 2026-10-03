# router — routing as code (the fastest option)

The router is your `core.Handler` itself, written as `match` statements over
the request's path segments. The [`router`](../../router/router.v) module only
reads the request line, straight from the raw request: nothing is registered,
looked up, parsed or allocated to route, every branch is plain code the
compilers see whole, and params are typed locals the V compiler checks. Every
response, 404 and 405 included, is the app's.

Same routes as [`examples/veb_like`](../veb_like/) — the declarative
alternative — with byte-identical responses, so the two are directly
comparable.

## The module

```v
import router { Method, Path }

m := router.method(req_buffer)      // Method enum: a switch on the first space, one compare
mut path := router.path(req_buffer) // zero-copy cursor over the path; never fails
path.next()   // 'users', then '42', for /users/42 ('' for an empty segment or when spent)
path.done()   // every segment popped? (false for /users/ after 'users')
path.rest()   // the catch-all: 'css/app.css' after popping 'files' from /files/css/app.css
```

Every segment is a view into the request buffer (valid until the handler
returns — `.clone()` what must outlive it), raw (not percent-decoded); the
query is never part of the path. A request line with no path to route — `*`,
absolute-form, or malformed — yields a single segment that no route matches,
so it falls into the app's 404.

Routing parses no headers. A route that needs them decodes the request itself
(`request_parser.decode_into`, answering `response.tiny_bad_request_response`
if that fails); malformed framing never reaches a handler, the server answers
it with 400.

## Writing the tree

[`routes.v`](src/routes.v) is the whole app: `route`, the root node, is the
handler the server calls ([`main.v`](src/main.v) only configures the server).
Each node is a function that pops the segments it owns and either answers or
hands the cursor on:

```v
fn route(req_buffer []u8, mut out []u8, _ int, _ voidptr, mut event_loop core.EventLoop) core.Step {
	m := router.method(req_buffer)
	mut path := router.path(req_buffer)
	start := out.len
	step := match path.next() {
		'users' { users(m, mut path, mut out) }
		'files' { catch_all(m, mut path, mut out, '{"file":') }
		else { not_found(mut out) }
	}
	if m == .head && step != .suspend {
		drop_body(mut out, start) // HEAD: GET's headers, no body
	}
	return step
}

fn users(m Method, mut path Path, mut out []u8) core.Step {
	if path.done() { // /users
		match m {
			.get, .head { out << users_list_response }
			.post { out << user_created_response }
			else { out << users_405 }
		}
		return .done
	}
	id := path.next() // /users/:id — a typed local, not a map lookup
	...
}
```

A leaf checks the path is fully consumed first (else 404), then the method
(else its own 405 const, whose `Allow` lists exactly what its branches serve),
so the HTTP outcome sits right next to the route. A method no branch serves,
unknown ones included, gets that 405. Because the handler *is* the router, a
branch has the whole contract at hand: `/delay/:ms` parks on a timerfd and
returns `.suspend` ([delay_linux.c.v](src/delay_linux.c.v)).

## Why it is the fastest

Per request: the method switch, one scan of the request target, then one
`memchr` per segment and the `match` compares (length first, then bytes) — no
header parse, no trie walk, no param table, no name lookups, no indirect call.
Neither router allocates (`test_routing_allocates_nothing`). In process
([`bench/router/router_bench.v`](../../bench/router/router_bench.v), one core,
AMD Ryzen 7 5800H), `veb_like` also parsing the whole request, since its
handlers receive it:

| request | router | veb_like |
|---|---:|---:|
| `GET /users` | 39 ns | 80 ns |
| `GET /users/42` | 51 ns | 103 ns |
| `GET /users/7/posts/99/comments/5` | 94 ns | 170 ns |
| `GET /files/css/app.css` | 50 ns | 104 ns |
| `POST /users/42` (405) | 22 ns | 68 ns |
| `GET /nope/x` (404) | 17 ns | 59 ns |

Over a socket the two are level (≈380k req/s keep-alive, ≈2.6M pipelined ×16
with 8 workers on that machine): the kernel path dominates long before routing
does. The gap shows where routing is a larger share of the work — pipelined
traffic, many cores, cheap handlers.

The cost is explicitness: the tree is code you write, its 404 and 405
responses included. Prefer [`veb_like`](../veb_like/) when a flat, declarative
list of routes matters more than the last nanoseconds.

## Run

```sh
v -prod run examples/router/src
v test examples/router/src
```
