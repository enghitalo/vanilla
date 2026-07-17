# conformance

An HTTP/1.1 handler written to be **correct under a conformance probe** rather
than to show off a single feature. It rejects malformed requests with the status
codes RFC 9112 / RFC 9110 mandate, so tools like
[h1spec](https://github.com/dropseed/h1spec) and
[Http11Probe](https://github.com/MDA2AV/Http11Probe) score it as compliant.

Every other example assumes a well-formed request and gets on with the feature
it demonstrates. This one is the opposite: the handler's first job is to decide
whether the request is even acceptable.

## What it enforces

The handler calls the stdlib `request_parser.validate_http1()` and then the extra
checks in [`src/validate.v`](src/validate.v):

| Check | Spec | Status |
|---|---|---|
| Exactly one `Host` on HTTP/1.1 (reject missing / duplicate) | RFC 9112 §3.2 | 400 |
| `Host` value with internal whitespace | RFC 9112 §3.2 | 400 |
| Only `HTTP/1.0` / `HTTP/1.1` accepted | RFC 9112 §2.3 | 400 / 505 |
| `Content-Length` **and** `Transfer-Encoding` together | RFC 9112 §6.1 | 400 |
| Duplicate `Content-Length` field-lines | RFC 9112 §6.3 | 400 |
| Invalid `Content-Length` value (non-digit) | RFC 9112 §6.3 | 400 (framer) |
| Unknown transfer-coding / `chunked` not final | RFC 9112 §6.1, §7 | 501 / 400 |
| Field-name with a space or non-`tchar` byte | RFC 9110 §5.1, §5.6.2 | 400 |
| Whitespace before the `:` | RFC 9112 §5.1 | 400 |
| Obsolete line folding (leading SP/HTAB) | RFC 9112 §5.2 | 400 |
| Control byte / NUL in a field-value | RFC 9110 §5.5 | 400 |
| `HEAD` returns headers with no body | RFC 9110 §9.3.2 | 200, empty body |
| Unimplemented method | RFC 9110 §15.5.6 | 405 + `Allow` |
| Error responses are self-delimiting + `Connection: close` | RFC 9110 §6.3, RFC 9112 §9.6 | — |

Malformed requests reach the handler already framed by
`frame_request_length_lim`, which rejects the grossest framing errors (missing
CRLF, over-limit head → 431, over-limit body → 413, bad chunk-size, non-digit
`Content-Length`) *before* the handler runs. The handler covers everything that
needs the parsed header view.

## Run it

```sh
v -prod run examples/conformance/src
```

## Probe it

Point either conformance tool at the running server (plain HTTP on port 3000):

```sh
# h1spec (Python / uv) — fast RFC 9112/9110 gate
uvx --from git+https://github.com/dropseed/h1spec h1spec --strict localhost:3000

# Http11Probe (.NET 10) — deeper suite incl. request-smuggling scenarios
dotnet run --project src/Http11Probe.Cli -- --host localhost --port 3000
```

Both run in CI on every push/PR — see
[`.github/workflows/conformance_h1spec.yml`](../../.github/workflows/conformance_h1spec.yml)
and
[`.github/workflows/conformance_http11probe.yml`](../../.github/workflows/conformance_http11probe.yml).

## Known limitations (tracked as core-vanilla issues)

A handler can only decide a request the framer has already accepted as a complete
message, so a few conformance gaps live in the `server` core, not this example.
They are tracked as issues:

- **`Content-Length` + `Transfer-Encoding` sent together**
  ([#104](https://github.com/enghitalo/vanilla/issues/104)) is rejected only when
  the bytes happen to form a complete chunked frame. When they don't, the framer
  waits for more input instead of rejecting the ambiguous message up front. The
  fix is to reject CL+TE at the framing layer (`frame_request_length_lim_idx`).
- **Chunked body with a missing CRLF terminator**
  ([#109](https://github.com/enghitalo/vanilla/issues/109)) is accepted on the
  epoll backend (served `200` instead of `400`): `frame_chunked_total` assumes
  the post-data CRLF is present without checking it.

The **half-closed-client** bug that used to drop the response
([#103](https://github.com/enghitalo/vanilla/issues/103)) is **fixed** — a client
that `shutdown(SHUT_WR)`s after a complete request now receives its full reply on
both epoll and kqueue. The handler is still covered by `src/main_test.v` (the
same decisions asserted without a socket), so the deterministic gate stays
independent of backend I/O.

The unit tests in [`src/main_test.v`](src/main_test.v) assert every row of the
table above and always pass regardless of backend I/O behavior.
