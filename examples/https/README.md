# https — an HTTPS server

The same kind of handler as any plain-HTTP example, served over TLS 1.3. TLS
lives in the server's epoll worker: it runs the handshake, encrypts and
decrypts records, and hands record crypto to the kernel (kTLS) when the host
can. The handler never sees any of it, so turning a plain server into an HTTPS
one is a single `ServerConfig` field, `tls_config`.

## Run

TLS is opt-in at build time: it needs Mbed TLS 4 and the `-d vanilla_tls`
flag. Linux only: `new_server` refuses `tls_config` on any backend but epoll.

```sh
v -d vanilla_tls run examples/https/src
```

It listens on `:8443` ([main.v](src/main.v)), IPv4. On the first run it
issues a self-signed certificate for `localhost`, `127.0.0.1` and `::1` and
writes it to `certs/` in the working directory (`cert.pem`, and `key.pem` with
mode 0600). Later runs load that identity again, so a client that trusts
`certs/cert.pem` keeps working across restarts:

```sh
curl -i --cacert certs/cert.pem https://localhost:8443/
```

```
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 13
Connection: keep-alive

Hello, HTTPS!
```

`curl -I` gets the same headers and no body. Any other method on `/` gets a
405 with `Allow: GET, HEAD`, and any other path a 404:

```sh
curl -i --cacert certs/cert.pem -X POST https://localhost:8443/
```

```
HTTP/1.1 405 Method Not Allowed
Allow: GET, HEAD
Content-Length: 0
Connection: keep-alive
```

Without `--cacert`, curl refuses the certificate (`self-signed certificate`,
exit 60): the identity is real, just not signed by a CA it knows. A plaintext
request to the port gets no HTTP answer: the server reads it as a broken
ClientHello and closes the connection (`curl http://localhost:8443/` reports a
reset).

Built without `-d vanilla_tls`, the program stops at startup:

```
https: vtls: built without TLS support — rebuild with `-d vanilla_tls` (and install Mbed TLS 4)
```

### A CA-issued certificate

Set `HTTPS_CERT` and `HTTPS_KEY` to PEM files (a certificate chain and its
key, for example from Let's Encrypt) and `load_tls` loads them with
`tls.new_from_pem` instead of issuing one:

```sh
HTTPS_CERT=/etc/letsencrypt/live/example.com/fullchain.pem \
HTTPS_KEY=/etc/letsencrypt/live/example.com/privkey.pem \
v -d vanilla_tls -prod run examples/https/src
```

Setting only one of them is an error, not a fallback to a self-signed
certificate. For a self-signed certificate valid for a real host, pass its
names to `tls.new_self_signed(sans: ['DNS:example.com', 'IP:203.0.113.5'])`
in `load_tls`, and delete `certs/` first: while its files exist they are
loaded, and `sans` is ignored.

## How it works

- **The handler is plain HTTP.** `route` reads the method and path from the
  request line (`http1_1/router`) and appends a `const` response with
  `core.append_str`: no allocation per request
  ([BEST_PRACTICES §3a](../../docs/BEST_PRACTICES.md#3a-static-responses--a-const-string-appended-with-coreappend_str)).
  It is called with decrypted bytes and its output is encrypted after it
  returns, so the same function would serve plain HTTP unchanged.
- **One field makes it HTTPS.** `tls_config: cfg` in `ServerConfig`, where
  `cfg` comes from `tls.new_self_signed` or `tls.new_from_pem`. Leave
  `io_multiplexing` unset: the Linux default, epoll, is the backend that
  serves TLS.
- **The handshake has a deadline.** A connection's first read deadline starts
  at accept, so `read_timeout_ms` also bounds the handshake: a client that
  connects and never finishes it is closed silently after 10 s. Without a read
  timeout the idle timeout does the same. Set one of them on any public HTTPS
  server ([server/README.md](../../server/README.md#tls)).
- **kTLS when the host has it.** After the handshake the server moves record
  encryption into the kernel if the `tls` module is loaded (`modprobe tls`),
  and then `sendfile(2)` can stream file bodies without a userspace copy (see
  `static_assets`). Otherwise records stay in Mbed TLS, and the server logs
  the fallback once.
- **Parallel crypto needs the right Mbed TLS build.** Without
  `MBEDTLS_THREADING_C` (the upstream default, and distro packages such as
  Arch's) the workers take turns in the crypto library, and the server says
  so at startup.
  [server/README.md](../../server/README.md#tls) shows how to build it with
  threading.

## Tests

```sh
v test examples/https/src
v -d vanilla_tls test examples/https/src
```

[main_test.v](src/main_test.v) calls `route` directly and runs in any build:
the exact bytes of the 200, HEAD and 404 answers, the 405's status line and
`Allow`, appending after an earlier response, no allocation over 20k
requests, and `load_tls` refusing a certificate without its key.
[https_e2e_test.v](src/https_e2e_test.v) needs `-d vanilla_tls` on Linux and
serves the example over TLS to a client that verifies the certificate
against `cert.pem`, as `curl --cacert` does. It covers `localhost` and
`127.0.0.1`, keep-alive, a restart that keeps the identity, the
`HTTPS_CERT`/`HTTPS_KEY` path, and a plaintext request that is closed at once
with no HTTP answer.

## See also

- [server/README.md — TLS](../../server/README.md#tls): what the TLS worker
  does, kTLS and the threading build
- [examples/https_upstream](../https_upstream/): the client side, calling an
  HTTPS API from a handler
