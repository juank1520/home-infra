#!/bin/sh
set -e

# Generate a local CA and a *.lan wildcard cert for Traefik so it serves a
# proper certificate for pihole.lan (and other *.lan hosts) instead of falling
# back to its self-signed default. Must run before Traefik starts.
# Idempotent: skips generation if a valid cert already exists.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/certs"

mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

if [ -f local.crt ] && openssl x509 -in local.crt -noout >/dev/null 2>&1; then
    echo "Traefik cert already present and valid — skipping generation."
    exit 0
fi

echo "Generating local CA and *.lan certificate for Traefik..."

# Root CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt \
  -subj "/C=GT/O=Juank Homelab/CN=Juank Root CA"

# Server key + CSR
openssl genrsa -out local.key 4096
openssl req -new -key local.key -out local.csr -subj "/CN=*.lan"

# Sign with SAN. POSIX sh has no process substitution, so use a temp extfile.
EXT=$(mktemp)
printf 'subjectAltName=DNS:*.lan,DNS:pihole.lan\n' > "$EXT"
openssl x509 -req -in local.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out local.crt -days 825 -sha256 \
  -extfile "$EXT"
rm -f "$EXT"

echo "Certificate generated at ${CERTS_DIR}/local.crt"
