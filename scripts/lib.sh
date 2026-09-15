#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
CAS_URL="https://localhost:8443/cas"
SERVICE_URL="https://localhost:8081/callback"

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

compose() {
  docker compose --project-directory "${PROJECT_DIR}" "$@"
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "缺少 .env；请先运行 ./scripts/start.sh"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  [[ -n "${CAS_TEST_USER:-}" ]] || die ".env 中 CAS_TEST_USER 为空"
  [[ -n "${CAS_TEST_PASSWORD:-}" ]] || die ".env 中 CAS_TEST_PASSWORD 为空"
  [[ -n "${CAS_KEYSTORE_PASSWORD:-}" ]] || die ".env 中 CAS_KEYSTORE_PASSWORD 为空"
  [[ -n "${CAS_WEBFLOW_ENCRYPTION_KEY:-}" ]] || die ".env 中 CAS_WEBFLOW_ENCRYPTION_KEY 为空"
  [[ -n "${CAS_WEBFLOW_SIGNING_KEY:-}" ]] || die ".env 中 CAS_WEBFLOW_SIGNING_KEY 为空"
  [[ -n "${CAS_TGC_ENCRYPTION_KEY:-}" ]] || die ".env 中 CAS_TGC_ENCRYPTION_KEY 为空"
  [[ -n "${CAS_TGC_SIGNING_KEY:-}" ]] || die ".env 中 CAS_TGC_SIGNING_KEY 为空"
}
