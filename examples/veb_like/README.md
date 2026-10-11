# veb-like router (production reference)

Declarative routing for vanilla: annotate the methods of your `App` with
`@['METHOD /path']` and the router dispatches to them. It keeps the project
values — the handler is still the core contract (append the raw response into
`out`, return a `core.Step`), responses are framed from consts, and a request
**allocates nothing**, whatever its outcome.

The router itself is the generic module
[`http1_1.veb_like`](../../http1_1/veb_like/), written to be extracted into its
own library; `src/` is an app that uses it. Like `http1_1.router`, it routes
HTTP/1.x requests.

## Declaring routes

```v
import http1_1.veb_like { Params }

@['GET /users/:id/posts/:post_id']
fn (app &App) user_post(req HttpRequest, p &Params, mut out []u8) core.Step {
	// p.get('id'), p.get('post_id'): zero-copy views of the request bytes
	return .done
}

@['GET /files/*path']   // catch-all: /files/css/app.css -> p.get('path') == 'css/app.css'
fn (app &App) serve_file(req HttpRequest, p &Params, mut out []u8) core.Step { ... }

fn main() {
	router := veb_like.new[App](&App{})!   // compiles the routes; a routing mistake fails here
	mut srv := server.new_server(server.ServerConfig{
		handler: fn [router] (req []u8, mut out []u8, fd int, ws voidptr, mut el core.EventLoop) core.Step {
			return router.handle(req, mut out, fd, ws, mut el)
		}
		// ...
	})!
	srv.run()
}
```

- **`:name`** matches one non-empty path segment; **`*name`** (last segment
  only) matches the rest of the path, slashes included, possibly empty.
- Static segments win over `:name`, which wins over `*name`; a dead end
  backtracks (`/a/b/c` and `/a/:x/d` both work, `/a/b/d` reaches the second).
- A param's name belongs to its route: `/users/:id` and
  `/users/:user_id/posts/:post_id` share a trie node without conflict.
- Matching is byte-exact (case-sensitive, not percent-decoded) and stops at `?`;
  query values come from `req.get_query_slice(key)`, a view into the request buffer.
- `p.get(name)` returns a view into the request buffer, valid until the handler
  returns — `.clone()` what must outlive it. Up to 8 params per route.

### Two handler shapes

```v
fn (app &App) short(req HttpRequest, p &Params, mut out []u8) core.Step
fn (app &App) long(req HttpRequest, p &Params, mut out []u8, client_fd int, worker_state voidptr, mut event_loop core.EventLoop) core.Step
```

The long shape is the whole `core.Handler` contract, so a route can park the
request on an fd (`event_loop.watch_fd` + `.suspend`: an async DB query, a
timer, an upstream), read its worker's state, or `.close`. `GET /delay/:ms` in
[main.v](src/main.v) suspends on a timerfd ([delay_linux.c.v](src/delay_linux.c.v)).

A method of `App` that returns `core.Step` and carries attributes is a handler,
so it must have one of these shapes (a clear compile error says so otherwise).
Without attributes it is an ordinary method, whatever its parameters.

### Routes in this example

| Pattern | Kind |
|---------|------|
| `GET /users`, `POST /users` | static |
| `GET\|PUT\|PATCH\|DELETE /users/:id` | one param, many verbs (→ 405 lists them) |
| `GET /users/:id/profile` | param + literal tail |
| `GET /users/:user_id/posts/:post_id` | two params |
| `GET /users/:user_id/posts/:post_id/comments/:comment_id` | three params, deep |
| `GET /tags/:a/:b/:c` | three consecutive params |
| `GET /search/:term` | single param |
| `GET /files/*path`, `GET /proxy/*upstream` | catch-all (captures slashes) |
| `GET /delay/:ms` | suspends on a timer (long handler shape) |

## How it works

Everything that can be decided before the first request is decided once, in
`veb_like.new`:

1. **Compile.** One `$for` over `App`'s methods reads each `@['METHOD /path']`
   attribute into a segment trie (static children, one `:name` child, one
   `*name` child per node; a route id per method slot). Malformed routes and
   two handlers for the same method + path are errors, at startup.
2. **Prebuild the 405s.** Each node a route ends at gets its complete
   `405 Method Not Allowed` response, `Allow` header included.

