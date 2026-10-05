#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_workspace_docs_probe (spec 075 live workspace docs proof)
#          stays offline in its dry run and refuses bad input, with no cloud call.
#   1. dry run: no spool / curl call; names the anonymous check and the verbs
#   2. refusals: box-wui, bad box, bad tenant, bad DRY_RUN
#   3. DRY_RUN=0 without a desk seat stops before any spool / curl call
#   4. CONTROL: the stub log records a call when one is made
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_workspace_docs_probe in_orc TENANT_ID=t1 DESK_BOX=box-desk 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was touched" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "want not workspace_docs_off" <<<"$out" && grep -q "doc-write + doc-read" <<<"$out" && pass "dry run names the off check and the verbs" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "DESK_BOX=box-wui" "DESK_BOX=Box_1" "TENANT_ID=T1" "DRY_RUN=2"; do
  if SNIPPET=do_spl_workspace_docs_probe in_orc TENANT_ID=t1 DESK_BOX=box-desk "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    pass "refuses $bad"
  fi
done

# --- 3. no seat: stops before spool / curl ---------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_workspace_docs_probe in_orc TENANT_ID=t1 DESK_BOX=box-desk DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "do_spl_desk_up first" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "no seat: refused, no call" \
  || fail "no seat: rc=$rc calls=$(cat "$T/calls.log") out=$out"

# --- 4. CONTROL --------------------------------------------------------------------------
SNIPPET='spool version' in_orc >/dev/null 2>&1
grep -q '^spool version' "$T/calls.log" && pass "CONTROL: stub records calls" || fail "CONTROL: stub recorded nothing"

(( fails == 0 )) && echo "OK workspace-docs-probe: all checks passed" || { echo "workspace-docs-probe: $fails failure(s)"; exit 1; }
