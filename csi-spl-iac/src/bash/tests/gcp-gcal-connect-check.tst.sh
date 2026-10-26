#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_gcal_connect_check (spec 149), offline: gcloud, curl and the
# cnf merge are stubbed, no live call.
#   1. all set: rc 0, every gcloud call carries --account, nothing enabled,
#      the console-only steps are printed as MANUAL lines.
#   2. S3 missing (Google answers redirect_uri_mismatch): rc 3 and the exact
#      MANUAL S3 line with the calendar callback URI.
#   3. the Calendar API off, DRY_RUN default: rc 3, says what it would run,
#      enables nothing.
#   4. the Calendar API off, DRY_RUN=0: enables it as the pinned SA.
#   5. an answer the probe cannot read is a FAIL, never an OK.
#   6. refusals: bad DRY_RUN, bad ENV, a placeholder client id, no account.
#   7. the client id is never printed.
# GCAL_CHECK_ACTION points the test at another copy (the red controls).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
A="${GCAL_CHECK_ACTION:-$PROJ_ROOT/src/bash/run/gcp-gcal-connect-check.func.sh}"
require_action "$A"
command -v yq >/dev/null || { echo "FAIL: yq is not installed"; exit 1; }
unset DRY_RUN ACCOUNT GCP_ACCOUNT
export ENV=dev ORG=o APP=a APP_PATH="$T"
CID=111-testclientid.apps.example.com
do_log() { echo "$*"; }
do_gcp_spl_proj_id() { export PROJ_ID=o-a-dev; }
do_gcp_pin_account() { [[ -n "${STUB_NO_ACCOUNT:-}" ]] && return 1; export GCP_ACCOUNT=o-a-dev@o-a-dev.iam.gserviceaccount.com; }
do_spl_merged_cnf() {
  cat >"$3" <<YAML
env:
  dns: {fqdn: app.example.com}
  gcp: {gcp_project: o-a-dev}
  auth:
    social:
      env:
        SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID: ${STUB_CID:-$CID}
        SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI: https://app.example.com/api/v1/auth/google/callback
  gcal: {scopes: "openid email", auth_url: "https://accounts.example.com/o/oauth2/v2/auth"}
  steps:
    001-enable-gcp-services: {gcp_services: [iam.googleapis.com, calendar-json.googleapis.com]}
YAML
}
MISMATCH=$(printf '\n\025redirect_uri_mismatch\022 You cannot sign in' | base64 -w0 | tr '+/' '-_')
stub gcloud "printf '%s\n' \"\$*\" >> '$T/gcloud.log'
[[ \"\$*\" == *'services list'* ]] && printf '%b' \"\${STUB_ENABLED:-}\"
exit 0"
# curl: STUB_REG lists the registered paths; STUB_CURL_500 = an unreadable answer
stub curl "for a in \"\$@\"; do [[ \$a == redirect_uri=* ]] && r=\${a#redirect_uri=}; done
[[ -n \"\${STUB_CURL_500:-}\" ]] && { printf '500 '; exit 0; }
p=\${r#https://app.example.com}
if [[ \" \${STUB_REG:-} \" == *\" \$p \"* ]]; then printf '302 https://accounts.example.com/v3/signin/identifier?x=1'
else printf '302 https://accounts.example.com/signin/oauth/error?authError=$MISMATCH&client_id=x'; fi"
export PATH="$T/bin:$PATH"
ON='iam.googleapis.com\ncalendar-json.googleapis.com\n'
BOTH='/api/v1/auth/google/callback /v1/me/google-calendar/callback'
# shellcheck disable=SC1090
source "$A"
all=""

# --- 1. all set ---------------------------------------------------------------
: >"$T/gcloud.log"
out=$(STUB_ENABLED=$ON STUB_REG=$BOTH do_gcp_gcal_connect_check 2>&1); rc=$?; all+=$out
(( rc == 0 )) && grep -q 'OK step 1: calendar-json.googleapis.com is enabled' <<<"$out" \
  && grep -q 'OK step S3: https://app.example.com/v1/me/google-calendar/callback is an authorised' <<<"$out" \
  && pass "all set: rc 0, API on, S3 registered" || fail "all set: rc=$rc out=$out"
[[ $(grep -c '^MANUAL ' <<<"$out") -eq 3 ]] && grep -q 'MANUAL S2 scope.*calendar.app.created' <<<"$out" \
  && pass "the console-only steps (S2 scope, test users, branding) are MANUAL lines" || fail "MANUAL lines: $out"
[[ -n $(grep -v -- '--account=o-a-dev@' "$T/gcloud.log") ]] \
  && fail "a gcloud call without --account: $(cat "$T/gcloud.log")" || pass "every gcloud call carries --account"
grep -q 'services enable' "$T/gcloud.log" && fail "all set enabled something" || pass "all set: nothing is enabled"

# --- 2. S3 missing ------------------------------------------------------------
out=$(STUB_ENABLED=$ON STUB_REG=/api/v1/auth/google/callback do_gcp_gcal_connect_check 2>&1); rc=$?; all+=$out
(( rc == 3 )) && grep -q 'FAIL step S3: Google answers redirect_uri_mismatch' <<<"$out" \
  && grep -q 'MANUAL S3 .*Add URI: https://app.example.com/v1/me/google-calendar/callback (not JavaScript origins)' <<<"$out" \
  && pass "S3 missing: rc 3 and the exact manual step" || fail "S3 missing: rc=$rc out=$out"
out=$(STUB_ENABLED=$ON STUB_REG=/v1/me/google-calendar/callback do_gcp_gcal_connect_check 2>&1); rc=$?; all+=$out
(( rc == 3 )) && grep -q 'FAIL the sign-in redirect URI' <<<"$out" \
  && pass "a lost sign-in redirect URI fails too" || fail "sign-in lost: rc=$rc out=$out"

# --- 3. API off, dry run ------------------------------------------------------
: >"$T/gcloud.log"
out=$(STUB_ENABLED='iam.googleapis.com\n' STUB_REG=$BOTH do_gcp_gcal_connect_check 2>&1); rc=$?; all+=$out
(( rc == 3 )) && grep -q 'DRY_RUN would run: gcloud services enable calendar-json.googleapis.com --project=o-a-dev --account=' <<<"$out" \
  && ! grep -q 'services enable' "$T/gcloud.log" \
  && pass "API off: DRY_RUN is the default and enables nothing" || fail "API off dry: rc=$rc out=$out"

# --- 4. API off, DRY_RUN=0 ----------------------------------------------------
: >"$T/gcloud.log"
out=$(STUB_ENABLED='iam.googleapis.com\n' STUB_REG=$BOTH DRY_RUN=0 do_gcp_gcal_connect_check 2>&1); rc=$?; all+=$out
(( rc == 0 )) && grep -qx 'services enable calendar-json.googleapis.com --project=o-a-dev --account=o-a-dev@o-a-dev.iam.gserviceaccount.com' "$T/gcloud.log" \
  && pass "DRY_RUN=0 enables the API as the pinned SA" || fail "enable: rc=$rc log=$(cat "$T/gcloud.log")"

# --- 5. unreadable answer -----------------------------------------------------
out=$(STUB_ENABLED=$ON STUB_CURL_500=1 do_gcp_gcal_connect_check 2>&1); rc=$?; all+=$out
(( rc == 3 )) && grep -q "FAIL step S3: Google's answer .* was not read: unknown:500" <<<"$out" && ! grep -q 'OK step S3' <<<"$out" \
  && pass "an unreadable answer is a FAIL, never an OK" || fail "unreadable: rc=$rc out=$out"

# --- 6. refusals --------------------------------------------------------------
DRY_RUN=2 do_gcp_gcal_connect_check >/dev/null 2>&1; rc=$?
(( rc == 1 )) && pass "a bad DRY_RUN is refused" || fail "DRY_RUN=2 rc=$rc"
ENV=lde do_gcp_gcal_connect_check >/dev/null 2>&1; rc=$?
(( rc == 1 )) && pass "ENV other than dev/prd is refused" || fail "ENV=lde rc=$rc"
STUB_CID=PLACEHOLDER-google-client-id do_gcp_gcal_connect_check >/dev/null 2>&1; rc=$?
(( rc == 1 )) && pass "a placeholder client id is refused" || fail "placeholder rc=$rc"
STUB_NO_ACCOUNT=1 STUB_REG=$BOTH do_gcp_gcal_connect_check >/dev/null 2>&1; rc=$?
(( rc == 1 )) && pass "no project SA: refused, no owner fallback" || fail "no account rc=$rc"

# --- 7. the client id never shows ---------------------------------------------
grep -qF "$CID" <<<"$all" && fail "the client id was printed" || pass "the client id is never printed"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
