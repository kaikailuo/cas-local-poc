#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command docker
require_command openssl
require_command security

JAMF_CA_COMMON_NAME="UMU JSS Built-in Certificate Authority"
JAMF_CA_ALIAS="jamf-umu-jss-built-in-ca"
JAMF_CA_EXPECTED_SHA256="55:E2:C2:4C:49:B4:3E:E9:16:04:15:8F:DB:A5:07:FD:DD:A8:DE:D7:FA:2A:C5:31:07:F9:1D:67:96:4C:15:D9"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"
CERT_DIR="${PROJECT_DIR}/runtime/certs"
CA_CERT_FILE="${CERT_DIR}/jamf-umu-jss-built-in-ca.pem"
TRUSTSTORE_FILE="${CERT_DIR}/jamf-client-truststore.jks"
X509_IMAGE="cas-local-poc/cas-x509:8.0.1"

docker info >/dev/null 2>&1 || die "Docker daemon 不可用；请启动 Docker Desktop 后重试"
docker image inspect "${X509_IMAGE}" >/dev/null 2>&1 \
  || die "缺少 ${X509_IMAGE}；请先完成并构建 Stage 1 X.509 Overlay"
[[ -f "${ENV_FILE}" ]] || die "缺少 .env；请先运行 ./scripts/start.sh"

if ! grep -Eq '^CAS_X509_TRUSTSTORE_PASSWORD=.+' "${ENV_FILE}"; then
  umask 077
  printf 'CAS_X509_TRUSTSTORE_PASSWORD=%s\n' "$(openssl rand -hex 24)" >> "${ENV_FILE}"
fi
chmod 600 "${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
[[ -n "${CAS_X509_TRUSTSTORE_PASSWORD:-}" ]] \
  || die ".env 中 CAS_X509_TRUSTSTORE_PASSWORD 为空"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cas-jamf-truststore.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

security find-certificate -c "${JAMF_CA_COMMON_NAME}" -p "${SYSTEM_KEYCHAIN}" \
  > "${work_dir}/jamf-ca.pem"
grep -q 'BEGIN CERTIFICATE' "${work_dir}/jamf-ca.pem" \
  || die "System Keychain 中未找到 ${JAMF_CA_COMMON_NAME}"

subject="$(openssl x509 -in "${work_dir}/jamf-ca.pem" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
issuer="$(openssl x509 -in "${work_dir}/jamf-ca.pem" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')"
fingerprint="$(openssl x509 -in "${work_dir}/jamf-ca.pem" -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//')"

[[ "${subject}" == "CN=${JAMF_CA_COMMON_NAME}" ]] \
  || die "Jamf CA Subject 不符合预期: ${subject}"
[[ "${issuer}" == "CN=${JAMF_CA_COMMON_NAME}" ]] \
  || die "Jamf CA Issuer 不符合预期: ${issuer}"
[[ "${fingerprint}" == "${JAMF_CA_EXPECTED_SHA256}" ]] \
  || die "Jamf CA SHA-256 fingerprint 不符合已验收值"

docker run --rm --pull never --network none \
  --user "$(id -u):$(id -g)" \
  --env CAS_X509_TRUSTSTORE_PASSWORD \
  --volume "${work_dir}:/work" \
  --entrypoint keytool \
  "${X509_IMAGE}" \
  -importcert -noprompt \
  -alias "${JAMF_CA_ALIAS}" \
  -file /work/jamf-ca.pem \
  -keystore /work/jamf-client-truststore.jks \
  -storetype JKS \
  -storepass:env CAS_X509_TRUSTSTORE_PASSWORD >/dev/null

mkdir -p "${CERT_DIR}"
install -m 600 "${work_dir}/jamf-ca.pem" "${CA_CERT_FILE}"
install -m 600 "${work_dir}/jamf-client-truststore.jks" "${TRUSTSTORE_FILE}"

docker run --rm --pull never --network none \
  --user "$(id -u):$(id -g)" \
  --env CAS_X509_TRUSTSTORE_PASSWORD \
  --volume "${CERT_DIR}:/work:ro" \
  --entrypoint keytool \
  "${X509_IMAGE}" \
  -list -v \
  -alias "${JAMF_CA_ALIAS}" \
  -keystore /work/jamf-client-truststore.jks \
  -storetype JKS \
  -storepass:env CAS_X509_TRUSTSTORE_PASSWORD >/dev/null

printf 'PASS: isolated Jamf CA truststore created at %s\n' "${TRUSTSTORE_FILE}"
printf 'Alias: %s\n' "${JAMF_CA_ALIAS}"
printf 'Subject: %s\n' "${subject}"
printf 'Issuer: %s\n' "${issuer}"
printf 'SHA-256 fingerprint: %s\n' "${fingerprint}"
