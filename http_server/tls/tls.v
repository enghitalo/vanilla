module tls

#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/error.h>
#include <mbedtls/ssl.h>
#include <mbedtls/ssl_ticket.h>
#include <mbedtls/ssl_cookie.h>
#include <mbedtls/version.h>
#include <mbedtls/build_info.h>

fn C.mbedtls_ssl_get_ciphersuite(ssl &mbedtls_ssl_context) &char
fn C.mbedtls_ssl_get_version(ssl &mbedtls_ssl_context) &char
fn C.mbedtls_x509_crt_info(buf &char, size usize, prefix &char, crt &mbedtls_x509_crt) int
fn C.mbedtls_strerror(errnum int, buf &u8, buflen usize)
