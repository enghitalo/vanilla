/*
 * vanilla_tls — a thin C adapter over Mbed TLS 4 (TLS 1.3): the HTTPS server,
 * and the client side of pg_async's TLS (vtls_client_setup).
 *
 * Why a C shim (not direct V bindings): Mbed TLS exposes its config via macros
 * with arguments (PSA_ALG_ECDSA(...), PSA_KEY_TYPE_ECC_KEY_PAIR(...)) and a dozen
 * opaque structs; wrapping the few operations we need in C is far cleaner than
 * binding all of that from V. V binds the handful of functions below.
 *
 * The self-signed certificate generation is ported from the project's reference
 * (concept-examples/TLS/server.c).
 */
#ifndef VANILLA_TLS_H
#define VANILLA_TLS_H

#include <stddef.h>

typedef struct vtls_ctx vtls_ctx; // a TLS config: the server's (cert + key) or a client's (trusted CAs)

// Process-wide one-time init (psa_crypto_init). Returns 0 on success.
int vtls_global_init(void);

// 1 if the linked Mbed TLS was built with MBEDTLS_THREADING_C (it locks PSA's
// process-wide state itself, so TLS workers run their crypto in parallel); 0
// if not, in which case every entry point here takes one process-wide lock and
// the workers take turns in the crypto library. Either way the functions are
// safe to call from several threads, on distinct sessions.
int vtls_parallel_crypto(void);

// Create/destroy a server TLS context.
vtls_ctx *vtls_ctx_new(void);
void vtls_ctx_free(vtls_ctx *ctx);

// Populate the context with a freshly generated self-signed certificate +
// key (EC P-256, TLS 1.3). `sans` are 1..16 "DNS:<host>" / "IP:<v4|v6>" entries
// the certificate will be valid for (clients validate against these, not the
// CN). `char *const *` rather than `const char *const *` only because V emits
// `char**` for `&&char` and gcc rejects the double-const conversion; the
// strings are never modified. Returns 0 on success, non-zero on a bad entry or
// generation failure.
int vtls_use_self_signed(vtls_ctx *ctx, char *const *sans, size_t nsans);

// Populate the context from PEM cert + key buffers. Returns 0 on success.
int vtls_use_pem(vtls_ctx *ctx, const unsigned char *cert, size_t clen,
                 const unsigned char *key, size_t klen);

// Finalize the SSL config (defaults, TLS 1.3, own cert). Call after use_*.
int vtls_setup(vtls_ctx *ctx);

// Configure the ALPN protocol list from a comma-separated string, in preference
// order (e.g. "http/1.1" or "h2,http/1.1"). Returns 0 on success. Call after
// vtls_setup, before creating sessions. Only advertise protocols you can serve.
int vtls_set_alpn(vtls_ctx *ctx, const char *list);

// The generated/loaded certificate as PEM (NUL-terminated), or NULL. Useful to
// save so a client can trust it (curl --cacert). Valid until vtls_ctx_free.
const char *vtls_cert_pem(vtls_ctx *ctx);

// The private key as PEM (NUL-terminated), or NULL. Set by vtls_use_self_signed
// (exported from the generated key) and by vtls_use_pem (a copy of the input,
// when it fits). Lets the caller persist the pair and reload it with
// vtls_use_pem, so the identity survives restarts. Valid until vtls_ctx_free.
const char *vtls_key_pem(vtls_ctx *ctx);

// The protocol negotiated via ALPN (e.g. "http/1.1"), or NULL if none. Valid
// only once the handshake on this session has completed.
const char *vtls_get_alpn(void *sess);

// ---- per-connection session (driven by the non-blocking epoll loop) --------

// Create a session bound to an already-accepted, non-blocking fd. NULL on error.
void *vtls_session_new(vtls_ctx *ctx, int fd);
void vtls_session_free(void *sess);

// Return codes. read/write return byte counts >= 0 on success, so the "blocked"
// and "error" signals are NEGATIVE to never collide with a 1-byte read.
//
// WANT_READ vs WANT_WRITE are distinct so the epoll worker knows which readiness
// to wait for: WANT_READ → arm EPOLLIN (the default), WANT_WRITE → arm EPOLLOUT
// (the socket send buffer is full; resume the same operation when it drains).
#define VTLS_OK 0          // handshake done
#define VTLS_WANT (-2)     // would block on READ — retry on the next EPOLLIN
#define VTLS_WANT_WRITE (-3) // would block on WRITE — retry on the next EPOLLOUT
#define VTLS_ERROR -1      // fatal — close the connection

// Drive the TLS handshake. VTLS_OK when complete, VTLS_WANT to retry, VTLS_ERROR.
int vtls_handshake(void *sess);

// Like recv/send but over TLS. read returns >=0 bytes, or VTLS_WANT / VTLS_ERROR.
// Reads stop at a drained socket without a syscall (see vtls_mark_readable).
int vtls_read(void *sess, unsigned char *buf, size_t len);
int vtls_write(void *sess, const unsigned char *buf, size_t len);

// Tell the session its socket may hold new bytes: call on every readable edge
// (and when resuming reads), before vtls_handshake/vtls_read. Once a recv came
// back short or EAGAIN, the session answers VTLS_WANT from its own state until
// this is called again. That is the edge-triggered contract: a drained socket
// raises a new edge for any byte that arrives later.
void vtls_mark_readable(void *sess);

