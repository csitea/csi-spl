#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the curl calls in this lane are time-bounded. A curl stub first on
#          PATH logs its argv and exits 28. Call _gandi_api,
#          spl_db_health_metrics, spl_db_api_user_set and _req (nested in
#          do_spl_checkout_fake_buy; the test lifts that body and calls it).
#          Every logged line has --max-time or -m . CONTROL: the stub exits
#          28 and each caller returns non-zero.
#          Round 4 row 10 adds spl_claim_tag_api, do_spl_db_insights,
#          do_spl_checkout_stripe_test_buy (GET /plan, its own _req; the
#          confirm curl is pinned in source), _spl_stripe_api and the lint
#          tool downloads (_ilt_fetch, _ilt_fetch_sums: --speed-limit too).
#          The setup-app-inf probes are pinned in source: calling them sleeps
#          through the readiness loop.
#          Round 4 row 14 adds do_spl_domain_verify (LIST, VERIFY, TOKEN),
#          spl_firebase_domain_poll and the downloads ghr_tarball,
#          oss_gitleaks_bin and install.sh's fetch (--speed-limit too).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export STUB_LOG="$T/curl.log"
mkdir -p "$T/bin"

cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "curl $*" >>"${STUB_LOG:?STUB_LOG unset}"
exit 28
EOF
cat >"$T/bin/gcloud" <<'EOF'
#!/bin/sh
printf '%s\n' 'ya29.stub-token'
exit 0
EOF
chmod +x "$T/bin/curl" "$T/bin/gcloud"
export PATH="$T/bin:$PATH"

do_log() { printf '%s\n' "$*" >&2; }
do_require_bin() { return 0; }

# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/lib/bash/funcs/gandi-api.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-db-health.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/lib/bash/funcs/spl-db-roles.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/lib/bash/funcs/spl-checkout.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-checkout-fake-buy.func.sh"

# _req is defined only once do_spl_checkout_fake_buy runs past it. Lift the
# nested body (two-space indent) so this test can call _req itself.
awk '
  /^  _req\(\)/ { on = 1 }
  on && /^  }$/ { sub(/^  /, ""); print; exit }
  on { sub(/^  /, ""); print }
' "$PROJ_ROOT/src/bash/run/spl-checkout-fake-buy.func.sh" >"$T/req.sh"
# shellcheck disable=SC1090,SC1091
source "$T/req.sh"
declare -F _req >/dev/null && pass "lifted nested _req" || fail "could not lift _req"

export ORG=csi GANDI_PAT=pat-stub GANDI_API_BASE=https://gandi.example.test
export GCP_ACCOUNT=sa@example.test SPL_PROJECT=proj-stub SPL_SQL_INSTANCE=inst-stub

# run_bounded <label> <cmd...> — stub log must be all time-bounded, rc non-zero.
run_bounded() {
  local label="$1" rc=0 line bad=0
  shift
  : >"$STUB_LOG"
  "$@" >"$T/out" 2>"$T/err" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    fail "$label returned 0; curl stub exits 28"
  else
    pass "$label returns non-zero when curl exits 28 (rc=$rc)"
  fi
  if [[ ! -s "$STUB_LOG" ]]; then
    fail "$label: curl stub logged nothing ($(tail -n 3 "$T/err" 2>/dev/null | tr '\n' ' '))"
    return
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" != *"--max-time"* && "$line" != *"-m "* ]]; then
      bad=1
      fail "$label: argv has no --max-time or -m"
    fi
  done <"$STUB_LOG"
  [[ "$bad" -eq 0 ]] && pass "$label: every curl argv is time-bounded"
}

: >"$STUB_LOG"
curl --max-time 1 http://127.0.0.1/control >/dev/null 2>&1
crc=$?
[[ "$crc" -eq 28 ]] && pass "CONTROL: the curl stub exits 28" || fail "CONTROL: curl stub rc=$crc"

