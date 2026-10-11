# static_files — a static file server, done carefully

Serving files looks like `read + write`, but a correct static server needs four
things: a `Content-Type` from the file extension, byte **Range** requests (how
video and audio players seek), **conditional GET** (`ETag` / `If-None-Match`,
so a cached file costs a 304 instead of its bytes) and, above all,
**path-traversal safety**, so `GET /../../etc/passwd` never leaves the web root.

This example does all four in one readable handler that reads the file into
the connection's write buffer on every request, with no allocation. That keeps
the logic visible; for production serving with
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
`bytes 10-27/28`) ranges work too. An end past the file stops at its last
byte (RFC 9110 §14.1.2), and a suffix longer than the file (`-r -100`) takes
all of it:

```sh
curl -i -r 10-1000 localhost:3000/index.html
```

```
HTTP/1.1 206 Partial Content
Content-Type: text/html; charset=utf-8
Content-Range: bytes 10-27/28
Accept-Ranges: bytes
Content-Length: 18
ETag: "f4a79a6166757a19"

from vanilla</h1>
```

A range that selects no byte (a start at or past the end, `bytes=-0`, any
range on an empty file) gets a 416 carrying the file's length, on GET and
HEAD alike:

```sh
curl -i -r 500-600 localhost:3000/index.html
```

```
HTTP/1.1 416 Range Not Satisfiable
Content-Range: bytes */28
Content-Length: 0
Connection: keep-alive

```

A spec that is not one valid byte range is ignored, and the whole file comes
back as a 200 (RFC 9110 §14.2 lets a server ignore `Range`): several ranges
(`-r 0-1,5-6`), an end before its start (`-r 9-3`), anything malformed.

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

- **Traversal guard: resolve, then check containment.** The web root is
  resolved once, in `main`, with `realpath(3)`; `resolve` fails closed, so a
  root that does not resolve stops the server, unlike `os.real_path`, which
  returns its input unchanged. Per request, `safe_path` builds root + `/` +
  URL path + NUL in a per-worker buffer (`State`, from `make_state`) and
  `realpath(3)` resolves it into a second one, so `..` and symlinks are
  followed before the check. The candidate must be the root **plus a path
  separator**: a bare `starts_with` would let `./public2` pass for `./public`
  (#228). A path that does not resolve (missing file, symlink loop), ends in
  `/`, holds a NUL or is longer than `PATH_MAX` is refused, and so is anything `fstat`
  says is not a regular file. Every refusal is a 404, the same answer as a
  missing file.
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
- **The file goes straight into `out`.** The header block is appended first,
  with a 16-byte placeholder for the ETag, then `core.append_file_region`
  reads the whole file with `pread(2)` after it: no `os.read_bytes`, no copy.
  The ETag hashes those bytes and fills the placeholder. A 304 or a 416 rolls
  `out` back to where the response began (`out.len = mark`); a 206 moves its
  window down over the bytes before it (never `content[a..b]`); HEAD drops
  the body.
- **Range.** `parse_range` reads the header through a `vbytes` view of the
  request buffer (no substring, no `split`) and returns a `RangeSpec`:
  `.satisfiable` with the window, `.unsatisfiable` or `.ignore`, with no
  `error()` to box. It accepts a single range whose numbers are all digits:
  an end past the file is clamped to its last byte, and a number too long
  for an `i64` saturates instead of wrapping around. The 416 is decided after
  the `If-None-Match` check (RFC 9110 §14.2 evaluates `Range` after the
  preconditions), so a cached copy that is still current gets its 304, and
  the file is read and hashed for a 416 as for any other request.
- **Bytes in place, framing appended.** Method check (`slice_eq`) and query
  strip (`path_len_without_query`) work on request offsets, and every view is
  taken from the handler's `req_buffer` parameter. 404 and 405 are `const`
  strings appended with `core.append_str`; 200/206/304/416 are framed with
  `core.append_str` plus the local `wi` for integers
  ([BEST_PRACTICES §3b](../../docs/BEST_PRACTICES.md#3b-dynamic-responses--append-parts-straight-into-out)).
  A request allocates nothing (`test_serving_allocates_nothing`).
- HEAD gets the same headers as GET with no body (`is_get`).

## Tests

```sh
v test examples/static_files/src
```

[main_test.v](src/main_test.v) builds a throwaway `public/` + `public2/`
fixture in a temp dir (with symlinks pointing in and out of the root, a
directory, a FIFO and an empty file) and calls `handle` directly. It covers
`parse_range` (normal, suffix, open-ended, an end past the file, the
unsatisfiable and the ignored specs, numbers past `i64`), `mime_type`,
traversal (`..`, the `public2` sibling, an escaping symlink, unresolvable
paths and symlink loops, a NUL, an over-long path), and raw-request cases:
index, query strip, HEAD, 404 (also for the directory, the FIFO and a path
ending in `/`), 405, 206 (a window from the middle, an end past the file,
HEAD), 416 (GET and HEAD, the empty file), a 304 that wins over a 416, the
fallback to 200, the ETag → 304 round trip, a response already in `out` left
intact by a 304, a 206 and a 416, the canned 400 on garbage, and that serving
allocates nothing (a `gc_heap_usage()` delta over 20k rounds of requests).

## See also

- [examples/spa_static_assets](../spa_static_assets/) — the production path:
  the `static_assets` module with precomputed ETags and `sendfile(2)`
- [examples/etag](../etag/) — conditional GET on its own
- [examples/video_stream](../video_stream/) — Range requests feeding a video
  player
- [BEST_PRACTICES §8 — Security defaults](../../docs/BEST_PRACTICES.md#8-security-defaults)
- [BEST_PRACTICES §2 — stay zero-copy](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)
