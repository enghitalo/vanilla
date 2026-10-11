# simple3 — the handler as a method on an `App`

[examples/simple](../simple/) uses a free function as the handler. Real apps
need resources that live for the whole process (a database pool, config,
caches), and simple3 shows one way to reach them: the routes and controllers
are **methods on an `App` struct**, and `main` registers a closure that
captures the `App` and forwards every handler argument to
`app.handle_request`. The routes, responses and controller bodies are
simple's, unchanged.

The `App` here holds a SQLite connection pool (`vlib/pool` +
`db.sqlite`). It is created at startup and stored in `App.db_pool`, but no
route queries it yet: the example shows the wiring, not database access. For
a server that does query a database from handlers, without blocking a worker,
see [examples/async_db_pg](../async_db_pg/) and
[examples/database](../database/).

## File layout

| File | Role |
|---|---|
| [src/main.v](src/main.v) | `App`, `App.handle_request` (the router), `main` (pool + server) |
| [src/controllers.v](src/controllers.v) | the controllers, as `App` methods returning the full response |

## Run

Needs the SQLite development library (`libsqlite3-dev` on Debian/Ubuntu,
`sqlite` on Arch/Manjaro).

```sh
v -prod run examples/simple3/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)) on the platform's
default backend, and creates (or opens) `simple.db` in the **current
directory** for the pool (`*.db` is git-ignored). If the pool cannot be
created the process panics at startup.

```sh
curl -i localhost:3000/user/123
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 3
Connection: keep-alive

123
```

`GET /` answers an empty `200 OK`, `POST /user` a `201 Created`, and any other
method or path (`/users`, `/nope`) the canned 400, byte for byte as in
[simple](../simple/#run).

## How it works

- **A closure adapts the method to `core.Handler`.** `server.ServerConfig`
  takes a plain function; `main` passes
  `fn [app] (req_buffer, mut out, client_fd, worker_state, mut event_loop) { return app.handle_request(...) }`.
  The closure captures `app` by value when `main` builds it, and every
  worker thread calls the same captured copy.
- **Shared means read-only, or synchronized.** All workers share that `App`,
  so whatever it holds must be safe to use from many threads at once: a
  pool with its own locking, immutable config. Per-thread mutable state
  belongs in `make_state` / `worker_state` instead
  ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
- **Blocking I/O stays off the hot path.** A SQLite call inside a handler
  would block that worker's whole event loop;
  [BEST_PRACTICES §5](../../docs/BEST_PRACTICES.md#5-side-effects-go-through-the-async-runtime--pools-off-the-hot-path)
  covers moving it off.
- **The controllers are simple's.** Each takes `mut out []u8` and appends
  its response: `get_user_controller` reads the path from the request, takes
  the id as a view of it (no copy) and frames the reply with
  `core.append_str` plus `wi`. No route allocates per request.
  `get_users_controller` exists but no route calls it.

## Tests

```sh
v test examples/simple3/src
```

[main_test.v](src/main_test.v) calls `App{}.handle_request` directly on four
raw requests (home, user, create, an `INVALID` method) and checks that no
route allocates.
[server_end_to_end_test.v](src/server_end_to_end_test.v) sends the same four
over real sockets with `vtest.drive`, wiring the handler through the same
closure `main` uses. Both use `App{}` with no pool, which these routes never
touch.

## See also

- [examples/simple](../simple/) — the free-function version
- [examples/simple2](../simple2/) — the same routes, routed by byte offsets
- [examples/hexagonal](../hexagonal/) — app structure with ports and adapters
- [BEST_PRACTICES §6 — concurrency](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)