run_bounded _gandi_api _gandi_api GET /livedns/domains
grep -q -- '--connect-timeout 10' "$STUB_LOG" && grep -q -- '--max-time 30' "$STUB_LOG" \
  && pass "_gandi_api default is connect-timeout 10 and max-time 30" \
  || fail "_gandi_api default bounds missing"

: >"$STUB_LOG"
rc=0
GANDI_MAX_TIME=9 _gandi_api GET /livedns/domains >"$T/out" 2>"$T/err" || rc=$?
[[ "$rc" -ne 0 ]] && grep -q -- '--max-time 9' "$STUB_LOG" \
  && pass "GANDI_MAX_TIME overrides --max-time (rc=$rc)" \
  || fail "GANDI_MAX_TIME override rc=$rc"

run_bounded spl_db_health_metrics spl_db_health_metrics
n=$(grep -c -- '--max-time 30' "$STUB_LOG" || true)
c=$(grep -c -- '--connect-timeout 10' "$STUB_LOG" || true)
[[ "$n" -eq 5 && "$c" -eq 5 ]] \
  && pass "spl_db_health_metrics bounds all 5 series (connect 10, max-time 30)" \
  || fail "spl_db_health_metrics bounds: max-time=$n connect=$c"

run_bounded spl_db_api_user_set spl_db_api_user_set stubuser secret-stub
grep -q -- '--connect-timeout 10' "$STUB_LOG" && grep -q -- '--max-time 60' "$STUB_LOG" \
  && pass "spl_db_api_user_set uses connect-timeout 10 and max-time 60" \
  || fail "spl_db_api_user_set bounds missing"

ENV=lde BASE_URL=http://127.0.0.1:9 DRY_RUN=1 TENANT_ID=acme BUYER_EMAIL=buyer@example.com \
  run_bounded "GET /plan" do_spl_checkout_fake_buy
grep -q -- '-m 30' "$STUB_LOG" && pass "GET /plan passes -m 30" || fail "GET /plan has no -m 30"

run_bounded _req _req GET http://127.0.0.1:9/healthz
grep -q -- '-m 30' "$STUB_LOG" && pass "_req passes -m 30" || fail "_req has no -m 30"

# --- round 4 row 10 -----------------------------------------------------------
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/lib/bash/funcs/spl-release-version.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-db-insights.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-checkout-stripe-test-buy.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-provision-stripe-endpoints.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/../csi-spl-iac/src/bash/run/install-lint-tools.func.sh"

# bounds_are <label> <connect> <max>: every stub line carries both values.
bounds_are() {
  local n c all
  all=$(wc -l <"$STUB_LOG")
  n=$(grep -c -- "--max-time $3" "$STUB_LOG" || true)
  c=$(grep -c -- "--connect-timeout $2" "$STUB_LOG" || true)
  [[ "$all" -gt 0 && "$n" -eq "$all" && "$c" -eq "$all" ]] \
    && pass "$1 uses connect-timeout $2 and max-time $3" \
    || fail "$1 bounds: lines=$all max-time=$n connect=$c"
}

run_bounded spl_claim_tag_api spl_claim_tag_api o/r 0123abc v9.9.9 tok-stub
bounds_are spl_claim_tag_api 10 30

insights_run() (
  do_spl_cloud_cnf() { return 0; }
  do_gcp_pin_account() { return 0; }
  do_gcp_require_live_account() { return 0; }
  ENV=dev SPL_CNF=/dev/null do_spl_db_insights
)
run_bounded do_spl_db_insights insights_run
bounds_are do_spl_db_insights 10 60

