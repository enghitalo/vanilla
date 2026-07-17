/*
 * vanilla_tls — thin C adapter over Mbed TLS 4 (TLS 1.3).
 * Cert generation ported from concept-examples/TLS/server.c.
 */
#include "vanilla_tls.h"

#include <mbedtls/ssl.h>
#include <mbedtls/ssl_ciphersuites.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/pem.h>
#include <psa/crypto.h>
#include <psa/crypto_values.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>  /* one-time kTLS engage/fallback log to stderr */
#include <errno.h>

/* kTLS: hand record crypto to the kernel after the userspace handshake. */
#include <linux/tls.h>
#include <netinet/tcp.h> /* TCP_ULP, SOL_TCP */
#include <sys/socket.h>  /* setsockopt, SOL_TLS (via bits/socket.h) */
#ifndef SOL_TLS
#define SOL_TLS 282
#endif

struct vtls_ctx {
    mbedtls_ssl_config conf;
    mbedtls_x509_crt srvcert;
    mbedtls_pk_context pkey;
    mbedtls_svc_key_id_t key_id;
    char cert_pem[4096];
    size_t cert_pem_len;
    // ALPN: mbedtls_ssl_conf_alpn_protocols stores the POINTER, so the backing
    // strings and the NULL-terminated pointer list must outlive the config —
    // hence they live here in the ctx, not on the stack.
    char alpn_buf[64];     // protocol names, NUL-separated in place
    const char *alpn[5];   // pointers into alpn_buf, NULL-terminated
};

// kTLS key capture: the TLS 1.3 application traffic secrets, filled by
// on_export_keys during the handshake. server secret => TX (we encrypt),
// client secret => RX (we decrypt). 32 bytes each for the SHA-256 suite.
typedef struct {
    unsigned char client_app_secret[32];
    unsigned char server_app_secret[32];
    int have_client;
    int have_server;
} vtls_keys;

typedef struct {
    mbedtls_ssl_context ssl;
    mbedtls_net_context net;
    vtls_keys keys;  // captured during the handshake, consumed by vtls_enable_ktls
    int ktls;        // 1 once kTLS TX+RX are both installed (reads/writes are plaintext)
    int ktls_failed; // 1 if a setsockopt failed AFTER the ULP attached → caller must close
} vtls_session;

// Pin the negotiated suite to exactly TLS_AES_128_GCM_SHA256 (0x1301) so the kTLS
// tls12_crypto_info_aes_gcm_128 layout always matches. mbedtls stores the POINTER
// (does not copy), so this needs static lifetime.
static const int ktls_ciphersuites[] = { MBEDTLS_TLS1_3_AES_128_GCM_SHA256, 0 };

// Capture the TLS 1.3 application traffic secrets during the handshake. p_expkey is
// &session->keys. The secret pointer is valid only for this call — copy it out.
// client/server randoms + prf type are TLS-1.2 concerns; ignored here.
static void on_export_keys(void *p_expkey, mbedtls_ssl_key_export_type type,
                           const unsigned char *secret, size_t secret_len,
                           const unsigned char client_random[32],
                           const unsigned char server_random[32],
                           mbedtls_tls_prf_types tls_prf_type) {
    (void)client_random;
    (void)server_random;
    (void)tls_prf_type;
    vtls_keys *k = (vtls_keys *)p_expkey;
    if (!k || secret_len != 32) return;
    if (type == MBEDTLS_SSL_KEY_EXPORT_TLS1_3_SERVER_APPLICATION_TRAFFIC_SECRET) {
        memcpy(k->server_app_secret, secret, 32);
        k->have_server = 1;
    } else if (type == MBEDTLS_SSL_KEY_EXPORT_TLS1_3_CLIENT_APPLICATION_TRAFFIC_SECRET) {
        memcpy(k->client_app_secret, secret, 32);
        k->have_client = 1;
    }
}

int vtls_global_init(void) {
    return (psa_crypto_init() == PSA_SUCCESS) ? 0 : -1;
}

