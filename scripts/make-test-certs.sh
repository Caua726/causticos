#!/bin/bash
# make-test-certs.sh — build the certificate fixtures x509t validates against.
#
# Real DER from a real toolchain, not hand-written vectors. A parser tested only
# against certificates its author also wrote agrees with itself and nothing
# else; these come out of OpenSSL, which is what the servers of the world use.
#
# The interesting half is the failures. A validator that accepts every good
# certificate and is never shown a bad one has not been tested at all, so this
# builds one fixture per way a chain can be wrong: expired, not yet valid,
# wrong hostname, signed by a CA nobody trusts, and signed by something that
# was never allowed to sign certificates.
#
#   scripts/make-test-certs.sh [outdir]
set -e
OUT="${1:-build/certs}"
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$OUT"

SUBJ_ROOT="/CN=CausticOS Test Root"
SUBJ_INT="/CN=CausticOS Test Intermediate"
CA_EXT="basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign"

leaf_ext() {
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nsubjectAltName=%s\n' "$1"
}

q() { "$@" >/dev/null 2>&1; }

# ---- RSA root -> intermediate -> leaf ----
q openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.pem \
    -days 3650 -subj "$SUBJ_ROOT" -addext "$CA_EXT" -sha256

q openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj "$SUBJ_INT"
printf '%s\n' "$CA_EXT" > int.ext
q openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -out int.pem \
    -days 3000 -extfile int.ext -sha256 -set_serial 2

q openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=host.causticos"
leaf_ext "DNS:host.causticos,DNS:alt.causticos" > leaf.ext
q openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -out leaf.pem \
    -days 800 -extfile leaf.ext -sha256 -set_serial 3

# A wildcard leaf, to pin the rule that '*' is one label and only the leftmost.
q openssl req -newkey rsa:2048 -nodes -keyout wild.key -out wild.csr -subj "/CN=wild"
leaf_ext "DNS:*.causticos" > wild.ext
q openssl x509 -req -in wild.csr -CA int.pem -CAkey int.key -out wild.pem \
    -days 800 -extfile wild.ext -sha256 -set_serial 4

# ---- Expired, and not yet valid ----
# -not_before / -not_after take YYYYMMDDHHMMSSZ. Fixed dates rather than
# relative ones so the fixture means the same thing whenever it is rebuilt.
q openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -out expired.pem \
    -not_before 20200101000000Z -not_after 20210101000000Z \
    -extfile leaf.ext -sha256 -set_serial 5
q openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -out future.pem \
    -not_before 20900101000000Z -not_after 20910101000000Z \
    -extfile leaf.ext -sha256 -set_serial 6

# ---- Signed by a root nobody trusts ----
q openssl req -x509 -newkey rsa:2048 -nodes -keyout rogue.key -out rogueca.pem \
    -days 3650 -subj "/CN=Rogue Root" -addext "$CA_EXT" -sha256
q openssl x509 -req -in leaf.csr -CA rogueca.pem -CAkey rogue.key -out rogue.pem \
    -days 800 -extfile leaf.ext -sha256 -set_serial 7

# ---- Signed by something that is not a CA ----
# The signature is perfectly valid; what is wrong is that a leaf certificate
# signed it. Without the basicConstraints check this is indistinguishable from
# a real chain, and it is how anyone holding any certificate mints one for a
# bank.
q openssl req -newkey rsa:2048 -nodes -keyout notca.key -out notca.csr -subj "/CN=Not A CA"
leaf_ext "DNS:notaca.causticos" > notca.ext
q openssl x509 -req -in notca.csr -CA int.pem -CAkey int.key -out notca.pem \
    -days 800 -extfile notca.ext -sha256 -set_serial 8
q openssl req -newkey rsa:2048 -nodes -keyout under.key -out under.csr -subj "/CN=under.causticos"
leaf_ext "DNS:under.causticos" > under.ext
q openssl x509 -req -in under.csr -CA notca.pem -CAkey notca.key -out under.pem \
    -days 800 -extfile under.ext -sha256 -set_serial 9

# ---- An ECDSA P-256 chain, for the other signature path ----
q openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout ecroot.key -out ecroot.pem -days 3650 -subj "/CN=CausticOS EC Root" \
    -addext "$CA_EXT" -sha256
q openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout ecleaf.key -out ecleaf.csr -subj "/CN=ec.causticos"
leaf_ext "DNS:ec.causticos" > ecleaf.ext
q openssl x509 -req -in ecleaf.csr -CA ecroot.pem -CAkey ecroot.key -out ecleaf.pem \
    -days 800 -extfile ecleaf.ext -sha256 -set_serial 10

# ---- DER for the guest, PEM for the trust store ----
for n in root int leaf wild expired future rogue under notca ecroot ecleaf; do
    openssl x509 -in "$n.pem" -outform DER -out "$n.der" 2>/dev/null
done

# The store the test trusts: the RSA root and the EC root, and nothing else.
cat root.pem ecroot.pem > ca.pem

echo "certs in $OUT:"
ls -1 *.der | sed 's/^/  /'
