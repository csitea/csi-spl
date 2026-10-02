#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_backfill_probe (SPL-987 live back-fill proof) stays offline in
#          its dry run and refuses bad input before any cloud or spool call.
#   1. dry run: no spool / gcloud / curl call; names the box, the posts and the
#      invited agent
#   2. refusals: box-desk / box-wui, poster == target, a human id, 0 or 21
#      posts, bad tenant, bad DRY_RUN
#   3. DRY_RUN=0 without a root key stops before any spool call
#   4. CONTROL: a spool call made through the stub IS recorded
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_backfill_probe in_orc TENANT_ID=t1 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was sent" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "seat PRB-9871, post 3 times, invite PRB-9872" <<<"$out" && grep -q "pin box-bfprobe under t1" <<<"$out" &&
  pass "dry run names the box, the posts and the invited agent" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "PROBE_BOX=box-wui" "PROBE_BOX=box-desk" "PROBE_AGENT=PRB-9871" "PROBE_AGENT=HUM-4" "PROBE_POSTER=prb-1" \
  "PROBE_POSTS=0" "PROBE_POSTS=21" "TENANT_ID=T1" "DRY_RUN=2" "PROBE_WAIT_SECS=soon"; do
  if SNIPPET=do_spl_backfill_probe in_orc TENANT_ID=t1 "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    pass "refuses $bad"
  fi
done

# --- 3. no root key: stops before any call -----------------------------------------------
: >"$T/calls.log"
if SNIPPET=do_spl_backfill_probe in_orc TENANT_ID=t1 DRY_RUN=0 ROOT_KEY="$T/none" >"$T/o" 2>&1; then
  fail "DRY_RUN=0 without a root key succeeded: $(cat "$T/o")"
else
  grep -q "FATAL ROOT_KEY" "$T/o" && [[ ! -s "$T/calls.log" ]] && pass "no root key: FATAL before any call" \
    || fail "no root key: $(cat "$T/o") calls=$(cat "$T/calls.log")"
fi

# --- 4. CONTROL: the stub records a call -------------------------------------------------
: >"$T/calls.log"
SNIPPET='spool keygen' in_orc >/dev/null 2>&1
grep -q "spool keygen" "$T/calls.log" && pass "CONTROL: a spool call is recorded" || fail "CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all backfill-probe.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
