module main

// Static, self-delimiting responses used by the conformance handler.
//
// Every response carries an explicit framing header (Content-Length) so it is
// self-delimiting per RFC 9110 §6.3 — including the error responses, which the
// h1spec "Error response is self-delimiting" check requires. Error responses
// also send `Connection: close`: after a malformed request the parser can no
// longer trust the byte stream, so closing is the safe RFC 9112 §9.6 behavior.
//
// Byte discipline (docs/BEST_PRACTICES.md): these are `const ... .bytes()`
// blobs appended with `out <<` — no `+`, no `${}`, no allocation on the hot path.

const resp_200_ok = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\nok\n'.bytes()

const resp_200_ok_close = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n'.bytes()

// HEAD: identical headers to GET / but with no message body (RFC 9110 §9.3.2).
const resp_200_head = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: keep-alive\r\n\r\n'.bytes()

const resp_400_bad_request = 'HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 12\r\nConnection: close\r\n\r\nbad request\n'.bytes()

const resp_404_not_found = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 10\r\nConnection: keep-alive\r\n\r\nnot found\n'.bytes()

const resp_405_method_not_allowed = 'HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\nContent-Length: 19\r\nAllow: GET, HEAD, POST\r\nConnection: keep-alive\r\n\r\nmethod not allowed\n'.bytes()

const resp_501_not_implemented = 'HTTP/1.1 501 Not Implemented\r\nContent-Type: text/plain\r\nContent-Length: 16\r\nConnection: close\r\n\r\nnot implemented\n'.bytes()

const resp_505_version_not_supported = 'HTTP/1.1 505 HTTP Version Not Supported\r\nContent-Type: text/plain\r\nContent-Length: 20\r\nConnection: close\r\n\r\nversion unsupported\n'.bytes()
