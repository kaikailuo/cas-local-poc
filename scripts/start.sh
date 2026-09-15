#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command docker
require_command curl
require_command openssl

docker info >/dev/null 2>&1 || die "Docker daemon 不可用；请启动 Docker Desktop 后重试"
docker compose version >/dev/null 2>&1 || die "Docker Compose 插件不可用"

generate_base64url() {
  openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '=\r\n'
}

if [[ ! -f "${ENV_FILE}" ]]; then
  umask 077
  generated_password="$(openssl rand -hex 12)"
  generated_keystore_password="$(openssl rand -hex 16)"
  {
    printf 'CAS_TEST_USER=casuser\n'
    printf 'CAS_TEST_PASSWORD=%s\n' "${generated_password}"
    printf 'CAS_KEYSTORE_PASSWORD=%s\n' "${generated_keystore_password}"
    printf 'CAS_WEBFLOW_ENCRYPTION_KEY=%s\n' "$(generate_base64url 16)"
    printf 'CAS_WEBFLOW_SIGNING_KEY=%s\n' "$(generate_base64url 64)"
    printf 'CAS_TGC_ENCRYPTION_KEY=%s\n' "$(generate_base64url 64)"
    printf 'CAS_TGC_SIGNING_KEY=%s\n' "$(generate_base64url 64)"
  } > "${ENV_FILE}"
  printf 'Created local-only .env with a generated password for casuser.\n'
fi

for secret_spec in \
  'CAS_TEST_PASSWORD 18' \
  'CAS_KEYSTORE_PASSWORD 24' \
  'CAS_WEBFLOW_ENCRYPTION_KEY 16' \
  'CAS_WEBFLOW_SIGNING_KEY 64' \
  'CAS_TGC_ENCRYPTION_KEY 64' \
  'CAS_TGC_SIGNING_KEY 64'; do
  read -r secret_name secret_bytes <<<"${secret_spec}"
  if ! grep -Eq "^${secret_name}=.+" "${ENV_FILE}"; then
    printf '%s=%s\n' "${secret_name}" "$(generate_base64url "${secret_bytes}")" >> "${ENV_FILE}"
  fi
done

load_env
mkdir -p "${PROJECT_DIR}/runtime/logs"
"${PROJECT_DIR}/scripts/generate-cert.sh"

printf 'Starting official CAS 8.0.1 image plus the local test service...\n'
compose up -d --build

printf 'Waiting for CAS login page'
for attempt in $(seq 1 120); do
  if curl -kfsS "${CAS_URL}/login" >/dev/null 2>&1; then
    if curl -kfsS "https://localhost:8081/health" >/dev/null 2>&1; then
      printf '\nCAS and test service are ready.\n'
      printf 'CAS:          %s/login\n' "${CAS_URL}"
      printf 'Test service: https://localhost:8081/\n'
      printf 'Test user:    %s (password is in .env)\n' "${CAS_TEST_USER}"
      exit 0
    fi
  fi
  if ! compose ps --status running --services | grep -qx cas; then
    printf '\n'
    compose logs --tail=120 cas
    die "CAS container stopped during startup"
  fi
  printf '.'
  sleep 2
done

printf '\n'
compose logs --tail=150 cas
die "CAS and test service did not become ready within 240 seconds"