vtls_ctx *vtls_ctx_new(void) {
    vtls_ctx *c = (vtls_ctx *)calloc(1, sizeof(vtls_ctx));
    if (!c) return NULL;
    mbedtls_ssl_config_init(&c->conf);
    mbedtls_x509_crt_init(&c->srvcert);
    mbedtls_pk_init(&c->pkey);
    return c;
}

void vtls_ctx_free(vtls_ctx *c) {
    if (!c) return;
    mbedtls_x509_crt_free(&c->srvcert);
    if (c->key_id != 0) psa_destroy_key(c->key_id);
    mbedtls_pk_free(&c->pkey);
    mbedtls_ssl_config_free(&c->conf);
    free(c);
}

// Generate an EC P-256 key (PSA) + a self-signed X.509v3 cert into the context.
int vtls_use_self_signed(vtls_ctx *c) {
    mbedtls_x509write_cert wc;
    unsigned char der[4096];
    int ret;

    mbedtls_x509write_crt_init(&wc);

    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(&attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    if (psa_generate_key(&attr, &c->key_id) != PSA_SUCCESS) { ret = -1; goto done; }
    if ((ret = mbedtls_pk_wrap_psa(&c->pkey, c->key_id)) != 0) goto done;

    mbedtls_x509write_crt_set_subject_key(&wc, &c->pkey);
    mbedtls_x509write_crt_set_issuer_key(&wc, &c->pkey);
    if ((ret = mbedtls_x509write_crt_set_subject_name(&wc, "CN=localhost,O=vanilla,C=US")) != 0) goto done;
    if ((ret = mbedtls_x509write_crt_set_issuer_name(&wc, "CN=localhost,O=vanilla,C=US")) != 0) goto done;
    mbedtls_x509write_crt_set_version(&wc, MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&wc, MBEDTLS_MD_SHA256);

    unsigned char serial[12];
    psa_generate_random(serial, sizeof(serial));
    if ((ret = mbedtls_x509write_crt_set_serial_raw(&wc, serial, sizeof(serial))) != 0) goto done;
    mbedtls_x509write_crt_set_validity(&wc, "20250101000000", "20351231235959");

    ret = mbedtls_x509write_crt_der(&wc, der, sizeof(der));
    if (ret < 0) goto done;
    size_t der_len = (size_t)ret;
    unsigned char *der_start = der + sizeof(der) - der_len;

    if ((ret = mbedtls_x509_crt_parse_der(&c->srvcert, der_start, der_len)) != 0) goto done;
    ret = mbedtls_pem_write_buffer("-----BEGIN CERTIFICATE-----\n", "-----END CERTIFICATE-----\n",
                                   der_start, der_len, (unsigned char *)c->cert_pem,
                                   sizeof(c->cert_pem), &c->cert_pem_len);
done:
    mbedtls_x509write_crt_free(&wc);
    return ret;
}

int vtls_use_pem(vtls_ctx *c, const unsigned char *cert, size_t clen,
                 const unsigned char *key, size_t klen) {
    int ret = mbedtls_x509_crt_parse(&c->srvcert, cert, clen);
    if (ret != 0) return ret;
    return mbedtls_pk_parse_key(&c->pkey, key, klen, NULL, 0); // Mbed TLS 4: no RNG args
}

int vtls_setup(vtls_ctx *c) {
    int ret = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_SERVER,
                                          MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) return ret;
    mbedtls_ssl_conf_min_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_3);
    mbedtls_ssl_conf_max_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_3);
    // Pin the single suite so the kTLS crypto_info layout always matches (0x1301).
    mbedtls_ssl_conf_ciphersuites(&c->conf, ktls_ciphersuites);
    // Disable TLS 1.3 NewSessionTicket. mbedtls defaults to sending 1 ticket right
    // after Finished, which encrypts under the server app key and advances the TX
    // record sequence to 1 before any app data — breaking the kTLS rec_seq=0 handoff.
    // Off => the first kernel-emitted application record is sequence 0.
