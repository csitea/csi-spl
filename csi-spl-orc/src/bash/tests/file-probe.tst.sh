#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_file_probe (027 T020 live upload proof) stays offline in
#          its dry run and refuses bad input, with no cloud call.
#   1. dry run: no spool / gcloud / curl call; names size, box and tenant hub
#   2. refusals: PROBE_FILE_MIB 0 / 33 / non-numeric, box-wui, bad agent, bad
#      tenant
#   3. DRY_RUN=0 without a pinned probe box stops before any spool call and
#      names do_spl_box_msg_probe
#   4. CONTROL: the stub log records a call when one is made
#   5. past the specs/061 legacy cutoff (SPOOL_NOW) the default PROBE_AGENT
#      passes the id check and is c-902, not the retired ORC-1. CONTROL: an
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
out=$(SNIPPET=do_spl_box_file_probe in_orc TENANT_ID=t1 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was touched" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "upload 8 MiB .*@box-orc-probe to https://[^ ]* as tenant t1 " <<<"$out" && ! grep -q "https://t1\." <<<"$out" && pass "dry run names 8 MiB default, box, the API host and tenant t1 (specs/026: no tenant host)" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "PROBE_FILE_MIB=0" "PROBE_FILE_MIB=33" "PROBE_FILE_MIB=8x" "PROBE_BOX=box-wui" "PROBE_AGENT=orc-1" "TENANT_ID=T1"; do
  if SNIPPET=do_spl_box_file_probe in_orc TENANT_ID=t1 "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    pass "refuses $bad"
  fi
done

# --- 3. unpinned box: stops before spool ---------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_box_file_probe in_orc TENANT_ID=t1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "do_spl_box_msg_probe first" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "unpinned: refused, no spool call" \
  || fail "unpinned: rc=$rc calls=$(cat "$T/calls.log") out=$out"

# --- 4. CONTROL --------------------------------------------------------------------------
SNIPPET='spool version' in_orc >/dev/null 2>&1
grep -q '^spool version' "$T/calls.log" && pass "CONTROL: stub records calls" || fail "CONTROL: stub recorded nothing"

# --- 5. default agent past the legacy cutoff ---------------------------------------------
LATE=2026-10-07T07:45:00Z
out=$(SNIPPET=do_spl_box_file_probe in_orc SPOOL_NOW=$LATE TENANT_ID=t1 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was touched" <<<"$out" && pass "late: the default PROBE_AGENT passes the 061 id check" \
  || fail "late: default PROBE_AGENT refused: rc=$rc $out"
grep -q "from c-902@box-orc-probe " <<<"$out" && pass "late: the default PROBE_AGENT is c-902" || fail "late: default agent not c-902: $out"
SNIPPET=do_spl_box_file_probe in_orc SPOOL_NOW=$LATE TENANT_ID=t1 PROBE_AGENT=ORC-1 >"$T/o" 2>&1 \
  && fail "late: accepts the retired ORC-1" || pass "late: CONTROL refuses the retired ORC-1"

(( fails == 0 )) && echo "OK file-probe: all checks passed" || { echo "file-probe: $fails failure(s)"; exit 1; }
