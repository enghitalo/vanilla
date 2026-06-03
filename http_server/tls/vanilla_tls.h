/*
 * vanilla_tls — a thin C adapter over Mbed TLS 4 (TLS 1.3).
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

typedef struct vtls_ctx vtls_ctx; // server-wide TLS config (cert + key + ssl conf)

// Process-wide one-time init (psa_crypto_init). Returns 0 on success.
int vtls_global_init(void);

// Create/destroy a server TLS context.
vtls_ctx *vtls_ctx_new(void);
void vtls_ctx_free(vtls_ctx *ctx);

// Populate the context with a freshly generated self-signed certificate +
// key (EC P-256, TLS 1.3). Returns 0 on success.
int vtls_use_self_signed(vtls_ctx *ctx);

// Populate the context from PEM cert + key buffers. Returns 0 on success.
int vtls_use_pem(vtls_ctx *ctx, const unsigned char *cert, size_t clen,
                 const unsigned char *key, size_t klen);

// Finalize the SSL config (defaults, TLS 1.3, own cert). Call after use_*.
int vtls_setup(vtls_ctx *ctx);

// The generated/loaded certificate as PEM (NUL-terminated), or NULL. Useful to
// save so a client can trust it (curl --cacert). Valid until vtls_ctx_free.
const char *vtls_cert_pem(vtls_ctx *ctx);

// ---- per-connection session (driven by the non-blocking epoll loop) --------

// Create a session bound to an already-accepted, non-blocking fd. NULL on error.
void *vtls_session_new(vtls_ctx *ctx, int fd);
void vtls_session_free(void *sess);

// Return codes. read/write return byte counts >= 0 on success, so the "blocked"
// and "error" signals are NEGATIVE to never collide with a 1-byte read.
#define VTLS_OK 0      // handshake done
#define VTLS_WANT (-2) // would block — retry on the next epoll readiness event
#define VTLS_ERROR -1  // fatal — close the connection

// Drive the TLS handshake. VTLS_OK when complete, VTLS_WANT to retry, VTLS_ERROR.
int vtls_handshake(void *sess);

// Like recv/send but over TLS. read returns >=0 bytes, or VTLS_WANT / VTLS_ERROR.
int vtls_read(void *sess, unsigned char *buf, size_t len);
int vtls_write(void *sess, const unsigned char *buf, size_t len);

#endif /* VANILLA_TLS_H */
