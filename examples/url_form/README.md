# url_form — percent-decode queries and form bodies, once

vanilla's request parser never percent-decodes: it hands the handler the raw
bytes off the wire, which is the right default for a zero-copy core. Most
apps still need decoded values, from two places that use the same encoding:

- the query string: `/search?q=hello%20world&tag=c%2B%2B`
- `application/x-www-form-urlencoded` request bodies (classic HTML form POSTs)

This example decodes both at the edge of the handler, explicitly and exactly
once, and echoes the result as JSON, escaping it, because a decoded value is
user input.

## Run

```sh
v -prod run examples/url_form/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). Every path answers
with the decoded pairs as a JSON object.

```sh
curl -i 'localhost:3000/search?q=hello%20world&tag=c%2B%2B'
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 31

{"q":"hello world","tag":"c++"}
```

A form POST (`curl -d` sends `application/x-www-form-urlencoded`):

```sh
curl -i localhost:3000/login -d 'user=ana+maria&note=50%25+off'
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 37

{"user":"ana maria","note":"50% off"}
```

Decoded input is escaped on the way out, and decoded only once:

```sh
curl -s localhost:3000/submit --data-urlencode 'msg=say "hi" & bye'
```

```
{"msg":"say \"hi\" & bye"}
```

`curl -s 'localhost:3000/x?q=%2527'` answers `{"q":"%27"}` (not `'`), and a
POST with another `Content-Type` (`-H 'Content-Type: application/json'`) is
not parsed as a form: `{}`.

## How it works

- **Inputs are views.** The handler finds the `?` by scanning the path bytes
  in place, and `view()` hands `parse_form` a `vbytes` window of the query or
  the body, never a copy. `parse_form` walks `key=value&...` by offsets: no
  `split`, no substrings. Empty pairs (`&&`) are skipped, a key without `=`
  maps to `""`, and a repeated key keeps its last value.
- **Outputs are owned, on purpose.** `percent_decode` turns `%XX` into a
  byte and `+` into a space, and returns a new `string`: decoded bytes differ
  from the wire bytes and become map entries. That copy per key and value
  (plus the map itself) is the allocation this example exists to show;
  everything around it reads the request in place
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **Decode once.** Decoding an already-decoded value is a classic filter
  bypass (`%2527` → `%27` → `'`). The result of the single pass is final.
  Malformed escapes (`100%`, `%zz`, `%2`) are kept as literal text.
- **Form bodies only when declared.** The body is parsed only for `POST`
  with a `Content-Type` starting with `application/x-www-form-urlencoded`,
  compared case-insensitively in place by `is_form_urlencoded`
  (a `; charset=...` suffix is fine). A form body replaces any query pairs.
  The core has already framed the body by `Content-Length` or chunked
  encoding, so `req.body` is complete.
- **Escape what you echo.** `write_json_escaped` escapes `"`, `\` and
  control bytes (`%0A` comes back as `\u000a`), so user input cannot break
  out of the JSON string
  ([BEST_PRACTICES §8](../../docs/BEST_PRACTICES.md#8-security-defaults)).
  Bytes ≥ 0x80 pass through as they are.
- **Framing.** The JSON body is built in one `strings.Builder` sized from the
  path and body lengths; the response is `resp_prefix` + `wi` (the length) +
  the builder's bytes, appended straight into `out`
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).

## Tests

```sh
v test examples/url_form/src
```

[main_test.v](src/main_test.v) table-tests `percent_decode` (escapes, `+`,
empty input, `%2527` decoded once, malformed escapes left literal) and
`parse_form`, then calls `handle` with raw requests: a decoded query, `+` as
space, an empty query, form bodies (including odd `Content-Type` casing and a
charset suffix), a JSON body left unparsed, an escaped `"` in the echo, and
the canned 400 on garbage.

## See also

- [examples/redirects](../redirects/) — a `?next=` value used as a redirect
  target, and why it needs checking
- [examples/request_limits](../request_limits/) — bounding the body this
  example parses
- [examples/json_api](../json_api/) — JSON request and response bodies
