module tls_cert

#include <mbedtls/x509_crt.h>
#include <mbedtls/x509_csr.h>
#include <mbedtls/pk.h>
#include <mbedtls/pem.h>
#include <mbedtls/psa_util.h>
#include <mbedtls/error.h>
#include <mbedtls/x509.h>
#include <mbedtls/x509write.h>
#include <psa/crypto.h>

fn C.mbedtls_pk_wrap_psa(pk &mbedtls_pk_context, key_id u32) int
fn C.psa_generate_random(output &u8, output_size usize) psa_status_t
fn C.psa_destroy_key(key_id u32) psa_status_t

fn C.psa_crypto_init() int
fn C.mbedtls_psa_crypto_free()

pub const cert_buf_size = 4096

@[typedef]
struct C.mbedtls_x509write_cert {}

@[typedef]
struct C.mbedtls_pk_context {}
