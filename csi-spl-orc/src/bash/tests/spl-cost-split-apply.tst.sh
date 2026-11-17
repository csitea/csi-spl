#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cost_split_apply (SPL-5768, spec 143 costs-allocation.md
#          section 7), with the hub operator call stubbed:
#   1. the dry run (default) reads (GET only, one per month), plans the
#      cloud items per rule (a csi-spl- line -> the operator, another line
#      and a cloud cost entry -> the other workspace, an item already so ->
#      skipped), the tokens split and a person's split, sends no PUT, and
#      prints counts only: no label, amount or person id
#   2. DRY_RUN=0 sends exactly the planned PUT bodies
#   3. bad input is refused before any call: a sum of 9999, a bad month,
#      FROM after TO, the same workspace twice, a malformed person entry
#   4. an unknown person code and a workspace that is not live are refused
#      after the reads, before any PUT
#   5. a refused PUT fails the run and names the HTTP and error code only
#   6. a split already in force is not sent again
# RED CONTROL: case 1 fails when the dry-run guard in _spl_cost_split_run is
# dropped (the call file then holds PUTs).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

PID=0a1b2c3d-1111-4222-8333-444455556666
SPLITS='{"splits":[],"people":[{"id":"'$PID'","code":"E-01"}],"workspaces":[{"id":"t1","name":"spool-hub"},{"id":"csitea","name":"csitea"}]}'
MONTH='{"month":"x","items":[
 {"source":"gcp","project_or_vendor":"csi-spl-prd","kind":"run","label":"cloud","usd_micros":7,"shares":[]},
 {"source":"gcp","project_or_vendor":"other-proj","kind":"run","label":"cloud","usd_micros":7,"shares":[]},
 {"source":"gcp","project_or_vendor":"csi-spl-dev","kind":"run","label":"cloud","usd_micros":7,"shares":[{"workspace_id":"t1","share_bp":10000}]},
 {"source":"cost_entry","project_or_vendor":"SecretVendorLabel","kind":"cloud","label":"cloud","usd_micros":7,"shares":[]},
 {"source":"cost_entry","project_or_vendor":"Monthly salary","kind":"hr","label":"persons","usd_micros":7,"shares":[]}],"workspaces":[]}'
HR='{"entries":[{"id":"e1","type":"hr","period":"2026-01","person_id":"'$PID'","amount":4242.5},{"id":"e2","type":"hr","period":"2026-02","person_id":"'$PID'","amount":4242.5},{"id":"e3","type":"hr","period":"2026-02","person_id":"","amount":1}]}'

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev CALLS="$T/calls" SPLITS="$SPLITS" MONTH="$MONTH" HR="$HR" \
    COST_SPLIT_FROM=2026-01 COST_SPLIT_TO=2026-02 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null SPL_PROJECT=csi-spl-dev; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "hub $1 $2 ${3:-}" >>"$CALLS"; SPL_HUB_OP_STATUS=200
      case "$1 $2" in
        "GET /v1/operator/cost-splits") SPL_HUB_OP_BODY="${STUB_SPLITS:-$SPLITS}" ;;
        "GET /v1/operator/cost-allocations"*) SPL_HUB_OP_BODY="$MONTH" ;;
        "GET /v1/operator/cost-entries"*) SPL_HUB_OP_BODY="$HR" ;;
        PUT*) SPL_HUB_OP_STATUS="${STUB_PUT_CODE:-200}"; SPL_HUB_OP_BODY="{\"error\":\"bad_cost_split\",\"message\":\"SecretDetail\"}" ;;
      esac
      return 0
    }
    do_spl_cost_split_apply' >"$T/o" 2>&1
}
ALL=("COST_SPLIT_TOKENS=t1=7000,csitea=3000" "COST_SPLIT_PERSONS=E-01:t1=7000,csitea=3000")

# --- 1. the dry run ---------------------------------------------------------------
run "${ALL[@]}"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^hub PUT' "$T/calls" && [[ $(grep -c '^hub GET /v1/operator/cost-allocations?month=' "$T/calls") -eq 2 ]] \
  && grep -qF 'PLAN cloud rule=line-prefix -> t1: items=1 already=1' "$T/o" \
  && grep -qF 'PLAN cloud rule=line-other -> csitea: items=1 already=0' "$T/o" \
  && grep -qF 'PLAN cloud rule=cloud-entry -> csitea: items=1 already=0' "$T/o" \
  && grep -qF 'PLAN split tokens: shares=2' "$T/o" && grep -qF 'PLAN person E-01: hr rows=2 months=2' "$T/o" \
  && grep -qF 'OK DRY_RUN dev: 5 PUT(s) planned' "$T/o" \
  && ! grep -qE 'SecretVendorLabel|4242|'$PID "$T/o" \
  && pass "1. dry run: GETs only, counts per rule, no label, amount or person id" || fail "1. dry run: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. DRY_RUN=0 sends the planned bodies ----------------------------------------