#if defined(MBEDTLS_SSL_SESSION_TICKETS)
    mbedtls_ssl_conf_new_session_tickets(&c->conf, 0);
#endif
    return mbedtls_ssl_conf_own_cert(&c->conf, &c->srvcert, &c->pkey);
}

const char *vtls_cert_pem(vtls_ctx *c) {
    return (c && c->cert_pem_len > 0) ? c->cert_pem : NULL;
}

// Configure ALPN from a comma-separated list (e.g. "http/1.1" or "h2,http/1.1").
// The server offers these in order; mbedTLS picks the first the client also
// supports. The names are copied into the ctx (the config keeps the pointers).
int vtls_set_alpn(vtls_ctx *c, const char *list) {
    if (!c || !list) return -1;
    size_t n = strlen(list);
    if (n == 0 || n >= sizeof(c->alpn_buf)) return -1;
    memcpy(c->alpn_buf, list, n + 1); // include the NUL
    size_t count = 0;
    char *p = c->alpn_buf;
    c->alpn[count++] = p; // first token starts at the buffer
    for (size_t i = 0; i < n && count < (sizeof(c->alpn) / sizeof(c->alpn[0])) - 1; i++) {
        if (c->alpn_buf[i] == ',') {
            c->alpn_buf[i] = '\0';                 // terminate this token
            c->alpn[count++] = &c->alpn_buf[i + 1]; // next token
        }
    }
    c->alpn[count] = NULL; // NULL-terminate the list
    return mbedtls_ssl_conf_alpn_protocols(&c->conf, c->alpn);
}

// ---- per-connection session -------------------------------------------------

void *vtls_session_new(vtls_ctx *c, int fd) {
    vtls_session *s = (vtls_session *)calloc(1, sizeof(vtls_session));
    if (!s) return NULL;
    mbedtls_ssl_init(&s->ssl);
    if (mbedtls_ssl_setup(&s->ssl, &c->conf) != 0) { free(s); return NULL; }
    s->net.fd = fd; // already accepted + non-blocking
    mbedtls_ssl_set_bio(&s->ssl, &s->net, mbedtls_net_send, mbedtls_net_recv, NULL);
    // Capture the TLS 1.3 application traffic secrets for the kTLS handoff (per-ssl;
    // there is no config-level variant in Mbed TLS 4). s->keys is zeroed by calloc.
    mbedtls_ssl_set_export_keys_cb(&s->ssl, on_export_keys, &s->keys);
    return s;
}

void vtls_session_free(void *sess) {
    if (!sess) return;
    vtls_session *s = (vtls_session *)sess;
    // On a kTLS socket the kernel owns record framing; a userspace close_notify via
    // mbedtls would write a spurious, wrongly-framed record. Skip it (a missing
    // close_notify is tolerated by peers). For the plain userspace path, send it.
    if (!s->ktls) mbedtls_ssl_close_notify(&s->ssl);
    mbedtls_ssl_free(&s->ssl);
    free(s);
}

// Negotiated ALPN protocol (e.g. "http/1.1"), or NULL if none was agreed.
// Valid only after the handshake completes.
const char *vtls_get_alpn(void *sess) {
    return mbedtls_ssl_get_alpn_protocol(&((vtls_session *)sess)->ssl);
}

static int map_ret(int ret) {
    if (ret == MBEDTLS_ERR_SSL_WANT_READ) return VTLS_WANT;
    if (ret == MBEDTLS_ERR_SSL_WANT_WRITE) return VTLS_WANT_WRITE;
    return VTLS_ERROR;
}

int vtls_handshake(void *sess) {
    int ret = mbedtls_ssl_handshake(&((vtls_session *)sess)->ssl);
    return (ret == 0) ? VTLS_OK : map_ret(ret);
}

