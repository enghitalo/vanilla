/*
 * vanilla_tls — thin C adapter over Mbed TLS 4 (TLS 1.3).
 * Cert generation ported from concept-examples/TLS/server.c.
 */
#include "vanilla_tls.h"

#include <mbedtls/ssl.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/pem.h>
#include <psa/crypto.h>
#include <psa/crypto_values.h>
#include <stdlib.h>
#include <string.h>

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

typedef struct {
    mbedtls_ssl_context ssl;
    mbedtls_net_context net;
} vtls_session;

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
    return s;
}

void vtls_session_free(void *sess) {
    if (!sess) return;
    vtls_session *s = (vtls_session *)sess;
    mbedtls_ssl_close_notify(&s->ssl);
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
