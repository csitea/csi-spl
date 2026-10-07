#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_file_door_probe (CLE-34962 live file read door proof) stays
#          offline in its dry run and refuses bad input, with no cloud call.
#   1. dry run: no spool / gcloud / curl call; names both boxes and the codes
#   2. refusals: box-wui, same box twice, bad agent, bad tenant, bad DRY_RUN
#   3. DRY_RUN=0 without pinned boxes stops before any spool call and names
#      do_spl_box_msg_probe
#   4. CONTROL: the stub log records a call when one is made
#   5. past the specs/061 legacy cutoff (SPOOL_NOW) the default PROBE_AGENT
#      passes the id check and is c-903, not the retired ORC-1. CONTROL: an
#      explicit PROBE_AGENT=ORC-1 is refused then
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_file_door_probe in_orc TENANT_ID=t1 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was touched" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "as box-orc-probe (want 200) and as box-orc-stranger (want 404)" <<<"$out" && pass "dry run names both boxes and the codes" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "PROBE_BOX=box-wui" "STRANGER_BOX=box-wui" "STRANGER_BOX=box-orc-probe" "PROBE_AGENT=orc-1" "TENANT_ID=T1" "DRY_RUN=2"; do
  if SNIPPET=do_spl_file_door_probe in_orc TENANT_ID=t1 "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    pass "refuses $bad"
  fi
done

# --- 3. unpinned boxes: stops before spool -------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_file_door_probe in_orc TENANT_ID=t1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "do_spl_box_msg_probe first" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "unpinned: refused, no spool call" \
  || fail "unpinned: rc=$rc calls=$(cat "$T/calls.log") out=$out"
mkdir -p "$T/state/dev/probe/t1/box-orc-probe" && : >"$T/state/dev/probe/t1/box-orc-probe/pinned"
out=$(SNIPPET=do_spl_file_door_probe in_orc TENANT_ID=t1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "box-orc-stranger is not pinned" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "stranger unpinned: refused, no spool call" \
  || fail "stranger unpinned: rc=$rc calls=$(cat "$T/calls.log") out=$out"

# --- 4. CONTROL --------------------------------------------------------------------------
SNIPPET='spool version' in_orc >/dev/null 2>&1
grep -q '^spool version' "$T/calls.log" && pass "CONTROL: stub records calls" || fail "CONTROL: stub recorded nothing"

# --- 5. default agent past the legacy cutoff ---------------------------------------------
LATE=2026-10-07T07:45:00Z
out=$(SNIPPET=do_spl_file_door_probe in_orc SPOOL_NOW=$LATE TENANT_ID=t1 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was touched" <<<"$out" && pass "late: the default PROBE_AGENT passes the 061 id check" \
  || fail "late: default PROBE_AGENT refused: rc=$rc $out"
grep -q "from c-903@box-orc-probe " <<<"$out" && pass "late: the default PROBE_AGENT is c-903" || fail "late: default agent not c-903: $out"
SNIPPET=do_spl_file_door_probe in_orc SPOOL_NOW=$LATE TENANT_ID=t1 PROBE_AGENT=ORC-1 >"$T/o" 2>&1 \
  && fail "late: accepts the retired ORC-1" || pass "late: CONTROL refuses the retired ORC-1"

(( fails == 0 )) && echo "OK file-door-probe: all checks passed" || { echo "file-door-probe: $fails failure(s)"; exit 1; }