int vtls_read(void *sess, unsigned char *buf, size_t len) {
    int ret = mbedtls_ssl_read(&((vtls_session *)sess)->ssl, buf, len);
    if (ret > 0) return ret;
    if (ret == 0 || ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return VTLS_ERROR; // closed
    return map_ret(ret); // VTLS_WANT (-2) or VTLS_ERROR (-1)
}

int vtls_write(void *sess, const unsigned char *buf, size_t len) {
    int ret = mbedtls_ssl_write(&((vtls_session *)sess)->ssl, buf, len);
    if (ret >= 0) return ret;
    return map_ret(ret);
}

// ---- kTLS handoff -----------------------------------------------------------

// HKDF-Expand-Label (RFC 8446 §7.1) over a TLS 1.3 traffic secret (already a PRK):
// SHA-256, empty context. Driven by the PSA key-derivation API (no mbedtls/hkdf.h
// on the target). Returns 0 on success.
static int hkdf_expand_label(const unsigned char secret[32], const char *label,
                             size_t label_len, unsigned char *out, size_t out_len) {
    // HkdfLabel = uint16 length || (uint8 full_len || "tls13 "+label) || (uint8 0).
    unsigned char info[2 + 1 + 6 + 16 + 1];
    size_t full_len = 6 + label_len; // "tls13 " is 6 bytes incl. the trailing space
    if (full_len > 255 || (3 + full_len + 1) > sizeof(info)) return -1;
    info[0] = (unsigned char)(out_len >> 8);
    info[1] = (unsigned char)(out_len & 0xff);
    info[2] = (unsigned char)full_len;
    memcpy(info + 3, "tls13 ", 6);
    memcpy(info + 9, label, label_len);
    info[3 + full_len] = 0; // empty context, length 0
    size_t info_len = 3 + full_len + 1;

    psa_key_derivation_operation_t op = PSA_KEY_DERIVATION_OPERATION_INIT;
    int rc = -1;
    if (psa_key_derivation_setup(&op, PSA_ALG_HKDF_EXPAND(PSA_ALG_SHA_256)) != PSA_SUCCESS)
        goto out;
    // HKDF-Expand: SECRET (the PRK) then INFO, in that order, no SALT.
    if (psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_SECRET, secret, 32) != PSA_SUCCESS)
        goto out;
    if (psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_INFO, info, info_len) != PSA_SUCCESS)
        goto out;
    if (psa_key_derivation_output_bytes(&op, out, out_len) != PSA_SUCCESS)
        goto out;
    rc = 0;
out:
    psa_key_derivation_abort(&op);
    return rc;
}

// Derive the AES-128-GCM key + IV from a TLS 1.3 traffic secret into a kernel
// crypto_info. The 12-byte write_iv splits salt = first 4 bytes, iv = last 8.
static int fill_crypto_info(const unsigned char secret[32],
                            struct tls12_crypto_info_aes_gcm_128 *ci) {
    unsigned char key[16], iv12[12];
    if (hkdf_expand_label(secret, "key", 3, key, 16) != 0) return -1;
    if (hkdf_expand_label(secret, "iv", 2, iv12, 12) != 0) {
        memset(key, 0, 16);
        return -1;
    }
    memset(ci, 0, sizeof(*ci));
    ci->info.version = TLS_1_3_VERSION;            // 0x0304
    ci->info.cipher_type = TLS_CIPHER_AES_GCM_128; // 51
    memcpy(ci->key, key, 16);
    memcpy(ci->salt, iv12, 4);     // implicit/fixed nonce prefix
    memcpy(ci->iv, iv12 + 4, 8);   // explicit nonce
    // rec_seq stays all-zero: tickets are disabled, so the first app record is seq 0.
    memset(key, 0, 16);
    memset(iv12, 0, 12);
    return 0;
}

// One-time kTLS outcome logging so a deployment can see whether kTLS engaged or
// silently fell back to userspace TLS (≤2 lines per process: first engage + first
// fallback). The distinction matters: a benchmark on a host without the `tls`
// kernel module would otherwise measure the userspace path and look like a no-op.
static int ktls_logged_ok = 0;
static int ktls_logged_fb = 0;
static void ktls_log_fb(const char *why) {
    if (!ktls_logged_fb) {
        ktls_logged_fb = 1;
        fprintf(stderr, "[ktls] fallback to userspace TLS: %s\n", why);
    }
}

