# router — routing as code (the fastest option)

The router is your `core.Handler` itself, written as `match` statements over
the request's path segments. The [`router`](../../router/router.v) module
supplies the pieces that make that fast and correct; nothing is registered,
looked up or allocated at runtime, every branch is plain code the compilers see
whole, and params are typed locals the V compiler checks.

Same routes, same responses and same production properties as
[`examples/veb_like`](../veb_like/) — the declarative alternative — so the two
are directly comparable (their tests are the same assertions).

## The pieces

```v
import router { Method, Path }

m := router.method(req)                      // Method enum: one length switch, one compare
mut path := router.path(req) or { ... 404 }  // zero-copy cursor; none for `*` / absolute-form
path.next()   // 'users', then '42', for /users/42 ('' for an empty segment or when spent)
path.done()   // every segment popped? (false for /users/ after 'users')
path.rest()   // the catch-all: 'css/app.css' after popping 'files' from /files/css/app.css

const user_405 = router.allow(.get, .head, .put, .delete, .patch) // a 405 + Allow, built once
router.drop_body(mut out, start)  // HEAD served by a GET branch: keep the head, drop the body
router.bad_request, router.not_found, router.not_implemented      // canned responses
```

Every segment is a view into the request buffer (valid until the handler
returns — `.clone()` what must outlive it), raw (not percent-decoded); the
query is never part of the path.

## Writing the tree

[`main.v`](src/main.v) parses, answers 400/501 itself, and drops the body of a
HEAD response; [`routes.v`](src/routes.v) is the tree. Each node is a function
that pops the segments it owns and either answers or hands the cursor on:

```v
fn route(m Method, mut path Path, mut out []u8, mut event_loop core.EventLoop) core.Step {
	match path.next() {
		'users' { return users(m, mut path, mut out) }
		'files' { return catch_all(m, mut path, mut out, '{"file":') }
		else { return not_found(mut out) }
	}
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
(else its own 405 const), so the HTTP outcome sits right next to the route.
Because the handler *is* the router, a branch has the whole contract at hand:
`/delay/:ms` parks on a timerfd and returns `.suspend`
([delay_linux.c.v](src/delay_linux.c.v)).

## Why it is the fastest

Per request: `decode_into`, the method switch, then one `memchr` per segment
and the `match` compares (length first, then bytes) — no trie walk, no param
table, no name lookups, no indirect call. Neither router allocates
(`test_routing_allocates_nothing`); in process
([`bench/router/router_bench.v`](../../bench/router/router_bench.v), one core,
AMD Ryzen 7 5800H) this one is 11–30% faster than `veb_like`:

| request | router | veb_like |
|---|---:|---:|
| `GET /users` | 68 ns | 77 ns |
| `GET /users/42` | 80 ns | 95 ns |
| `GET /users/7/posts/99/comments/5` | 121 ns | 156 ns |
| `GET /files/css/app.css` | 77 ns | 98 ns |
| `POST /users/42` (405) | 52 ns | 60 ns |
| `GET /nope/x` (404) | 49 ns | 54 ns |

Over a socket the two are level (≈390k req/s keep-alive, ≈2.6M pipelined ×16
with 8 workers on that machine): the kernel path dominates long before routing
does. The gap shows where routing is a larger share of the work — pipelined
traffic, many cores, cheap handlers.

The cost is explicitness: the tree is code you write, the 404/405 branches
included. Prefer [`veb_like`](../veb_like/) when a flat, declarative list of
routes matters more than the last nanoseconds.

## Run

```sh
v -prod run examples/router/src
v test examples/router/src
```
