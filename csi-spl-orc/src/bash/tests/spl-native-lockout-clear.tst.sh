#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_native_lockout_clear (SPL-6182 defect 5) stays offline on
#          DRY_RUN and on bad input, needs OWNER_GO for a prd write, and a
#          real run calls `spool hub-clear-lockout` once with the proxy DSN
#          and the lower-cased email, never logging the email. The cloud
#          helpers (cnf, SA pin, proxy, host binary) are stubbed: each call is
#          recorded, an absent call is absent.
#   1. DRY_RUN (the default) prints the plan and calls nothing.
#   2. bad ENV / email are refused before any call.
#   3. ENV=prd DRY_RUN=0 without OWNER_GO is refused before any call.
#   4. ENV=dev DRY_RUN=0 runs the CLI once; the email is not in the log.
#   5. a failing CLI is a FATAL, rc 1, the email masked.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

cat >"$T/spool" <<'STUB'
#!/usr/bin/env bash
printf 'spool' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ "${STUB_SPOOL_RC:-0}" == 0 ]] || { echo "pg: connection refused for ${5:-}" >&2; exit "$STUB_SPOOL_RC"; }
echo '{"cleared":3,"status":"cleared"}'
STUB
chmod +x "$T/spool"

in_orc() {
  : >"$T/calls.log"
  env -u DRY_RUN -u LOCKOUT_EMAIL -u OWNER_GO -u STUB_SPOOL_RC \
    PROJ_PATH="$PROJ_ROOT" STUB_LOG="$T/calls.log" STUB_SPOOL="$T/spool" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-native-lockout-clear.func.sh"
    do_spl_cloud_cnf() { echo cnf >>"$STUB_LOG"; SPL_SQL_CONN=p:r:i; SPL_CNF=x; }
    do_gcp_pin_account() { echo pin >>"$STUB_LOG"; GCP_ACCOUNT=sa@example.iam; }
    do_gcp_require_live_account() { :; }
    spl_host_spool() { SPL_SPOOL="$STUB_SPOOL"; }
    spl_via_proxy() { echo proxy >>"$STUB_LOG"; SPL_PROXY_DSN=postgres://u@127.0.0.1:1/db "$@"; }
    do_spl_native_lockout_clear' >"$T/out" 2>&1 </dev/null
}

FUNC="$PROJ_ROOT/src/bash/run/spl-native-lockout-clear.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"

in_orc LOCKOUT_EMAIL=Person@Example.com; rc=$?
if (( rc == 0 )) && grep -q 'OK DRY_RUN would clear' "$T/out" && ! grep -q spool "$T/calls.log" && ! grep -qi 'person@example' "$T/out"; then
  pass "1. DRY_RUN is the default: plan only, no CLI, no email in the log"
else fail "1. DRY_RUN rc=$rc: $(cat "$T/out") calls: $(cat "$T/calls.log")"; fi

for c in "ENV=stg LOCKOUT_EMAIL=a@example.com DRY_RUN=0" "LOCKOUT_EMAIL=not-an-email DRY_RUN=0" "LOCKOUT_EMAIL= DRY_RUN=0" "LOCKOUT_EMAIL=a@example.com DRY_RUN=2"; do
  # shellcheck disable=SC2086 # word-split on purpose: one env assignment per word
  in_orc $c; rc=$?
  if (( rc != 0 )) && [[ ! -s "$T/calls.log" ]] && grep -q FATAL "$T/out"; then
    pass "2. refused before any call: $c"
  else fail "2. not refused: $c rc=$rc: $(cat "$T/out") calls: $(cat "$T/calls.log")"; fi
done

in_orc ENV=prd LOCKOUT_EMAIL=a@example.com DRY_RUN=0; rc=$?
if (( rc != 0 )) && [[ ! -s "$T/calls.log" ]] && grep -q 'needs OWNER_GO' "$T/out"; then
  pass "3. ENV=prd DRY_RUN=0 without OWNER_GO is refused before any call"
else fail "3. prd without OWNER_GO rc=$rc: $(cat "$T/out") calls: $(cat "$T/calls.log")"; fi
in_orc ENV=prd LOCKOUT_EMAIL=a@example.com OWNER_GO=deadbeef DRY_RUN=0; rc=$?
if (( rc == 0 )) && grep -q 'owner go deadbeef' "$T/out"; then
  pass "3. CONTROL: with OWNER_GO the prd clear runs"
else fail "3. CONTROL: prd with OWNER_GO rc=$rc: $(cat "$T/out")"; fi

in_orc LOCKOUT_EMAIL=Person@Example.com DRY_RUN=0; rc=$?
if (( rc == 0 )) && [[ "$(grep -c '^spool' "$T/calls.log")" == 1 ]] &&
   grep -qF 'spool [hub-clear-lockout] [--db] [postgres://u@127.0.0.1:1/db] [--email] [person@example.com]' "$T/calls.log" &&
   grep -q '"cleared":3' "$T/out" && ! grep -qi 'person@example' "$T/out"; then
  pass "4. DRY_RUN=0: one CLI call through the proxy, email lower-cased, not logged"
else fail "4. real run rc=$rc: $(cat "$T/out") calls: $(cat "$T/calls.log")"; fi

in_orc LOCKOUT_EMAIL=person@example.com DRY_RUN=0 STUB_SPOOL_RC=1; rc=$?
if (( rc == 1 )) && grep -q 'FATAL lockout clear on dev failed' "$T/out" && grep -q '<email>' "$T/out" && ! grep -q 'person@example' "$T/out"; then
  pass "5. a failing CLI is FATAL rc 1, the email masked"
else fail "5. failing CLI rc=$rc: $(cat "$T/out")"; fi

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
