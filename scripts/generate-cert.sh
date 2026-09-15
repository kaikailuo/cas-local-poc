#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command openssl
load_env

CERT_DIR="${PROJECT_DIR}/runtime/certs"
KEY_FILE="${CERT_DIR}/localhost.key"
CERT_FILE="${CERT_DIR}/localhost.crt"
KEYSTORE_FILE="${CERT_DIR}/localhost.p12"

mkdir -p "${CERT_DIR}"

if [[ -s "${KEY_FILE}" && -s "${CERT_FILE}" && -s "${KEYSTORE_FILE}" ]]; then
  printf 'Local certificate already exists: %s\n' "${CERT_FILE}"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -keyout "${KEY_FILE}" \
  -out "${CERT_FILE}" \
  -days 825 \
  -subj "/CN=localhost/O=CAS Local POC" \
  -addext "subjectAltName=DNS:localhost,DNS:cas,IP:127.0.0.1" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"

openssl pkcs12 -export \
  -name cas \
  -inkey "${KEY_FILE}" \
  -in "${CERT_FILE}" \
  -out "${KEYSTORE_FILE}" \
  -passout "pass:${CAS_KEYSTORE_PASSWORD}"

chmod 600 "${KEY_FILE}" "${KEYSTORE_FILE}"
printf 'Generated self-signed localhost certificate: %s\n' "${CERT_FILE}"

