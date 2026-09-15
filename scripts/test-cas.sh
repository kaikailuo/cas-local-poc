#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_command curl
load_env

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cas-poc-test.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
COOKIE_JAR="${TEST_DIR}/cookies.txt"
LOGIN_PAGE="${TEST_DIR}/login.html"
LOGIN_HEADERS="${TEST_DIR}/login.headers"
LOGIN_BODY="${TEST_DIR}/login-result.html"
VALIDATION="${TEST_DIR}/validation.xml"
CALLBACK_BODY="${TEST_DIR}/callback.html"

pass() { printf 'PASS: %s\n' "$*"; }

extract_location() {
  awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$1"
}

extract_ticket() {
  printf '%s' "$1" | sed -n 's/.*[?&]ticket=\([^&]*\).*/\1/p'
}

printf 'CAS 8.0.1 protocol smoke test\n'

for attempt in $(seq 1 30); do
  if curl --cacert "${CA_CERT}" -fsS "${CAS_URL}/login" >/dev/null 2>&1 \
    && curl --cacert "${CA_CERT}" -fsS "https://localhost:8081/health" >/dev/null 2>&1; then
    break
  fi
  [[ "${attempt}" -lt 30 ]] || die "CAS or test service did not become ready within 30 seconds"
  sleep 1
done

curl --cacert "${CA_CERT}" -fsS "${CAS_URL}/login" -o "${LOGIN_PAGE}"
grep -q '<form' "${LOGIN_PAGE}" || die "login endpoint responded without a login form"
pass "project CA trust and hostname verification succeeded; /login renders a form"

curl --cacert "${CA_CERT}" -fsS "https://localhost:8081/health" >/dev/null
pass "local test service is alive"

curl --cacert "${CA_CERT}" -fsS --get --data-urlencode "service=${SERVICE_URL}" \
  -c "${COOKIE_JAR}" -o "${LOGIN_PAGE}" "${CAS_URL}/login"

execution="$(sed -n 's/.*name="execution"[^>]*value="\([^"]*\)".*/\1/p' "${LOGIN_PAGE}" | head -1)"
[[ -n "${execution}" ]] || die "unable to extract Spring Webflow execution token"
pass "login Webflow execution token was issued"

login_url="${CAS_URL}/login?service=https%3A%2F%2Flocalhost%3A8081%2Fcallback"
curl --cacert "${CA_CERT}" -sS -D "${LOGIN_HEADERS}" -o "${LOGIN_BODY}" \
  -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
  --data-urlencode "username=${CAS_TEST_USER}" \
  --data-urlencode "password=${CAS_TEST_PASSWORD}" \
  --data-urlencode "execution=${execution}" \
  --data-urlencode "_eventId=submit" \
  --data-urlencode "geolocation=" \
  "${login_url}"

location="$(extract_location "${LOGIN_HEADERS}")"
ticket_one="$(extract_ticket "${location}")"
[[ "${ticket_one}" == ST-* ]] || {
  if grep -oE 'class="[^"]*(errors|alert)[^"]*"[^>]*>[^<]+' "${LOGIN_BODY}" >&2; then
    :
  fi
  die "credential login did not return an ST (Location: ${location:-none})"
}
grep -Eq $'\tTGC\t' "${COOKIE_JAR}" || die "login succeeded but no TGC cookie was stored"
pass "credentials authenticated; TGC (CAS session/TGT cookie) and first ST were issued"

curl --cacert "${CA_CERT}" -fsS --get \
  --data-urlencode "service=${SERVICE_URL}" \
  --data-urlencode "ticket=${ticket_one}" \
  "${CAS_URL}/serviceValidate" -o "${VALIDATION}"
grep -q '<cas:authenticationSuccess>' "${VALIDATION}" || die "first ST was rejected by /serviceValidate"
grep -q "<cas:user>${CAS_TEST_USER}</cas:user>" "${VALIDATION}" || die "validated principal did not match ${CAS_TEST_USER}"
pass "first ST validated once through /serviceValidate as ${CAS_TEST_USER}"

curl --cacert "${CA_CERT}" -sS --get --data-urlencode "service=${SERVICE_URL}" \
  -b "${COOKIE_JAR}" -D "${LOGIN_HEADERS}" -o "${LOGIN_BODY}" "${CAS_URL}/login"
location="$(extract_location "${LOGIN_HEADERS}")"
ticket_two="$(extract_ticket "${location}")"
[[ "${ticket_two}" == ST-* ]] || die "existing TGC did not produce a second ST without credentials"
[[ "${ticket_two}" != "${ticket_one}" ]] || die "CAS unexpectedly reused a service ticket"
pass "existing CAS session/TGT produced a distinct second ST without credentials"

callback_status="$(curl --cacert "${CA_CERT}" -sS -o "${CALLBACK_BODY}" -w '%{http_code}' "https://localhost:8081/callback?ticket=${ticket_two}")"
if [[ "${callback_status}" != "200" ]]; then
  sed -n '1,80p' "${CALLBACK_BODY}" >&2
  die "test service returned HTTP ${callback_status} while validating callback ticket"
fi
grep -q "Authenticated user: <strong>${CAS_TEST_USER}</strong>" "${CALLBACK_BODY}" || die "test service did not identify the expected user"
pass "test service received the callback, validated the second ST, and identified ${CAS_TEST_USER}"

reuse_result="$(curl --cacert "${CA_CERT}" -sS --get --data-urlencode "service=${SERVICE_URL}" --data-urlencode "ticket=${ticket_two}" "${CAS_URL}/serviceValidate")"
grep -q '<cas:authenticationFailure' <<<"${reuse_result}" || die "CAS did not reject reuse of the consumed ST"
pass "consumed ST was rejected on reuse (one-time ticket semantics)"

printf 'PASS: complete CAS flow: authentication -> TGT/TGC -> ST -> service validation.\n'
