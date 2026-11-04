#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_cost_entries (SPL-4824, rdb 0245), with the hub
#          operator call stubbed:
#   1. list (the default) GETs as the SA, no DRY_RUN needed; COST_TYPE and
#      COST_MONTH ride the query
#   2. create and delete are dry by default: print, call nothing
#   3. bad input is refused before any call
#   4. DRY_RUN=0 create POSTs the exact body; delete DELETEs the id
#   5. hub refusals (400, 403) fail
# RED CONTROL: case 2 fails when the dry-run guard is dropped (the call file
# then holds the POST).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev CALLS="$T/calls" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() { echo "hub $1 $2 ${3:-}" >>"$CALLS"; SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"; return 0; }
    do_spl_hub_cost_entries' >"$T/o" 2>&1
}
ID=0a1b2c3d-1111-4222-8333-444455556666
ENTRY='{"id":"'$ID'","type":"cloud","label":"Suite fixture","amount":64.8,"currency":"EUR","period":"2020-01","note":"","created_by":"sa@example.iam.gserviceaccount.com"}'
CREATE=(COST_CMD=create COST_TYPE=cloud "COST_LABEL=Suite fixture" COST_AMOUNT=64.80 COST_CURRENCY=EUR COST_PERIOD=2020-01)
BODY='{"type":"cloud","label":"Suite fixture","amount":64.8,"currency":"EUR","period":"2020-01","note":""}'

# --- 1. reads -------------------------------------------------------------------
run STUB_BODY="{\"entries\":[$ENTRY]}"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/cost-entries ' "$T/calls" && grep -q '^OK dev cost entries: 1' "$T/o" \
  && grep -qxF "  $ID 2020-01 cloud 64.8 EUR Suite fixture" "$T/o" && pass "1. list GETs and prints each entry" || fail "1. list: rc=$rc $(cat "$T/calls" "$T/o")"
run COST_TYPE=cloud COST_MONTH=2026-01 STUB_BODY='{"entries":[]}'; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/cost-entries?type=cloud&month=2026-01 ' "$T/calls" && grep -q '^OK dev cost entries: 0' "$T/o" \
  && pass "1. the type and month filters ride the query" || fail "1. filters: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. dry by default ----------------------------------------------------------
run "${CREATE[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qF "OK DRY_RUN would POST /v1/operator/cost-entries $BODY to https://hub.invalid in dev" "$T/o" \
  && pass "2. create is dry by default: the exact body, 0 calls" || fail "2. dry create: rc=$rc $(cat "$T/calls" "$T/o")"
run COST_CMD=delete COST_ID=$ID; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "DRY_RUN would DELETE /v1/operator/cost-entries/$ID" "$T/o" \
  && pass "2. delete is dry by default, 0 calls" || fail "2. dry delete: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 3. refusals before any call ------------------------------------------------
for bad in COST_TYPE=ai COST_LABEL= "COST_LABEL=   " COST_AMOUNT=0 COST_AMOUNT=-1 COST_AMOUNT=1e3 COST_CURRENCY=eur COST_PERIOD=2020-13 COST_PERIOD=2020-01-01 DRY_RUN=yes; do
  run "${CREATE[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "3. create $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
for bad in "COST_CMD=drop" "COST_CMD=delete COST_ID=1;rm" "COST_MONTH=2020-1" "COST_TYPE=ai"; do
  # shellcheck disable=SC2086 # two assignments on purpose
  run DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "3. $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 4. writes ------------------------------------------------------------------
run "${CREATE[@]}" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ENTRY"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub POST /v1/operator/cost-entries $BODY" "$T/calls" && grep -qF "OK dev cost entry created: $ID 2020-01 cloud 64.8 EUR Suite fixture" "$T/o" \
  && pass "4. create POSTs the body as the SA" || fail "4. create: rc=$rc $(cat "$T/calls" "$T/o")"
run "${CREATE[@]}" "COST_NOTE=invoice 1" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ENTRY"; rc=$?
grep -qF '"note":"invoice 1"' "$T/calls" && pass "4. the note rides the body" || fail "4. note: $(cat "$T/calls")"
run COST_CMD=delete COST_ID=$ID DRY_RUN=0 STUB_CODE=204; rc=$?
[[ $rc -eq 0 ]] && grep -qx "hub DELETE /v1/operator/cost-entries/$ID " "$T/calls" && grep -q "deleted" "$T/o" \
  && pass "4. delete DELETEs the id" || fail "4. delete: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. hub refusals ------------------------------------------------------------
run "${CREATE[@]}" DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_cost_entry","detail":"period must be a month YYYY-MM"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'refused it (400): period must be a month' "$T/o" && pass "5. 400 fails with the hub's detail" || fail "5. 400: rc=$rc $(cat "$T/o")"
run STUB_CODE=403 STUB_BODY='{"error":"forbidden"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'SPOOL_HUB_OPERATOR_EMAILS' "$T/o" && pass "5. 403 names the operator allowlist" || fail "5. 403: rc=$rc $(cat "$T/o")"
run COST_CMD=delete COST_ID=$ID DRY_RUN=0 STUB_CODE=404 STUB_BODY='{"error":"not_found"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'answered 404' "$T/o" && pass "5. a 404 on delete fails" || fail "5. 404: rc=$rc $(cat "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
