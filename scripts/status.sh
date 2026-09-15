#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command docker
require_command curl

printf 'CAS local POC container status:\n'
compose ps
printf '\nEndpoints:\n'
printf '  CAS login:    %s/login\n' "${CAS_URL}"
printf '  Test service: https://localhost:8081/\n'

if curl -kfsS "${CAS_URL}/login" >/dev/null 2>&1; then
  printf 'PASS: CAS login page is reachable over HTTPS.\n'
else
  printf 'FAIL: CAS login page is not reachable.\n' >&2
  exit 1
fi

if curl -kfsS "https://localhost:8081/health" >/dev/null 2>&1; then
  printf 'PASS: Test service is reachable.\n'
else
  printf 'FAIL: Test service is not reachable.\n' >&2
  exit 1
fi
