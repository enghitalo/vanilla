# compression — `Accept-Encoding` negotiation over precompressed responses

The body here is static, so it is compressed once, at startup, with each
encoder (brotli, zstd, gzip), and each result is framed into a complete
response. Per request the handler only reads `Accept-Encoding`, picks one of
four prebuilt responses and appends it: no compression and no formatting on
the hot path. Every variant carries `Vary: Accept-Encoding` so caches keep
them apart.

The same idea serves files from disk: the
[static_assets](../../static_assets/) module sends precompressed `.br`/`.gz`
siblings.

## Run

```sh
v -prod run examples/compression/src
```

It listens on `:3000` (fixed in [main.v](src/main.v)). gzip (pure V) and zstd
(vendored C) are always available. brotli `dlopen`s the system
`libbrotlienc`/`libbrotlidec` (`libbrotli1` on Debian/Ubuntu, `brotli` on
Arch); without
them the brotli response is never built, the server prints a note at startup
and a client asking for `br` gets zstd or gzip instead.

Without `Accept-Encoding` the body goes out as is:

```sh
curl -i localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 464
Vary: Accept-Encoding
Connection: keep-alive

{"message":"this body is large enough to be worth compressing","items":[1,2,3,4,5,6,7,8,9,10],"note":"repeated text compresses well …"}
```

`curl --compressed` offers every encoding it supports and decodes the
reply; with libbrotli installed the server picks `br`:

```sh
curl -s --compressed -D - -o /dev/null localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 107
Vary: Accept-Encoding
Content-Encoding: br
Connection: keep-alive

```

Asking for one encoding at a time (headers trimmed):

```sh
curl -s -H 'Accept-Encoding: zstd, gzip' -D - -o /dev/null localhost:3000/
curl -s -H 'Accept-Encoding: gzip' localhost:3000/ | gzip -d
```

| `Accept-Encoding` | `Content-Encoding` | `Content-Length` |
|---|---|---|
| (none) | (none) | 464 |
| `br, gzip` | `br` | 107 |
| `zstd, gzip` | `zstd` | 127 |
| `gzip` or `GZIP` | `gzip` | 147 |
| `pack200-gzip` | (none) | 464 |

## How it works

- **Four `const` responses.** `resp_identity`, `resp_gzip`, `resp_zstd` and
  `resp_br` are built by `make_response` when the module's consts are
  initialized: brotli at quality 11, zstd at level 19, since ratio matters
  and latency does not at startup. `make_response` uses a `strings.Builder`
  and `${}`, which is fine because it never runs per request. A failed brotli
  `compress` (no library) leaves `resp_br` empty, and the handler passes
  `resp_br.len > 0` as `brotli_ok`.
- **Negotiation by offsets.** `get_header_value_slice('Accept-Encoding')`
  gives a `Slice`, and `pick_encoding` scans those bytes in the request buffer
  (`br` > `zstd` > `gzip` > identity) without slicing or copying
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **Whole tokens only.** `has_token` matches case-insensitively (`| 0x20`,
  so needles must be lowercase letters) and requires a delimiter (`,`, `;`,
  space, tab or the value's edge) on both sides, so `pack200-gzip`, a
  different registered coding, does not match `gzip`.
- **One append.** The handler appends the chosen response with `out << resp_*`
  ([BEST_PRACTICES §1](../../docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc)).
  The four responses are `[]u8` consts because they are built from
  compressor output at init, not string literals.
- **What the scan does not do.** It reads no q-values, so `gzip;q=0` (which
  forbids gzip) still gets gzip. `*` and the legacy `x-gzip` alias get
  identity. A production negotiator parses q-values; this one shows the
  selection shape.
- **Dynamic bodies.** When the body cannot be precompressed, gzip or zstd per
  response works, but `brotli.compress` opens and closes the library on every
  call: keep it off the hot path. Skip tiny bodies and already-compressed
  types, and if an encoder fails send identity without `Content-Encoding`.

## Tests

```sh
v test examples/compression/src
```

[main_test.v](src/main_test.v) covers `pick_encoding` (preference order, case
folding, `;` as a delimiter, whole tokens vs `pack200-gzip`, the no-brotli
fallback) and `has_token` staying inside its offset window. Each prebuilt
response is split and its body decompressed back to `demo_body` with
matching `Content-Length` and `Vary` (the brotli round trip is skipped
without libbrotli). Raw requests through `handle` return the expected
response, and malformed or truncated ones the canned 400 with `.close`.

## See also

- [static_assets](../../static_assets/) — precompressed sibling files served from disk
- [examples/static_files](../static_files/), [examples/spa_static_assets](../spa_static_assets/) — that module in use
- [BEST_PRACTICES §3 — the content negotiation worked example](../../docs/BEST_PRACTICES.md#3-avoid--interpolation-on-the-hot-path)
- [BEST_PRACTICES §3a — static responses as `const`s](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)