run "${ALL[@]}" DRY_RUN=0; rc=$?
want=(
  'hub PUT /v1/operator/cost-allocations {"source":"gcp","project_or_vendor":"csi-spl-prd","kind":"run","shares":[{"workspace_id":"t1","share_bp":10000}]}'
  'hub PUT /v1/operator/cost-allocations {"source":"gcp","project_or_vendor":"other-proj","kind":"run","shares":[{"workspace_id":"csitea","share_bp":10000}]}'
  'hub PUT /v1/operator/cost-allocations {"source":"cost_entry","project_or_vendor":"SecretVendorLabel","kind":"cloud","shares":[{"workspace_id":"csitea","share_bp":10000}]}'
  'hub PUT /v1/operator/cost-splits {"split_kind":"tokens","subject":"","shares":[{"workspace_id":"t1","share_bp":7000},{"workspace_id":"csitea","share_bp":3000}]}'
  'hub PUT /v1/operator/cost-splits {"split_kind":"person","subject":"'"$PID"'","shares":[{"workspace_id":"t1","share_bp":7000},{"workspace_id":"csitea","share_bp":3000}]}'
)
ok=1; for w in "${want[@]}"; do grep -qxF "$w" "$T/calls" || ok=0; done
[[ $rc -eq 0 && $ok -eq 1 && $(grep -c '^hub PUT' "$T/calls") -eq 5 ]] && grep -qF 'OK dev: PUT sent=5 ok=5 refused=0' "$T/o" \
  && ! grep -q 'Monthly salary' "$T/calls" \
  && pass "2. DRY_RUN=0 sends the 5 planned PUTs, no Persons item" || fail "2. apply: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 3. refusals before any call --------------------------------------------------
for bad in COST_SPLIT_TOKENS=t1=9999 COST_SPLIT_TOKENS=t1=7000,csitea COST_SPLIT_FROM=2026-13 COST_SPLIT_FROM=2026-03 \
  COST_SPLIT_OTHER=t1 "COST_SPLIT_PERSONS=E-01" "COST_SPLIT_PERSONS=Jane:t1=10000" DRY_RUN=yes; do
  run "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "3. $bad refused, no call" || fail "3. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 4. refusals after the reads --------------------------------------------------
run "COST_SPLIT_PERSONS=E-99:t1=10000" DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub PUT' "$T/calls" && grep -qF 'FATAL no hr person with code E-99' "$T/o" \
  && pass "4. an unknown person code: FATAL, no PUT" || fail "4. code: rc=$rc $(cat "$T/calls" "$T/o")"
run COST_SPLIT_OTHER=gone DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^hub PUT' "$T/calls" && grep -qF 'FATAL workspace gone is not a live workspace' "$T/o" \
  && pass "4. a workspace that is not live: FATAL, no PUT" || fail "4. ws: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. a refused PUT -------------------------------------------------------------
run "${ALL[@]}" DRY_RUN=0 STUB_PUT_CODE=400; rc=$?
[[ $rc -ne 0 ]] && grep -qF 'ERROR dev: PUT sent=5 ok=0 refused=5' "$T/o" && grep -qF 'answered 400 bad_cost_split' "$T/o" \
  && ! grep -q SecretDetail "$T/o" && pass "5. refused PUTs fail the run, HTTP and error code only" || fail "5. refused: rc=$rc $(cat "$T/o")"

# --- 6. a split already in force --------------------------------------------------
IN_FORCE='{"splits":[{"split_kind":"tokens","subject":"","shares":[{"workspace_id":"csitea","share_bp":3000},{"workspace_id":"t1","share_bp":7000}]}],"people":[],"workspaces":[{"id":"t1"},{"id":"csitea"}]}'
run STUB_SPLITS="$IN_FORCE" COST_SPLIT_CLOUD_PREFIX= COST_SPLIT_TOKENS=t1=7000,csitea=3000 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^hub PUT' "$T/calls" && ! grep -q 'cost-allocations' "$T/calls" && grep -qF 'PLAN split tokens: already in force' "$T/o" \
  && pass "6. a split in force and no cloud step: nothing sent" || fail "6. in force: rc=$rc $(cat "$T/calls" "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