// Move record crypto into the kernel after the handshake. Returns 1 if kTLS TX+RX
// both engaged; 0 to stay on the userspace mbedtls path (clean fallback). On a
// setsockopt failure AFTER the ULP attached it sets ktls_failed (the socket is then
// half-converted and unusable for userspace — the caller MUST close the connection).
int vtls_enable_ktls(void *sess, int fd) {
    vtls_session *s = (vtls_session *)sess;
    // Derived/installed key material — scrubbed unconditionally at `done`.
    struct tls12_crypto_info_aes_gcm_128 tx, rx;
    memset(&tx, 0, sizeof(tx));
    memset(&rx, 0, sizeof(rx));

    // Must be the pinned single suite and both traffic secrets must be captured.
    if (mbedtls_ssl_get_ciphersuite_id_from_ssl(&s->ssl) != MBEDTLS_TLS1_3_AES_128_GCM_SHA256) {
        ktls_log_fb("ciphersuite is not TLS_AES_128_GCM_SHA256");
        goto done;
    }
    if (!s->keys.have_server || !s->keys.have_client) {
        ktls_log_fb("traffic secrets not exported");
        goto done;
    }
    // Handoff hazard: if mbedtls already decrypted-and-buffered application data, the
    // kernel (reading raw from the socket) would never see it. Stay userspace then.
    if (mbedtls_ssl_get_bytes_avail(&s->ssl) != 0 || mbedtls_ssl_check_pending(&s->ssl) != 0) {
        ktls_log_fb("mbedtls holds buffered plaintext at handoff");
        goto done;
    }
    // Derive AES-128-GCM key+iv per direction: server secret => TX, client => RX.
    if (fill_crypto_info(s->keys.server_app_secret, &tx) != 0) {
        ktls_log_fb("key derivation failed (TX)");
        goto done;
    }
    if (fill_crypto_info(s->keys.client_app_secret, &rx) != 0) {
        ktls_log_fb("key derivation failed (RX)");
        goto done;
    }
    // Attach the kTLS ULP. Failure here is the clean fallback point — nothing on the
    // socket changed, so the connection keeps running over userspace mbedtls
    // (errno ENOENT = the `tls` kernel module is not loaded).
    if (setsockopt(fd, SOL_TCP, TCP_ULP, "tls", sizeof("tls")) < 0) {
        if (!ktls_logged_fb) {
            ktls_logged_fb = 1;
            fprintf(stderr, "[ktls] fallback to userspace TLS: TCP_ULP failed (errno=%d %s)\n",
                    errno, strerror(errno));
        }
        goto done;
    }
    // Past the ULP attach, a TX/RX failure leaves the socket half-converted (userspace
    // mbedtls can no longer drive it) → mark for close (the caller checks ktls_failed).
    if (setsockopt(fd, SOL_TLS, TLS_TX, &tx, sizeof(tx)) < 0) {
        s->ktls_failed = 1;
        goto done;
    }
    if (setsockopt(fd, SOL_TLS, TLS_RX, &rx, sizeof(rx)) < 0) {
        s->ktls_failed = 1;
        goto done;
    }
    s->ktls = 1; // keys now live in the kernel
    if (!ktls_logged_ok) {
        ktls_logged_ok = 1;
        fprintf(stderr, "[ktls] engaged: kernel TLS TX+RX (TLS 1.3, AES-128-GCM)\n");
    }

done:
    // Scrub every userspace copy of key material on all paths: the derived
    // crypto_info and the captured traffic secrets (the kernel owns them now on
    // success; on fallback the userspace mbedtls path doesn't use s->keys).
    memset(&tx, 0, sizeof(tx));
    memset(&rx, 0, sizeof(rx));
    memset(&s->keys, 0, sizeof(s->keys));
    return s->ktls;
}

int vtls_ktls_active(void *sess) { return ((vtls_session *)sess)->ktls; }

int vtls_ktls_failed(void *sess) { return ((vtls_session *)sess)->ktls_failed; }
