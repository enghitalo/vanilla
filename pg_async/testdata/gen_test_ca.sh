#!/usr/bin/env bash
# gen_test_ca.sh — a throwaway certificate authority and server certificates
# for pg_async's TLS tests. Generated at test time into <outdir>, never
# committed (no private key belongs in the repository).
#
#   pg_async/testdata/gen_test_ca.sh /tmp/pg-certs
#
# Writes (EC P-256, SHA-256, valid 30 days):
#   ca.crt  ca.key             the test CA
#   server.crt  server.key     signed by it, SAN DNS:localhost, IP:127.0.0.1,
#                              IP:::1 (what the TLS-only test cluster serves)
#   wronghost.crt  wronghost.key   signed by it, SAN DNS:wrong.example only:
#                              a verify-full hostname-mismatch negative
#   other_ca.crt  other_ca.key     an unrelated CA: a verify-ca negative
# Keys are mode 0600, as PostgreSQL requires for ssl_key_file.

set -euo pipefail

out="${1:?usage: $0 <outdir>}"
mkdir -p "$out"
cd "$out"

days=30
ec=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes)

new_ca() { # <name> <cn>
	openssl req -x509 "${ec[@]}" -sha256 -days "$days" \
		-keyout "$1.key" -out "$1.crt" -subj "/CN=$2/O=vanilla-test" \
		-addext 'basicConstraints=critical,CA:TRUE' \
		-addext 'keyUsage=critical,keyCertSign,cRLSign' 2>/dev/null
}

new_leaf() { # <name> <cn> <subjectAltName>
	openssl req -new "${ec[@]}" -keyout "$1.key" -out "$1.csr" \
		-subj "/CN=$2/O=vanilla-test" 2>/dev/null
	printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyAgreement\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$3" > "$1.ext"
	openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
		-sha256 -days "$days" -extfile "$1.ext" -out "$1.crt" 2>/dev/null
	rm -f "$1.csr" "$1.ext"
}

new_ca ca 'vanilla pg_async test CA'
new_ca other_ca 'unrelated test CA'
new_leaf server localhost 'DNS:localhost,IP:127.0.0.1,IP:::1'
new_leaf wronghost wrong.example 'DNS:wrong.example'
rm -f ca.srl
chmod 600 ./*.key
echo "test CA and certificates written to $out"