stripe_buy_run() (
  spl_checkout_require_locale() { return 0; }
  spl_checkout_require_buyer() { return 0; }
  # shellcheck disable=SC2034 # read by do_spl_checkout_stripe_test_buy
  do_spl_cloud_cnf() { SPL_FQDN=dev.example.test SPL_STATE_DIR="$T"; }
  ENV=dev DRY_RUN=1 TENANT_ID=acme BUYER_EMAIL=buyer@example.com \
    STRIPE_API_BASE=https://stripe.example.test do_spl_checkout_stripe_test_buy
)
run_bounded "stripe test buy GET /plan" stripe_buy_run
bounds_are "stripe test buy GET /plan" 10 30

buy="$PROJ_ROOT/src/bash/run/spl-checkout-stripe-test-buy.func.sh"
awk '
  /^  _req\(\)/ { on = 1 }
  on && /^  }$/ { sub(/^  /, ""); print; exit }
  on { sub(/^  /, ""); print }
' "$buy" >"$T/buy-req.sh"
# shellcheck disable=SC1090,SC1091
source "$T/buy-req.sh"
# shellcheck disable=SC2034 # the lifted _req writes $h/body
h="$T"
run_bounded "stripe test buy _req" _req GET https://dev.example.test/api/v1/checkout
bounds_are "stripe test buy _req" 10 30
grep -Fq 'curl -sS --connect-timeout 10 --max-time 30 --config - -w' "$buy" \
  && pass "stripe test buy confirm curl is bounded in source" \
  || fail "stripe test buy confirm curl has no bounds"

printf 'sk_test_stub\n' >"$T/sk"
run_bounded _spl_stripe_api _spl_stripe_api GET /v1/webhook_endpoints https://stripe.example.test "$T/sk"
bounds_are _spl_stripe_api 10 30

_ILT_BIN="$T/ilt-bin"
mkdir -p "$_ILT_BIN"
run_bounded _ilt_fetch _ilt_fetch tool 1.0 abc https://dl.example.test/tool ""
bounds_are _ilt_fetch 30 900
run_bounded _ilt_fetch_sums _ilt_fetch_sums tool 1.0 https://dl.example.test/a https://dl.example.test/sums a ""
bounds_are _ilt_fetch_sums 30 900
grep -q -- '--speed-limit 1024 --speed-time 60' "$STUB_LOG" \
  && pass "lint tool downloads cut only a stalled mirror (--speed-limit/--speed-time)" \
  || fail "lint tool downloads have no --speed-limit/--speed-time"
n=$(grep -c '"${_ILT_CURL_DL_LIMIT\[@\]}"' "$PROJ_ROOT/../csi-spl-iac/src/bash/run/install-lint-tools.func.sh" || true)
[[ "$n" -eq 3 ]] && pass "install-lint-tools bounds its 3 checked downloads" \
  || fail "install-lint-tools _ILT_CURL_DL_LIMIT count is $n"

sai="$PROJ_ROOT/src/bash/run/setup-app-inf.func.sh"
n=$(grep -c 'curl -s --max-time 2' "$sai" || true)
[[ "$n" -eq 4 ]] && pass "setup-app-inf bounds 4 curls with --max-time 2" \
  || fail "setup-app-inf --max-time 2 count is $n"
grep -q 'Polls ~10 s' "$sai" && pass "_sai_check_gcs header names the ~10 s poll" \
  || fail "_sai_check_gcs header missing"

health="$PROJ_ROOT/src/bash/run/spl-db-health.func.sh"
grep -q 'never in argv' "$health" && fail "stale metrics comment remains" \
  || pass "metrics comment no longer says the token is never in argv"
grep -q 'behaviour change' "$health" && pass "metrics comment records the -K move as a behaviour change" \
  || fail "metrics comment missing the behaviour-change note"

gandi="$PROJ_ROOT/lib/bash/funcs/gandi-api.func.sh"
grep -q 'GANDI_MAX_TIME' "$gandi" && grep -q 'exit 28' "$gandi" \
  && pass "usage names GANDI_MAX_TIME and curl exit 28" \
  || fail "gandi usage line missing the knob or exit 28"