// Read the TLS stream (handshake, read, write) the way the edge-triggered
// workers need it: a "want" result means the socket really is drained (or
// full), never that Mbed TLS stopped early with records still buffered — a
// TLS 1.3 NewSessionTicket (MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET on a
// client) or a skipped warning alert is read past, not reported.

// 1 once the peer ended the TLS session (EOF, or a close_notify alert): a
// VTLS_ERROR from vtls_read is then a clean close, not a failure.
int vtls_peer_closed(void *sess);

// 1 if the peer ended the session with a close_notify alert; 0 for a bare
// transport EOF (or no close at all). A body delimited by the close is
// complete only after a close_notify (RFC 9112 §9.8).
int vtls_peer_close_notify(void *sess);

// ---- client (pg_async's TLS; the server side never calls these) -----------

// How a client checks the server's certificate.
#define VTLS_VERIFY_NONE 0 // not at all: encrypted, but the server is not authenticated
#define VTLS_VERIFY_CA 1   // the certificate chains to a trusted CA
#define VTLS_VERIFY_FULL 2 // ...and names the host dialed (a DNS or IP SAN)

// Configure ctx (from vtls_ctx_new) as a TLS 1.3 client that accepts the
// suites the server offers and verifies its certificate per `verify` against
// the PEM bundle at ca_file (unused for VTLS_VERIFY_NONE). Returns 0, or a
// negative Mbed TLS error (vtls_error_string): the file unreadable, or not one
// certificate in it parsed.
int vtls_client_setup(vtls_ctx *ctx, const char *ca_file, int verify);

// A client session on a connected, NON-BLOCKING socket, for server `host`. A
// DNS name is the SNI and, under VTLS_VERIFY_FULL, the name the certificate
// must carry. An IP address, in any spelling getaddrinfo reads as one
// (10.0.0.5, ::1, 127.1, fe80::1%eth0), is never sent as SNI (RFC 6066 §3);
// under VTLS_VERIFY_FULL it must equal one of the certificate's iPAddress
// SANs (RFC 9525 §6.2: not a dNSName, a wildcard or the CN). Non-blocking
// because Mbed TLS must never wait in a recv holding the crypto lock (see
// VTLS_LOCK in vanilla_tls.c). NULL on error.
void *vtls_client_session_new(vtls_ctx *ctx, int fd, const char *host);

// Re-arm a client session for a fresh handshake to the same host on a new
// socket (a re-dial), keeping its buffers. fd -1 detaches it from a socket
// that is being closed, so nothing (vtls_session_free's close_notify) writes
// to the fd number after it is reused. Returns 0, or a negative Mbed TLS error.
int vtls_session_reset(void *sess, int fd);

// After vtls_handshake returned VTLS_ERROR: why, NUL-terminated in buf (the
// certificate verification failure, or the Mbed TLS error).
void vtls_handshake_error(void *sess, char *buf, size_t len);

// After vtls_handshake returned VTLS_ERROR: 1 if the server's certificate
// failed verification (untrusted chain, wrong name, expired), 0 for any other
// failure. Allocation-free, unlike vtls_handshake_error.
int vtls_verify_failed(void *sess);

// The text of a negative Mbed TLS error code, NUL-terminated in buf.
void vtls_error_string(int err, char *buf, size_t len);

// ---- kTLS: kernel record-crypto offload ------------------------------------

// After vtls_handshake() returns VTLS_OK, try to hand record encrypt/decrypt to the
// kernel (TLS_TX + TLS_RX). Returns 1 if kTLS engaged — thereafter the caller does
// PLAIN recv()/send() on the fd and the kernel does AES-128-GCM. Returns 0 to keep
// using vtls_read/vtls_write (userspace mbedtls) — a safe fallback when the host
// lacks the tls ULP. If it returns 0 AND vtls_ktls_failed() is 1, the socket is
// half-converted and the caller MUST close the connection.
int vtls_enable_ktls(void *sess, int fd);
int vtls_ktls_active(void *sess);
int vtls_ktls_failed(void *sess);

// On a kTLS session, send a fatal internal_error alert (best effort) before the
// caller closes mid-response: the kernel first pushes the data record a
// MSG_MORE send left open, so the bytes already in it are not lost. No-op on
// a userspace session.
void vtls_ktls_abort(void *sess);

// Allow (1, the default) or forbid (0) kTLS for sessions created from now on.
// Each session copies the setting at vtls_session_new; with 0 its
// vtls_enable_ktls returns 0 (the clean userspace fallback, logged once).
void vtls_set_ktls(vtls_ctx *ctx, int enabled);

// Opt in (enabled = 1) to TLS_RX_EXPECT_NO_PAD on the kTLS sessions of this
// context: the kernel then decrypts each record straight into the recv()
// buffer, saving a page allocation and a copy per record. Off by default.
// Kernels before commit 1c8629651cb5 (fixed in v7.2, v7.1.9+, v6.18.45+)
// mishandle a padded or non-data record in this mode: recvmsg() writes past
// the length it returns, corrupting the received data. Peers do not pad by
// default, but TLS 1.3 allows it (OpenSSL's RecordPadding), so enable it on a
// fixed kernel, or when the peers are known not to pad. Kernels before 6.0
// reject the option: kTLS then runs without it. Each session copies the
// setting when created, so call it before the server starts.
void vtls_set_ktls_rx_no_pad(vtls_ctx *ctx, int enabled);

#endif /* VANILLA_TLS_H */
