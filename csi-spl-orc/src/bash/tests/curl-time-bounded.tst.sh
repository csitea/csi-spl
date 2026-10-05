#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the curl calls in this lane are time-bounded. A curl stub first on
#          PATH logs its argv and exits 28. Call _gandi_api,
#          spl_db_health_metrics, spl_db_api_user_set and _req (nested in
#          do_spl_checkout_fake_buy; the test lifts that body and calls it).
#          Every logged line has --max-time or -m . CONTROL: the stub exits
#          28 and each caller returns non-zero.
#          The setup-app-inf probes are pinned in source: calling them sleeps
#          through the readiness loop.
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

if [[ "$fails" -eq 0 ]]; then
  echo "PASS: all curl-time-bounded.tst.sh assertions"
  exit 0
fi
echo "FAIL: curl-time-bounded $fails check(s)"
exit 1
