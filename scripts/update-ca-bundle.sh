#!/usr/bin/env bash
# update-ca-bundle.sh — refresh userspace/lib/x509/ca.pem, the trust store the
# root image ships as /etc/ca.pem.
#
# The anchors are Mozilla's, as the host's distribution extracts them for TLS
# server authentication; the file is copied across unchanged under a header
# that says where it came from. Roots expire and get distrusted, so this is run
# now and then rather than once.
set -euo pipefail

R="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$R/userspace/lib/x509/ca.pem"

SRC=""
for c in /etc/ca-certificates/extracted/tls-ca-bundle.pem \
         /etc/ssl/certs/ca-certificates.crt \
         /etc/pki/tls/certs/ca-bundle.crt \
         /etc/ssl/cert.pem; do
    if [ -s "$c" ]; then SRC="$c"; break; fi
done
if [ -z "$SRC" ]; then
    echo "update-ca-bundle: no CA bundle found on this host" >&2
    exit 1
fi

N=$(grep -c 'BEGIN CERTIFICATE' "$SRC")
{
    echo "# /etc/ca.pem — the certificates this machine trusts for TLS server"
    echo "# authentication (lib/x509/trust.cst). Mozilla's root program, MPL-2.0."
    echo "# $N anchors, taken from $SRC on $(date -u +%Y-%m-%d)"
    echo "# by scripts/update-ca-bundle.sh; run it again to refresh."
    echo "#"
    cat "$SRC"
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "update-ca-bundle: $N anchors from $SRC -> $OUT"
