# compression — `Accept-Encoding` negotiation over precompressed responses

The body here is static, so it is compressed once, at startup, with each
encoder (brotli, zstd, gzip), and each result is framed into a complete
response. Per request the handler only reads `Accept-Encoding`, picks one of
four prebuilt responses (or a canned `406`) and appends it: no compression and
no formatting on the hot path. Every variant carries `Vary: Accept-Encoding`
so caches keep them apart.

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
Arch); without them the brotli response is never built, the server prints a
note at startup and `br` drops out of the negotiation: a client that also
accepts zstd or gzip gets one of those.

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

Weights count: `gzip;q=0` refuses gzip, so this client gets the body as is:

```sh
curl -s -H 'Accept-Encoding: gzip;q=0' -D - -o /dev/null localhost:3000/
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 464
Vary: Accept-Encoding
Connection: keep-alive

```

A client that refuses identity too, and accepts nothing the server has, gets
`406 Not Acceptable`. The connection stays open:

```sh
curl -i -H 'Accept-Encoding: identity;q=0' localhost:3000/
```

```
HTTP/1.1 406 Not Acceptable
Content-Length: 0
Vary: Accept-Encoding
Connection: keep-alive

```

More values (headers trimmed):

```sh
curl -s -H 'Accept-Encoding: zstd, gzip' -D - -o /dev/null localhost:3000/
curl -s -H 'Accept-Encoding: gzip' localhost:3000/ | gzip -d
```

| `Accept-Encoding` | Status | `Content-Encoding` | `Content-Length` |
|---|---|---|---|
| (none) | 200 | (none) | 464 |
| `br, gzip` | 200 | `br` | 107 |
| `zstd, gzip` | 200 | `zstd` | 127 |
| `gzip` or `GZIP` | 200 | `gzip` | 147 |
| `x-gzip` | 200 | `gzip` | 147 |
| `br;q=0.5, gzip` | 200 | `gzip` | 147 |
| `gzip;q=0.8, zstd;q=0.9` | 200 | `zstd` | 127 |
| `*` | 200 | `br` | 107 |
| `gzip, gzip;q=0` | 200 | (none) | 464 |
| `gzip;q=2` | 200 | (none) | 464 |
| `pack200-gzip` | 200 | (none) | 464 |
| `identity;q=0, gzip` | 200 | `gzip` | 147 |
| `*;q=0, identity` | 200 | (none) | 464 |
| `*;q=0` | 406 | (none) | 0 |

`gzip;q=2` is not a valid weight, so that element is ignored and gzip counts
as not listed.

## How it works

- **Four `const` responses.** `resp_identity`, `resp_gzip`, `resp_zstd` and
  `resp_br` are built by `make_response` when the module's consts are
  initialized: brotli at quality 11, zstd at level 19, since ratio matters
  and latency does not at startup. `make_response` uses a `strings.Builder`
  and `${}`, which is fine because it never runs per request. A failed brotli
  `compress` (no library) leaves `resp_br` empty, and the handler passes
  `resp_br.len > 0` as `brotli_ok`. The 406, `resp_406`, is a `const` string.
- **One pass by offsets.** `get_header_value_slice('Accept-Encoding')` gives
  a `Slice`, and `pick_encoding` walks those bytes in the request buffer once,
  element by element, without slicing or copying
  ([BEST_PRACTICES §2](../../docs/BEST_PRACTICES.md#2-stay-zero-copy-work-with-slices-not-copies)).
- **Each element.** The coding is a whole token compared case-insensitively
  with a real ASCII lowercase, so `pack200-gzip`, a different registered
  coding, is not gzip, while `x-gzip` is (RFC 9110 §8.4.1.3). Parameters
  follow, each after a `;` with optional whitespace around it. The weight is
  the `q` parameter (`q` or `Q`, no whitespace around its `=`) holding a
  qvalue, `0[.ddd]` or `1[.000]` (RFC 9110 §12.4.2), kept in thousandths;
  without one it is 1000. Other parameters are skipped. An element whose
  qvalue does not parse (`q=2`, `q=0.1234`, `q=`, `q = 0`), or with anything
  but `;` after its coding, is ignored.
- **Repeats keep the lowest q.** `gzip, gzip;q=0` and `gzip, x-gzip;q=0`
  both refuse gzip: a refusal anywhere wins.
- **The choice.** Each coding the server has takes its own q, else the q of
  `*` when `*` is listed, else 0. The highest q above 0 wins, and a tie goes
  to `br`, then `zstd`, then `gzip` (`br` only with libbrotli). When none
  qualifies the body goes out as is, unless the client refused identity, with
  `identity;q=0` or with `*;q=0` and no identity entry (RFC 9110 §12.5.3):
  then it gets the 406. A missing or empty `Accept-Encoding` gets identity.
- **First field line only.** `get_header_value_slice` returns the first
  `Accept-Encoding` line, so the elements of a second one are not merged in.
- **One append.** The handler appends the chosen response with `out << resp_*`
  ([BEST_PRACTICES §1](../../docs/BEST_PRACTICES.md#1-handlers-append-into-the-connections-write-buffer-zero-alloc)),
  or the 406 with `core.append_str`. The four responses are `[]u8` consts
  because they are built from compressor output at init, not string literals.
- **Dynamic bodies.** When the body cannot be precompressed, gzip or zstd per
  response works, but `brotli.compress` opens and closes the library on every
  call: keep it off the hot path. Skip tiny bodies and already-compressed
  types, and if an encoder fails send identity without `Content-Encoding`.

## Tests

```sh
v test examples/compression/src
```

[main_test.v](src/main_test.v) covers `pick_encoding`: preference order,
`q=0` refusals, the highest q winning and ties going to server order, `*` and
`*;q=0` with and without an identity entry, `identity;q=0` alone and next to
a usable coding, `x-gzip`, case folding, invalid qvalues and `q = 0`
ignored, whitespace around `;`, whole tokens vs `pack200-gzip`, repeats
keeping the lowest q, other parameters skipped, both libbrotli branches, and
the parse staying inside its offset window. `qvalue` is checked against the
RFC grammar. Each prebuilt response is split and its body decompressed back
to `demo_body` with matching `Content-Length` and `Vary` (the brotli round
trip is skipped without libbrotli), and the 406's headers are checked. Raw
requests through `handle` return the expected response with `.done`,
malformed or truncated ones the canned 400 with `.close`, and 20,000 rounds
of well-formed requests covering every outcome allocate nothing.

## See also

- [static_assets](../../static_assets/) — precompressed sibling files served from disk
- [examples/static_files](../static_files/), [examples/spa_static_assets](../spa_static_assets/) — that module in use
- [BEST_PRACTICES §3 — the content negotiation worked example](../../docs/BEST_PRACTICES.md#3-avoid--interpolation-on-the-hot-path)
- [BEST_PRACTICES §3a — static responses as `const`s](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)
