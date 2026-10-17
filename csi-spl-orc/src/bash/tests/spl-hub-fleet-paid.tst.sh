#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_fleet_paid (SPL-2342, rdb 0205), with the hub operator
#          call stubbed:
#   1. list (the default) and effective GET as the SA, no DRY_RUN needed;
#      FROM / TO ride the query
#   2. create and delete are dry by default: print, call nothing
#   3. bad input is refused before any call
#   4. DRY_RUN=0 create POSTs the exact body; delete DELETEs the id
#   5. hub refusals (400, 403) fail
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
    spl_hub_operator_call() { echo "hub $1 $2 ${3:-}" >>"$CALLS"; SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"; }
    do_spl_hub_fleet_paid' >"$T/o" 2>&1
}
ID=0a1b2c3d-1111-4222-8333-444455556666
ITEM='{"id":"'$ID'","vendor":"agy","kind":"topup","plan_label":"fixture","quantity":1,"amount":1,"currency":"USD","period_start":"2020-01-01","period_end":"2020-01-02","created_by":"sa@example.iam.gserviceaccount.com"}'
CREATE=(PAID_CMD=create VENDOR=agy KIND=topup PLAN_LABEL=fixture AMOUNT=1 CURRENCY=USD PERIOD_START=2020-01-01 PERIOD_END=2020-01-02)
BODY='{"vendor":"agy","kind":"topup","plan_label":"fixture","quantity":1,"amount":1,"currency":"USD","period_start":"2020-01-01","period_end":"2020-01-02","note":""}'

# --- 1. reads -------------------------------------------------------------------
run STUB_BODY="{\"items\":[$ITEM]}"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/fleet-tokens/paid ' "$T/calls" && grep -q '^OK dev paid items: 1' "$T/o" \
  && grep -qF "$ID agy topup fixture 1 x 1 USD [2020-01-01, 2020-01-02)" "$T/o" && pass "1. list GETs and prints each item" || fail "1. list: rc=$rc $(cat "$T/calls" "$T/o")"
run STUB_BODY='{"items":[]}'; rc=$?
[[ $rc -eq 0 ]] && grep -q '^OK dev paid items: 0' "$T/o" && pass "1. an empty list reads 0" || fail "1. empty: rc=$rc $(cat "$T/o")"
run PAID_CMD=effective FROM=2026-09-01 TO=2026-10-01 STUB_BODY='{"from":"2026-09-01","to":"2026-10-01","days":30,"vendors":[{"vendor":"agy","status":"not_metered","tokens":0,"cache_read":0,"paid_usd":20,"paid_per_day_usd":0.6667,"effective_usd_per_mtok":null,"list_usd_per_mtok":null}]}'; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/fleet-tokens/effective?from=2026-09-01&to=2026-10-01 ' "$T/calls" \
  && grep -q 'agy not_metered tokens=0 cache_read=0 paid_usd=20 per_day=0.6667' "$T/o" && pass "1. effective GETs with from and to" || fail "1. effective: rc=$rc $(cat "$T/calls" "$T/o")"
run PAID_CMD=effective STUB_BODY='{"from":"a","to":"b","days":30,"vendors":[]}'; rc=$?
grep -qx 'hub GET /v1/operator/fleet-tokens/effective ' "$T/calls" && pass "1. effective without FROM / TO sends no query" || fail "1. bare effective: $(cat "$T/calls")"

# --- 2. dry by default ----------------------------------------------------------
run "${CREATE[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -qF "OK DRY_RUN would POST /v1/operator/fleet-tokens/paid $BODY to https://hub.invalid in dev" "$T/o" \
  && pass "2. create is dry by default: the exact body, 0 calls" || fail "2. dry create: rc=$rc $(cat "$T/calls" "$T/o")"
run PAID_CMD=delete PAID_ID=$ID; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "DRY_RUN would DELETE /v1/operator/fleet-tokens/paid/$ID" "$T/o" \
  && pass "2. delete is dry by default, 0 calls" || fail "2. dry delete: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 3. refusals before any call ------------------------------------------------
for bad in VENDOR=gpt KIND=gift PLAN_LABEL= AMOUNT=0 AMOUNT=-1 AMOUNT=1e3 CURRENCY=usd PERIOD_END=2020-01-01 PERIOD_START=2020-1-1 QUANTITY=0 DRY_RUN=yes; do
  run "${CREATE[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "3. create $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
for bad in "PAID_CMD=drop" "PAID_CMD=delete PAID_ID=1;rm" "PAID_CMD=effective FROM=yesterday"; do
  # shellcheck disable=SC2086 # two assignments on purpose
  run DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "3. $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 4. writes ------------------------------------------------------------------
run "${CREATE[@]}" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ITEM"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub POST /v1/operator/fleet-tokens/paid $BODY" "$T/calls" && grep -q "^OK dev paid item created: $ID (agy topup fixture)" "$T/o" \
  && pass "4. create POSTs the body as the SA" || fail "4. create: rc=$rc $(cat "$T/calls" "$T/o")"
run "${CREATE[@]}" QUANTITY=3 AMOUNT=200.5 NOTE="three seats" DRY_RUN=0 STUB_CODE=201 STUB_BODY="$ITEM"; rc=$?
grep -qF '"quantity":3,"amount":200.5' "$T/calls" && grep -qF '"note":"three seats"' "$T/calls" \
  && pass "4. quantity, a decimal amount and the note ride the body" || fail "4. qty: $(cat "$T/calls")"
run PAID_CMD=delete PAID_ID=$ID DRY_RUN=0 STUB_CODE=204; rc=$?
[[ $rc -eq 0 ]] && grep -qx "hub DELETE /v1/operator/fleet-tokens/paid/$ID " "$T/calls" && grep -q "deleted" "$T/o" \
  && pass "4. delete DELETEs the id" || fail "4. delete: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. hub refusals ------------------------------------------------------------
run "${CREATE[@]}" DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_paid_item","detail":"currency must be USD or one the hub holds an exchange rate for"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'refused it (400): currency must be USD' "$T/o" && pass "5. 400 fails with the hub's detail" || fail "5. 400: rc=$rc $(cat "$T/o")"
run STUB_CODE=403 STUB_BODY='{"error":"forbidden"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'SPOOL_HUB_OPERATOR_EMAILS' "$T/o" && pass "5. 403 names the operator allowlist" || fail "5. 403: rc=$rc $(cat "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
