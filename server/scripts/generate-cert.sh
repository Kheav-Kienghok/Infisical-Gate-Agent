#!/usr/bin/env bash
# Self-signed certificate that is valid for IP addresses (no domain needed).
# Usage: ./scripts/generate-cert.sh <public-ip> [private-ip]
set -euo pipefail
PUBIP="${1:?usage: $0 <public-ip> [private-ip]}"
PRIVIP="${2:-}"
SAN="IP:${PUBIP},IP:127.0.0.1,DNS:localhost"
[ -n "$PRIVIP" ] && SAN="${SAN},IP:${PRIVIP}"
mkdir -p certs
openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 825 \
  -keyout certs/privkey.pem -out certs/fullchain.pem \
  -subj "/CN=${PUBIP}" \
  -addext "subjectAltName=${SAN}" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
  -addext "extendedKeyUsage=serverAuth"
chmod 600 certs/privkey.pem
chmod 644 certs/fullchain.pem
echo "Created certs/fullchain.pem (SAN: ${SAN})"