Per request: `decode_into` → method to a slot index → walk the trie (O(path
depth), independent of the number of routes) → one direct call. The dispatch
is a `$for` over the methods comparing an integer; GCC turns it into a jump
table and inlines the handlers.

**Nothing is allocated per request** — not for a hit, a 404, a 405, a 501 or a
400 (`test_routing_allocates_nothing`). Under `-gc none`, vanilla's production
build, any per-request allocation would be a permanent leak. Two choices keep it
there (see [docs/V_PERF_TOOLBOX.md](../../docs/V_PERF_TOOLBOX.md)):

- `Params` stores its eight slots as plain fields, not a `[8]Slice`: V still
  copies a struct holding a fixed array to the heap when the function it is
  passed to passes it on, as every handler does with `p.get(name)`;
- params live in that stack struct, not a `map[string]Slice` (a map plus a
  clone of every key, per request).

## Performance

Measured on an AMD Ryzen 7 5800H (8 cores / 16 threads), `-prod -gc none`,
`VANILLA_WORKERS=8`, wrk on the same machine (`-t6 -c256`), this rewrite
against the previous `examples/veb_like` (a linear attribute scan with a
`map` of params and a returned `[]u8` per response):

| | before | after |
|---|---:|---:|
| memory per request (`-gc none`, RSS slope) | **+1,179 B** (a leak: 6.9 → 17.7 GiB over 9.6M requests) | **0 B** (flat 7 MiB over 31.6M) |
| `GET /users/7/posts/99`, keep-alive | 256k req/s | 390k req/s |
| `GET /users/7/posts/99`, pipelined ×16 | 0.95M req/s | 2.60M req/s |
| `GET /nope/x` (404), pipelined ×16 | 0.47M req/s | 2.67M req/s |

In process ([`bench/router/router_bench.v`](../../bench/router/router_bench.v):
route + a small reply, one core), next to the hand-written tree of
[`examples/router`](../router/) on the same routes:

| request | veb_like | router |
|---|---:|---:|
| `GET /users` | 80 ns | 39 ns |
| `GET /users/42` | 103 ns | 51 ns |
| `GET /users/7/posts/99/comments/5` | 170 ns | 94 ns |
| `GET /files/css/app.css` | 104 ns | 50 ns |
| `POST /users/42` (405) | 68 ns | 22 ns |
| `GET /nope/x` (404) | 59 ns | 17 ns |

`router` reads only the request line. `veb_like` parses the whole request,
because its handlers receive it, then walks a trie instead of compiled
branches and looks params up by name. Over a socket the two are level (≈380k
req/s keep-alive, ≈2.6M pipelined ×16): the kernel path dominates.

## HTTP behavior

- **400 + close** for a request the parser rejects — never a panic, which would
  end the whole server process (every worker).
- **404** when no route matches the path (`router.not_found` can be replaced
  before the server starts, e.g. with a page); **405** with `Allow` when the
  path exists under other methods.
- **HEAD** is served by the GET route when no HEAD route exists: the router
  drops the body the handler wrote (not for a handler that suspends — it answers
  later; check `req.method` there if it matters).
- **501** for a method outside RFC 9110's nine (methods are case-sensitive).
- Only origin-form targets (`/…`) are routed; `*` and absolute-form get a 404.

The app adds: accurate `Content-Length` (computed while framing), JSON-escaped
URL values (no injection), `Limits` (header/body size, connection cap,
read/write/idle timeouts) and graceful shutdown on SIGTERM/SIGINT.

## Files

| File | Role |
|------|------|
| [`http1_1/veb_like/router.v`](../../http1_1/veb_like/router.v) | `new` (compile), `handle` (match + dispatch), the trie |
| [`http1_1/veb_like/params.v`](../../http1_1/veb_like/params.v) | `Params`: the matched values, on the stack |
| [`http1_1/veb_like/router_test.v`](../../http1_1/veb_like/router_test.v) | the router's own contract: priority, backtracking, startup errors |
| `src/main.v` | `App`, its handlers, the production server config |
| `src/responses.v` | zero-allocation response framing straight into `out` |
| `src/delay_linux.c.v` | the timerfd behind `/delay/:ms` |
| `src/main_test.v` | every route type, HTTP edge cases, suspend/resume, zero allocation |

## Run

```sh
v -prod run examples/veb_like/src
v test examples/veb_like/src
```
