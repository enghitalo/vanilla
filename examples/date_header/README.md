# date_header — one shared `Date` cache, refreshed by a ticker thread

Every response should carry a `Date:` header (RFC 9110 §6.6.1), but it only
has 1-second resolution, so formatting it per request is wasted work. Here one
`DateCache` for the whole server holds the pre-formatted `Date: …\r\n` line,
a background thread rewrites it once a second, and the handler just appends
it: no clock read, no formatting on the request path.

It is one of two takes on the same problem. This one shares a single cache
across all workers and publishes it lock-free with a double buffer;
[examples/efficient_date](../efficient_date/) gives each worker its own cache
and refreshes it lazily, when a request sees the second has changed (see
[the comparison below](#date_header-vs-efficient_date)).

## Run

```sh
v -prod run examples/date_header/src
```

It listens on `:3000` (set in [main.v](src/main.v)), on epoll on Linux and
kqueue on macOS. Every method and path gets the same reply:

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Date: Sun, 11 Oct 2026 04:10:16 GMT
Content-Type: text/plain
Content-Length: 2
Connection: keep-alive

ok
```

## How it works

- **The cache is app state, not a global.** `main` allocates the
  `DateCache`, seeds it and formats the first date before serving; the
  handler closure and the ticker thread both capture it.
- **Fixed buffers, seeded once.** The cache holds two fixed 37-byte buffers
  (`date_line_len`: `Date: ` + the 29-byte IMF-fixdate + CRLF). `seed`
  copies `line_template` into both, so `refresh` only rewrites date bytes at
  offset 6, with `time.update_http_header`: only the digits that changed
  since that buffer was last written (mostly the seconds), no format string,
  no intermediate string, no allocation. The first write of each buffer, and
  the first after midnight, formats the whole date; there V's weekday lookup
  allocates a small array, once a day.
- **Double buffering, lock-free.** `refresh` formats into the inactive buffer
  (`1 - idx`), then publishes it with `stdatomic.store_u64(&c.idx, next)`.
  `date_line` does one `stdatomic.load_u64` and returns a view of the active
  buffer. The writer never touches the buffer readers were just told to use;
  it rewrites it a second later, by which time a reader's 37-byte copy is long
  done
  ([BEST_PRACTICES §6](../../docs/BEST_PRACTICES.md#6-concurrency-no-shared-mutable-state-without-protection)).
- **One ticker for the server.** A single `spawn`ed loop does
  `time.sleep(time.second)` then `cache.refresh()`, forever: one format per
  second whatever the traffic or the number of workers.
- **The handler is three appends.** `respond` does
  `core.append_str(mut out, status_head)`, `out << cache.date_line()`,
  `core.append_str(mut out, resp_tail)`: two `const` halves around the cached
  line, straight into `out`, with no per-request `strings.Builder`.
  `date_line` returns a `vbytes` view of the active buffer, not
  `bufs[i][..]`, which builds a new heap array on every call; the tests check
  that neither `respond` nor `refresh` allocates
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).

## date_header vs efficient_date

| | date_header | [efficient_date](../efficient_date/) |
| --- | --- | --- |
| Cache | one, shared by every worker | one per worker (`make_state`) |
| Refresh | a ticker thread, every ~1 s | lazily, by the first request in a new second |
| Per-request work | one atomic load + copy | one `time.unix_now()` + copy |
| Freshness | up to ~1 s behind (sleep-paced, not aligned to the second) | always the current second |
| Backends | epoll, kqueue | epoll (Linux) only |

Both servers polled side by side every half second:

```
04:10:17.487 dh=04:10:17 ed=04:10:17
04:10:18.004 dh=04:10:17 ed=04:10:18
04:10:18.520 dh=04:10:18 ed=04:10:18
04:10:19.036 dh=04:10:18 ed=04:10:19
```

A value up to a second old is still a valid `Date`. [BEST_PRACTICES
§3](../../docs/BEST_PRACTICES.md#3-avoid--interpolation-on-the-hot-path)
records the measurement: under `wrk` the two (and
[async_date_timerfd](../async_date_timerfd/)) are indistinguishable from each
other and from a response with no `Date` at all; the win is a cheap hot path,
not more req/s.

## Tests

```sh
v test examples/date_header/src
```

[main_test.v](src/main_test.v) exercises the cache without a server or a
clock-dependent value: a refreshed line starts with `Date: `, ends with
` GMT\r\n` and is exactly 37 bytes; each `refresh` flips the active buffer;
the response the handler composes contains the status line, the Date line
and `Content-Length: 2`; and neither `respond` nor `refresh` allocates (a
`gc_heap_usage()` delta over 20k calls each).

## See also

- [examples/efficient_date](../efficient_date/) — per-worker cache, lazy refresh
- [examples/async_date_timerfd](../async_date_timerfd/) — per-worker cache
  refreshed by a timerfd on each worker's own event loop
- [BEST_PRACTICES §3 — the `Date` header worked example](../../docs/BEST_PRACTICES.md#3-avoid--interpolation-on-the-hot-path)