roles="$PROJ_ROOT/lib/bash/funcs/spl-db-roles.func.sh"
grep -q 'HTTP:' "$roles" && grep -q 'POST' "$roles" && grep -Fq 'PUT ?name=' "$roles" \
  && pass "spl_db_api_user_set header lists its HTTP calls" \
  || fail "spl_db_api_user_set header does not list the HTTP calls"

# --- round 4 row 14 -----------------------------------------------------------
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-domain-verify.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/spl-wait-for-firebase-domain.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/gh-runner-add.func.sh"
# shellcheck disable=SC1090,SC1091
source "$PROJ_ROOT/src/bash/run/oss-gate.func.sh"

: >"$T/sa-key.json"
# domain_verify_run <LIST|VERIFY|TOKEN>: the action with its gcp helpers stubbed.
domain_verify_run() (
  spl_require_cloud_env() { return 0; }
  # shellcheck disable=SC2034 # read by do_spl_domain_verify
  do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=proj-stub SPL_ORG_APP=csi-spl; }
  yq() { echo example.test; }
  do_gcp_isolated_active_account() { echo sa@example.test; }
  do_gcp_log_identity() { return 0; }
  export LIST=0 VERIFY=0
  [[ "$1" == TOKEN ]] || export "$1=1"
  ENV=dev SPL_SA_KEY="$T/sa-key.json" do_spl_domain_verify
)
declare -A verify_url=([LIST]='/webResource$' [VERIFY]='webResource[?]verificationMethod=DNS_CNAME -d' [TOKEN]='/token -d')
for mode in LIST VERIFY TOKEN; do
  run_bounded "do_spl_domain_verify $mode" domain_verify_run "$mode"
  bounds_are "do_spl_domain_verify $mode" 10 30
  grep -Eq -- "${verify_url[$mode]}" "$STUB_LOG" && pass "do_spl_domain_verify $mode called its own endpoint" \
    || fail "do_spl_domain_verify $mode did not call ${verify_url[$mode]}"
done

run_bounded spl_firebase_domain_poll spl_firebase_domain_poll example.test proj-stub site-stub sa@example.test 0 1
bounds_are spl_firebase_domain_poll 10 30

ghr_tarball_run() (
  sudo() { "$@"; }
  gh() { echo "v9.9.9 $(printf '0%.0s' {1..64})"; }
  unset GH_RUNNER_TARBALL
  GHR_ROOT="$T" ghr_tarball
)
run_bounded ghr_tarball ghr_tarball_run
bounds_are ghr_tarball 30 1800

gitleaks_run() (
  unset GITLEAKS_BIN
  XDG_CACHE_HOME="$T/cache" oss_gitleaks_bin
)
run_bounded oss_gitleaks_bin gitleaks_run
bounds_are oss_gitleaks_bin 30 900

sed -n '/^fetch() {/,/^}/p' "$PROJ_ROOT/src/bash/features/spool-install/install.sh" >"$T/fetch.sh"
# shellcheck disable=SC1090,SC1091
source "$T/fetch.sh"
run_bounded "install.sh fetch" fetch https://dl.example.test/go.tgz "$T/go.tgz"
bounds_are "install.sh fetch" 30 1800

: >"$STUB_LOG"
ghr_tarball_run >/dev/null 2>&1
gitleaks_run >/dev/null 2>&1
fetch https://dl.example.test/go.tgz "$T/go.tgz" >/dev/null 2>&1
n=$(grep -c -- '--speed-limit 1024 --speed-time 60' "$STUB_LOG" || true)
[[ "$n" -eq 3 ]] && pass "row 14 downloads cut only a stalled mirror (--speed-limit/--speed-time)" \
  || fail "row 14 downloads with --speed-limit/--speed-time: $n of 3"

if [[ "$fails" -eq 0 ]]; then
  echo "PASS: all curl-time-bounded.tst.sh assertions"
  exit 0
fi
echo "FAIL: curl-time-bounded $fails check(s)"
exit 1
