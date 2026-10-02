#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wui_perf_flow_events (CLE-77914) - the read-only Flow + Event
#          log timing e2e on a deployed WUI - refuses bad input before Chrome
#          starts, refuses the owner's prd t1, and hands the timing script the
#          tenant's own host, the test member and a kept browser profile.
#   1. refusals: bad tenant, prd t1, PF_N out of 1..50, unknown profile,
#      bad PF_COLD_CACHE - each FATAL and named, node never runs
#   2. defaults: dev -> t1 at https://<fqdn>, prd -> e2e at https://e2e.<fqdn>,
#      the member email read from <state>/m3-e2e/<tenant>/human-email
#   3. no password file -> FATAL naming do_spl_m3_e2e, node never runs
#   4. CONTROL: a node call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub"
# node records its environment (never the password: only the file's path)
printf '#!/bin/sh\necho "node $* BASE=$BASE TENANT=$TENANT EMAIL=$EMAIL N=$N PROFILES=$PROFILES UDD=$USER_DATA_DIR PW=$PW_FILE" >>"$STUB_LOG"\nexit 0\n' >"$T/stub/node"
for b in gcloud curl docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
printf '#!/bin/sh\nexit 0\n' >"$T/stub/chrome"
chmod +x "$T/stub/"*

in_orc() {
  : >"$T/calls.log"
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" STUB_LOG="$T/calls.log" T="$T" \
    PATH="$T/stub:$PATH" CHROME_PATH="$T/stub/chrome" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; [[ $ENV == prd ]] && SPL_FQDN=example.test || SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
    do_spl_wui_perf_flow_events'
}
seat() { mkdir -p "$T/state/$1/m3-e2e/$2"; echo x >"$T/state/$1/m3-e2e/$2/pw-human"; [[ -z "${3:-}" ]] || echo "$3" >"$T/state/$1/m3-e2e/$2/human-email"; }

# --- 1. refusals ------------------------------------------------------------------
seat dev t1; seat prd t1; seat prd e2e
for kv in "ENV=dev TENANT_ID=T1" "ENV=prd TENANT_ID=t1" "ENV=dev PF_N=0" "ENV=dev PF_N=51" "ENV=dev PF_N=x" \
          "ENV=dev PF_PROFILES=d1440,phone" "ENV=dev PF_COLD_CACHE=2"; do
  # shellcheck disable=SC2086
  out=$(in_orc $kv 2>&1) && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL <<<"$out" && pass "$kv: the refusal is FATAL and named" || fail "$kv: refusal text: $out"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: node never ran" || fail "$kv: called: $(cat "$T/calls.log")"
done
grep -q "owner's tenant" <<<"$(in_orc ENV=prd TENANT_ID=t1 2>&1)" && pass "prd t1 refusal names why" || fail "prd t1 refusal text"

# --- 2. defaults ------------------------------------------------------------------
in_orc ENV=dev PF_N=2 >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://dev.example.test TENANT=t1 EMAIL=m3-e2e-human@example.com N=2 PROFILES=d1440,m390' <<<"$c" &&
  pass "dev: t1 at the env host, the default member, n and both profiles" || fail "dev defaults: $c"
grep -q "UDD=$T/state/dev/perf-flow-events/t1/chrome-profile" <<<"$c" && pass "dev: a kept browser profile per tenant" || fail "profile dir: $c"
grep -q 'perf-flow-events.timing.mjs' <<<"$c" && pass "CONTROL: the stub records the node call" || fail "CONTROL: no node call: $c"
seat prd e2e sys+e2e@example.test
in_orc ENV=prd >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://e2e.example.test TENANT=e2e EMAIL=sys+e2e@example.test N=10' <<<"$c" &&
  pass "prd: e2e at its tenant host, the member from human-email, n=10" || fail "prd defaults: $c"

# --- 3. no password ---------------------------------------------------------------
out=$(in_orc ENV=dev TENANT_ID=nopw 2>&1) && fail "no pw: ran" || pass "no pw: refused"
grep -q do_spl_m3_e2e <<<"$out" && pass "no pw: names do_spl_m3_e2e" || fail "no pw text: $out"
[[ ! -s "$T/calls.log" ]] && pass "no pw: node never ran" || fail "no pw: called"

((fails == 0)) && echo "OK spl-wui-perf-flow-events: all checks passed" || { echo "FAIL spl-wui-perf-flow-events: $fails check(s)"; exit 1; }
