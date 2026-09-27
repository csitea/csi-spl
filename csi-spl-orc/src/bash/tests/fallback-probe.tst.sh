#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_fallback_probe (SPL-997 live fallback proof) stays offline in
#          its dry run and refuses bad input before any cloud or spool call.
#   1. dry run: no spool / gcloud / curl call; names the box, both agents and
#      both channels
#   2. refusals: t1 (a real tenant's list), box-desk / box-wui, responder ==
#      member, a human id, bad tenant, bad DRY_RUN, bad wait
#   3. DRY_RUN=0 without a root key stops before any spool call
#   4. CONTROL: a spool call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud curl docker spool psql; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_fallback_probe in_orc TENANT_ID=e2e 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was sent" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "pin box-fbprobe under e2e .* announcing PRB-9973 and PRB-9974" <<<"$out" &&
  grep -q "set e2e's responders to PRB-9973, post into #fb-probe-[0-9]* (no agent), then #fb-ctrl-[0-9]* (PRB-9974 seated)" <<<"$out" &&
  pass "dry run names the box, both agents and both channels" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "TENANT_ID=t1" "PROBE_BOX=box-wui" "PROBE_BOX=box-desk" "PROBE_MEMBER=PRB-9973" "PROBE_RESPONDER=HUM-4" \
  "PROBE_MEMBER=prb-1" "TENANT_ID=E2E" "DRY_RUN=2" "PROBE_WAIT_SECS=soon" "PROBE_WAIT_SECS=0"; do
  : >"$T/calls.log"
  if SNIPPET=do_spl_fallback_probe in_orc TENANT_ID=e2e "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    [[ ! -s "$T/calls.log" ]] && pass "refuses $bad before any call" || fail "refuses $bad but called: $(cat "$T/calls.log")"
  fi
done

# --- 3. no root key: stops before any call -----------------------------------------------
: >"$T/calls.log"
if SNIPPET=do_spl_fallback_probe in_orc TENANT_ID=e2e DRY_RUN=0 ROOT_KEY="$T/none" >"$T/o" 2>&1; then
  fail "DRY_RUN=0 without a root key succeeded: $(cat "$T/o")"
else
  grep -q "FATAL ROOT_KEY" "$T/o" && [[ ! -s "$T/calls.log" ]] && pass "no root key: FATAL before any call" \
    || fail "no root key: $(cat "$T/o") calls=$(cat "$T/calls.log")"
fi

# --- 4. CONTROL: the stub records a call -------------------------------------------------
: >"$T/calls.log"
SNIPPET='spool keygen' in_orc >/dev/null 2>&1
grep -q "spool keygen" "$T/calls.log" && pass "CONTROL: a spool call is recorded" || fail "CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all fallback-probe.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
