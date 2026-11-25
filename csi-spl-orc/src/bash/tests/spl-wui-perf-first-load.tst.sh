#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wui_perf_first_load (CLE-77934) - the read-only first-load
#          runtime timing e2e on a deployed WUI - refuses bad input before Chrome
#          starts, refuses the owner's prd t1, and hands the timing script the
#          tenant's own host, the test member and a kept browser profile.
#   1. refusals: bad tenant, prd t1, PF_N out of 1..50, unknown profile,
#      bad PF_COLD_CACHE, bad FL_CPU_PROFILE - each FATAL and named, node never runs
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
printf '#!/bin/sh\necho "node $* BASE=$BASE TENANT=$TENANT EMAIL=$EMAIL N=$N PROFILES=$PROFILES CPU=$CPU_PROFILE UDD=$USER_DATA_DIR PW=$PW_FILE" >>"$STUB_LOG"\nexit 0\n' >"$T/stub/node"
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
    do_spl_wui_perf_first_load'
}
seat() { mkdir -p "$T/state/$1/m3-e2e/$2"; echo x >"$T/state/$1/m3-e2e/$2/pw-human"; [[ -z "${3:-}" ]] || echo "$3" >"$T/state/$1/m3-e2e/$2/human-email"; }

# --- 1. refusals ------------------------------------------------------------------
seat dev t1; seat prd t1; seat prd e2e
for kv in "ENV=dev TENANT_ID=T1" "ENV=prd TENANT_ID=t1" "ENV=dev PF_N=0" "ENV=dev PF_N=51" "ENV=dev PF_N=x" \
          "ENV=dev PF_PROFILES=d1440,phone" "ENV=dev PF_COLD_CACHE=2" "ENV=dev FL_CPU_PROFILE=yes"; do
  # shellcheck disable=SC2086
  out=$(in_orc $kv 2>&1) && fail "$kv: ran" || pass "$kv: refused"
  grep -q FATAL <<<"$out" && pass "$kv: the refusal is FATAL and named" || fail "$kv: refusal text: $out"
  [[ ! -s "$T/calls.log" ]] && pass "$kv: node never ran" || fail "$kv: called: $(cat "$T/calls.log")"
done
grep -q "owner's tenant" <<<"$(in_orc ENV=prd TENANT_ID=t1 2>&1)" && pass "prd t1 refusal names why" || fail "prd t1 refusal text"

# --- 2. defaults ------------------------------------------------------------------
in_orc ENV=dev PF_N=2 >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://dev.example.test TENANT=t1 EMAIL=m3-e2e-human@example.com N=2 PROFILES=d1440,m390 CPU=0' <<<"$c" &&
  pass "dev: t1 at the env host, the default member, n and both profiles" || fail "dev defaults: $c"
grep -q "UDD=$T/state/dev/perf-first-load/t1/chrome-profile" <<<"$c" && pass "dev: a kept browser profile per tenant" || fail "profile dir: $c"
grep -q 'perf-first-load.timing.mjs' <<<"$c" && pass "CONTROL: the stub records the node call" || fail "CONTROL: no node call: $c"
seat prd e2e sys+e2e@example.test
in_orc ENV=dev FL_CPU_PROFILE=1 >/dev/null 2>&1
grep -q 'CPU=1' "$T/calls.log" && pass "FL_CPU_PROFILE=1 reaches the timing script" || fail "cpu flag: $(cat "$T/calls.log")"
in_orc ENV=prd >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://e2e.example.test TENANT=e2e EMAIL=sys+e2e@example.test N=10' <<<"$c" &&
  pass "prd: e2e at its tenant host, the member from human-email, n=10" || fail "prd defaults: $c"

# --- 3. no password ---------------------------------------------------------------
out=$(in_orc ENV=dev TENANT_ID=nopw 2>&1) && fail "no pw: ran" || pass "no pw: refused"
grep -q do_spl_m3_e2e <<<"$out" && pass "no pw: names do_spl_m3_e2e" || fail "no pw text: $out"
[[ ! -s "$T/calls.log" ]] && pass "no pw: node never ran" || fail "no pw: called"

