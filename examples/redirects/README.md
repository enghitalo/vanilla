# redirects — pick the right 3xx, and don't open-redirect

A redirect is a status line and a `Location` header, but the status code
carries meaning, and the wrong one silently changes what clients do:

| Status | Permanent? | Method on follow | Use it for |
|---|---|---|---|
| `301 Moved Permanently` | yes, cacheable | may become GET | canonical URL moves |
| `302 Found` | no | may become GET | (prefer 303 or 307) |
| `303 See Other` | no | always GET | after a form POST (Post/Redirect/Get) |
| `307 Temporary Redirect` | no | kept, body too | temporary API moves |
| `308 Permanent Redirect` | yes | kept, body too | permanent API moves |

This example serves three of them (301, 303, 308) and shows the security half:
a redirect target taken from the request (`?next=...`) must be checked, or the
server becomes an open redirect that phishing links can bounce through.

## Run

```sh
v -prod run examples/redirects/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)).

`/old` moved for good (the query is ignored when routing, so `/old?utm=1`
redirects too):

```sh
curl -i localhost:3000/old
```

```
HTTP/1.1 301 Moved Permanently
Location: /new
Content-Length: 0
Connection: keep-alive

```

An API path moved with method and body preserved (`curl -L` re-sends the
POST to `/api/v2/resource`):

```sh
curl -i -X POST localhost:3000/api/v1/resource -d x=1
```

```
HTTP/1.1 308 Permanent Redirect
Location: /api/v2/resource
Content-Length: 0
Connection: keep-alive

```

Post/Redirect/Get: a login POST sends the browser to a GET page, taken from
`?next=` when it is a same-site path:

```sh
curl -i -X POST 'localhost:3000/login?next=/profile'
```

```
HTTP/1.1 303 See Other
Location: /profile
Content-Length: 0
Connection: keep-alive

```

An off-site target collapses to `/`:

```sh
curl -i -X POST 'localhost:3000/login?next=//evil.com'
```

```
HTTP/1.1 303 See Other
Location: /
Content-Length: 0
Connection: keep-alive

```

`next=https://evil.com` and an empty `next=` also get `Location: /`; a POST
with no `next` goes to `/dashboard`. `GET /login` (the form page) and every
other path answer an empty `200 OK`.

## How it works

- **Static redirects are consts.** `resp_301_old`, `resp_308_api` and
  `resp_200_empty` are whole responses, appended with `core.append_str`
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
- **Route without the query.** `req.path` includes the query string, so
  `route_len` finds the first `?` and the handler routes on a `Slice` of that
  length; `slice_eq` compares it against each literal in place.
- **The one dynamic response.** For `POST /login`, the 303's `Location` is
  `req.get_query_slice(next_key)` taken as a `vbytes` view of the request
  buffer, passed through `safe_next`, and appended between two literal
  `core.append_str` calls: no copy, no `${}`
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
  The fallback targets (`slash_bytes`, `dashboard_bytes`) are `const`
  byte arrays built once at startup.
- **The open-redirect guard.** `safe_next` accepts only a target that starts
  with `/` and not `//`; anything else becomes `/`. The query value is not
  percent-decoded, so `%2F%2Fevil.com` does not start with `/` and is
  rejected as well. It is a minimal guard and it has a known gap: it lets
  `/\evil.com` through, which browsers read as `//evil.com`. A real app
  should match `next` against an allowlist of its own paths
  ([BEST_PRACTICES §8](../../docs/BEST_PRACTICES.md#8-security-defaults)).
  Header injection through `next` is stopped one layer down: a request head
  with a bare LF is answered 400 by the server's framer before any handler
  runs.

## Tests

```sh
v test examples/redirects/src
```

[main_test.v](src/main_test.v) calls `handle` directly: `safe_next` on
relative, protocol-relative, absolute and empty targets; the 301 with and
without a query; the 308 on POST; the 303 with a good, off-site, empty and
missing `next`; `GET /login` and unknown paths as 200; and `.close` on a
malformed request.

## See also

- [examples/url_form](../url_form/) — parsing the form a login POST would carry
- [examples/csrf](../csrf/), [examples/cookies_sessions](../cookies_sessions/) —
  the rest of a login flow
- [BEST_PRACTICES §7 — follow the HTTP standards](../../docs/BEST_PRACTICES.md#7-follow-the-http-standards)
