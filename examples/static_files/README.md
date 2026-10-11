# static_files — a static file server, done carefully

Serving files looks like `read + write`, but a correct static server needs four
things: a `Content-Type` from the file extension, byte **Range** requests (how
video and audio players seek), **conditional GET** (`ETag` / `If-None-Match`,
so a cached file costs a 304 instead of its bytes) and, above all,
**path-traversal safety**, so `GET /../../etc/passwd` never leaves the web root.

This example does all four in one readable handler that reads the file into
memory per request. That keeps the logic visible; for production serving with
precomputed validators and `sendfile(2)` for large files, use the
[`static_assets`](../../static_assets/static_assets.v) module (see
[examples/spa_static_assets](../spa_static_assets/)).

## Run

The web root is `./public` **relative to the working directory** (`web_root`
in [main.v](src/main.v)), so run it from a folder that has one:

```sh
mkdir -p /tmp/site/public && cd /tmp/site
echo '<h1>hello from vanilla</h1>' > public/index.html
echo 'body { color: #333; }' > public/app.css
v -prod run /path/to/vanilla/examples/static_files/src
```

It listens on `:3000` (fixed in `main`). `/` serves `/index.html`; GET and HEAD
only.

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Content-Length: 28
Accept-Ranges: bytes
ETag: "f4a79a6166757a19"
Cache-Control: public, max-age=3600
Connection: keep-alive

<h1>hello from vanilla</h1>
```

`curl -i localhost:3000/app.css` answers `Content-Type: text/css`. The query
string is ignored (`/index.html?v=2` serves the same file).

**Range** — a byte window answers 206 with `Content-Range`:

```sh
curl -i -r 0-8 localhost:3000/index.html
```

```
HTTP/1.1 206 Partial Content
Content-Type: text/html; charset=utf-8
Content-Range: bytes 0-8/28
Accept-Ranges: bytes
Content-Length: 9
ETag: "f4a79a6166757a19"

<h1>hello
```

Suffix (`-r -7` → `bytes 21-27/28`) and open-ended (`-r 10-` →
`bytes 10-27/28`) ranges work too. A spec it cannot satisfy (multiple ranges,
start past end, or an end past the file such as `-r 10-1000`) is ignored and
the whole file comes back as a 200.

**ETag / 304** — send the `ETag` back and the body is not resent:

```sh
curl -i -H 'If-None-Match: "f4a79a6166757a19"' localhost:3000/index.html
```

```
HTTP/1.1 304 Not Modified
ETag: "f4a79a6166757a19"

```

**Path traversal** — `--path-as-is` stops curl from normalizing the `..` away,
so the raw request line reaches the server:

```sh
curl -i --path-as-is localhost:3000/../../../../etc/passwd
```

```
HTTP/1.1 404 Not Found
Content-Length: 0
Connection: keep-alive

```

A sibling folder sharing the root's name (`--path-as-is
localhost:3000/../public2/secret.txt`, with a `/tmp/site/public2/secret.txt`
present) and the percent-encoded form (`/%2e%2e/%2e%2e/etc/passwd`) get the
same 404. `curl -i -X POST localhost:3000/index.html` gets
`405 Method Not Allowed` with `Allow: GET, HEAD`.

## How it works

- **Traversal guard: resolve, then check containment.** `safe_path` joins the
  URL path under `web_root`, then `resolve`s both the root and the candidate
  with `realpath(3)`, so `..` and symlinks are followed before the check. The
  candidate must be the root **plus a path separator**: a bare `starts_with`
  would let `./public2` pass for `./public` (#228). `resolve` fails closed: a
  path that does not resolve (missing file, symlink loop) is refused, unlike
  `os.real_path`, which returns its input unchanged. Every refusal is a 404,
  the same answer as a missing file.
- **No percent-decoding.** The core hands the path over raw, so `%2e%2e` is
  never turned back into `..`; it is just a file name that does not exist.
- **MIME by extension, in place.** `mime_type` scans back to the last `.` of
  the basename and compares it against `mime_table` with `ext_eq` (guarded
  A–Z lowering, so `PIC.PNG` matches), returning a `const` string. Unknown
  extensions get `application/octet-stream`.
- **ETag.** A 64-bit wyhash of the file, hex-encoded by `hex16` into a stack
  array (no `.hex()` string). `etag_matches` compares the `If-None-Match`
  value in place against `"<16 hex>"`: an exact match only, no `W/` weak
  tags or lists. Hashing the whole file on every request is O(file size) on
  purpose here; `static_assets` precomputes it.
- **Range.** `parse_range` reads the header through a `vbytes` view of the
  request buffer (no substring, no `split`); the window is appended with
  `out.push_many(&content[start], len)`, never `content[a..b]`.
- **Bytes in place, framing appended.** Method check (`slice_eq`) and query
  strip (`path_len_without_query`) work on request offsets; the path reaches
  `safe_path` as a `tos` view. 404 and 405 are `const` strings appended with
  `core.append_str`; 200/206/304 are framed with `core.append_str` plus the
  local `wi` for integers
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
  The `os` path calls (`join_path`, `norm_path`, `realpath`) and
  `os.read_bytes` still allocate per request: this route is disk-bound and
  written for clarity, not as a zero-allocation path.
- HEAD gets the same headers as GET with no body (`is_get`).

## Tests

```sh
v test examples/static_files/src
```

[main_test.v](src/main_test.v) builds a throwaway `public/` + `public2/`
fixture in a temp dir (with symlinks pointing in and out of the root) and
calls `handle` directly. It covers `parse_range` (normal, suffix,
open-ended, rejected specs), `mime_type`, traversal (`..`, the `public2`
sibling, an escaping symlink, unresolvable paths and symlink loops), and
raw-request cases: index, query strip, HEAD, 404, 405, 206, fallback to 200,
the ETag → 304 round trip and the canned 400 on garbage.

## See also

- [examples/spa_static_assets](../spa_static_assets/) — the production path:
  the `static_assets` module with precomputed ETags and `sendfile(2)`
- [examples/etag](../etag/) — conditional GET on its own
- [examples/video_stream](../video_stream/) — Range requests feeding a video
  player
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
- [BEST_PRACTICES §2 — stay zero-copy](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)