# --- 4. r99-02 one copy and standalone lazy-source --------------------------------
for f in spl-wui-perf-first-load.func.sh spl-wui-perf-first-load-net.func.sh; do
  fp="$PROJ_ROOT/src/bash/run/$f"
  own="$(grep -nE "FATAL no password for |FATAL no Chrome at |FATAL no (timing|first-load) e2e at " "$fp" || true)"
  [[ -z "$own" ]] && grep -q "spl_pf_env " "$fp" \
    && pass "4. one copy: $f delegates env setup to spl_pf_env" || fail "4. one copy $f: own=[$own]"
done
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" T="$T" ENV=dev TENANT_ID=nopw CHROME_PATH="$T/stub/chrome" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  do_spl_cloud_cnf(){ SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
  source "$PROJ_PATH/src/bash/run/spl-wui-perf-first-load.func.sh"
  do_spl_wui_perf_first_load' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no password for "* && "$out" != *"command not found"* ]] \
  && pass "4. lazy load: spl-wui-perf-first-load.func.sh loads spl_pf_env standalone" || fail "4. lazy first-load: rc=$rc $out"
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" T="$T" ENV=dev TENANT_ID=nopw CHROME_PATH="$T/stub/chrome" bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  do_spl_cloud_cnf(){ SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
  source "$PROJ_PATH/src/bash/run/spl-wui-perf-first-load-net.func.sh"
  do_spl_wui_perf_first_load_net' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no password for "* && "$out" != *"command not found"* ]] \
  && pass "4. lazy load: spl-wui-perf-first-load-net.func.sh loads spl_pf_env standalone" || fail "4. lazy first-load-net: rc=$rc $out"
in_orc ENV=dev PF_WUI_URL=https://o.example.test PF_EMAIL=o@example.test >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://o.example.test .*EMAIL=o@example.test' <<<"$c" \
  && pass "4. first-load honors PF_WUI_URL and PF_EMAIL overrides" || fail "4. first-load overrides: $c"
out=$(in_orc APP_PATH="$T/no-wui" ENV=dev 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no timing e2e at $T/no-wui/csi-spl-wui/tests/e2e/perf-first-load.timing.mjs"* && ! -s "$T/calls.log" ]] \
  && pass "4. first-load missing script prints timing label and never calls node" || fail "4. first-load script label: rc=$rc $out"
: >"$T/calls.log"
env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" STUB_LOG="$T/calls.log" T="$T" PATH="$T/stub:$PATH" CHROME_PATH="$T/stub/chrome" \
  ENV=dev PF_WUI_URL=https://wrong.example.test PF_EMAIL=wrong@example.test PFL_WUI_URL=https://o.example.test PFL_EMAIL=o@example.test bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf(){ SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
  do_spl_wui_perf_first_load_net' >/dev/null 2>&1; c=$(cat "$T/calls.log")
grep -q 'BASE=https://o.example.test .*EMAIL=o@example.test' <<<"$c" \
  && pass "4. first-load-net honors PFL_WUI_URL and PFL_EMAIL overrides" || fail "4. first-load-net overrides: $c"
: >"$T/calls.log"
out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/no-wui" STUB_LOG="$T/calls.log" T="$T" PATH="$T/stub:$PATH" CHROME_PATH="$T/stub/chrome" ENV=dev bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf(){ SPL_ORG_APP=csi-spl; SPL_STATE_DIR="$T/state/$ENV"; SPL_FQDN=dev.example.test; mkdir -p "$SPL_STATE_DIR"; }
  do_spl_wui_perf_first_load_net' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no first-load e2e at $T/no-wui/csi-spl-wui/tests/e2e/perf-first-load-net.timing.mjs"* && ! -s "$T/calls.log" ]] \
  && pass "4. first-load-net missing script prints first-load label and never calls node" || fail "4. first-load-net script label: rc=$rc $out"

((fails == 0)) && echo "OK spl-wui-perf-first-load: all checks passed" || { echo "FAIL spl-wui-perf-first-load: $fails check(s)"; exit 1; }
