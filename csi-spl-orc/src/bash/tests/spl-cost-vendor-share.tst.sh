#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cost_vendor_share (SPL-6301, spec 143 costs-allocation.md
#          7.7), with the hub operator call stubbed:
#   1. the dry run (default) reads (GET only), logs the vendor's paid items
#      per month of the range (counts only: no amount, no plan label), plans
#      one tokens_vendor PUT and sends none
#   2. DRY_RUN=0 sends exactly the planned body: the workspace at its bp,
#      the rest over the tokens split pro rata (6000 of t1 7000 / csitea
#      3000 = 4200 / 1800)
#   3. COST_SHARE_REST names the rest instead; a workspace of the tokens
#      split takes its pro rata part of the rest on top of its bp; a share
#      of 3333/3333/3334 keeps a whole of 10000 (largest remainder)
#   4. bad input is refused before any call
#   5. after the reads, no PUT: no tokens split, a range with no item of the
#      vendor, a workspace that is not live, a stored tokens_vendor split of
#      the vendor whose months meet the range
#   6. a refused PUT fails the run, HTTP and error code only
#   7. the split already in force is not sent again
# RED CONTROL: case 1 fails when the dry-run guard in _spl_cost_vshare_run
# is dropped (the call file then holds a PUT).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

WS='"workspaces":[{"id":"t1"},{"id":"csitea"},{"id":"ws-a"}]'
TOK='{"split_kind":"tokens","subject":"","shares":[{"workspace_id":"csitea","share_bp":3000},{"workspace_id":"t1","share_bp":7000}]}'
SPLITS='{"splits":['"$TOK"'],"people":[],'"$WS"'}'
PAID='{"items":[
 {"id":"a","vendor":"claude","kind":"subscription","plan_label":"SecretPlan","amount":4242.5,"currency":"USD","period_start":"2026-01-01","period_end":"2026-02-01","usd_micros":4242500000},
 {"id":"b","vendor":"claude","kind":"topup","plan_label":"SecretPlan","amount":4242.5,"currency":"USD","period_start":"2026-03-10","period_end":"2026-04-10","usd_micros":4242500000},
 {"id":"c","vendor":"grok","kind":"subscription","plan_label":"SecretPlan","amount":4242.5,"currency":"USD","period_start":"2026-02-01","period_end":"2026-03-01","usd_micros":4242500000},
 {"id":"d","vendor":"claude","kind":"subscription","plan_label":"SecretPlan","amount":4242.5,"currency":"USD","period_start":"2026-08-01","period_end":"2026-09-01","usd_micros":4242500000}]}'

run() {
  : >"$T/calls"
  env PROJ_PATH="$PROJ_ROOT" ENV=dev CALLS="$T/calls" SPLITS="$SPLITS" PAID="$PAID" \
    COST_SHARE_VENDOR=claude COST_SHARE_FROM=2026-01 COST_SHARE_TO=2026-04 COST_SHARE_WORKSPACE=ws-a COST_SHARE_BP=4000 "$@" bash -c '
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
        "GET /v1/operator/fleet-tokens/paid") SPL_HUB_OP_BODY="$PAID" ;;
        PUT*) SPL_HUB_OP_STATUS="${STUB_PUT_CODE:-200}"; SPL_HUB_OP_BODY="{\"error\":\"bad_cost_split\",\"message\":\"SecretDetail\"}" ;;
      esac
      return 0
    }
    do_spl_cost_vendor_share' >"$T/o" 2>&1
}
put_of() { printf 'hub PUT /v1/operator/cost-splits {"split_kind":"tokens_vendor","subject":"%s","shares":%s}' "$1" "$2"; }

# --- 1. the dry run ---------------------------------------------------------------
run; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^hub PUT' "$T/calls" && [[ $(grep -c '^hub GET' "$T/calls") -eq 2 ]] \
  && grep -qF 'PLAN vendor=claude month=2026-01 paid items=1' "$T/o" && grep -qF 'PLAN vendor=claude month=2026-02 paid items=0' "$T/o" \
  && grep -qF 'PLAN vendor=claude month=2026-03 paid items=1' "$T/o" && grep -qF 'PLAN vendor=claude month=2026-04 paid items=1' "$T/o" \
  && grep -qF 'PLAN split tokens_vendor claude 2026-01..2026-04: shares=3' "$T/o" && grep -qF 'OK DRY_RUN dev: 1 PUT(s) planned' "$T/o" \
  && ! grep -qE 'SecretPlan|4242' "$T/o" \
  && pass "1. dry run: GETs only, items per month, no amount or plan" || fail "1. dry run: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. DRY_RUN=0 sends the planned body ------------------------------------------
run DRY_RUN=0; rc=$?
want="$(put_of claude:2026-01:2026-04 '[{"workspace_id":"ws-a","share_bp":4000},{"workspace_id":"csitea","share_bp":1800},{"workspace_id":"t1","share_bp":4200}]')"
[[ $rc -eq 0 && $(grep -c '^hub PUT' "$T/calls") -eq 1 ]] && grep -qxF "$want" "$T/calls" && grep -qF 'OK dev: PUT sent=1 ok=1 refused=0' "$T/o" \
  && pass "2. DRY_RUN=0: ws-a 4000, the rest 4200 / 1800 by the tokens split" || fail "2. apply: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 3. the rest named, the workspace inside the tokens split, rounding -----------
run DRY_RUN=0 COST_SHARE_REST=t1=6000; rc=$?
want="$(put_of claude:2026-01:2026-04 '[{"workspace_id":"ws-a","share_bp":4000},{"workspace_id":"t1","share_bp":6000}]')"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/calls" && pass "3. COST_SHARE_REST names the rest" || fail "3. rest: rc=$rc $(cat "$T/calls" "$T/o")"
run DRY_RUN=0 COST_SHARE_WORKSPACE=csitea; rc=$?
want="$(put_of claude:2026-01:2026-04 '[{"workspace_id":"csitea","share_bp":5800},{"workspace_id":"t1","share_bp":4200}]')"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/calls" && pass "3. a workspace of the tokens split adds its part of the rest" || fail "3. merge: rc=$rc $(cat "$T/calls" "$T/o")"
THIRDS='{"splits":[{"split_kind":"tokens","subject":"","shares":[{"workspace_id":"t1","share_bp":3333},{"workspace_id":"csitea","share_bp":3333},{"workspace_id":"ws-a","share_bp":3334}]}],"people":[],'"$WS"'}'
run DRY_RUN=0 STUB_SPLITS="$THIRDS" COST_SHARE_WORKSPACE=t1 COST_SHARE_BP=1; rc=$?
want="$(put_of claude:2026-01:2026-04 '[{"workspace_id":"t1","share_bp":3334},{"workspace_id":"csitea","share_bp":3333},{"workspace_id":"ws-a","share_bp":3333}]')"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/calls" && pass "3. largest remainder keeps the whole at 10000" || fail "3. thirds: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. refusals before any call --------------------------------------------------
for bad in COST_SHARE_VENDOR=openai COST_SHARE_FROM=2026-13 COST_SHARE_FROM=2026-05 COST_SHARE_BP=0 COST_SHARE_BP=10001 \
  COST_SHARE_WORKSPACE='a b' COST_SHARE_REST=t1=5000 COST_SHARE_REST=t1 DRY_RUN=yes; do
  run "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "4. $bad refused, no call" || fail "4. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 5. refusals after the reads --------------------------------------------------
NO_TOK='{"splits":[],"people":[],'"$WS"'}'
OVER='{"splits":['"$TOK"',{"split_kind":"tokens_vendor","subject":"claude:2026-04:2026-06","shares":[{"workspace_id":"t1","share_bp":10000}]}],"people":[],'"$WS"'}'
for c in "STUB_SPLITS=$NO_TOK|FATAL no tokens split is stored" "COST_SHARE_FROM=2026-05|FATAL COST_SHARE_FROM is after" \
  "COST_SHARE_FROM=2026-05 COST_SHARE_TO=2026-06|FATAL vendor claude has no paid item in 2026-05..2026-06" \
  "COST_SHARE_WORKSPACE=gone|FATAL workspace gone is not a live workspace" \
  "STUB_SPLITS=$OVER|FATAL the months meet the stored tokens_vendor split claude:2026-04:2026-06"; do
  read -r -a args <<<"${c%%|*}"
  run "${args[@]}" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 ]] && ! grep -q '^hub PUT' "$T/calls" && grep -qF "${c#*|}" "$T/o" \
    && pass "5. ${c#*|}: no PUT" || fail "5. ${c#*|}: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 6. a refused PUT -------------------------------------------------------------
run DRY_RUN=0 STUB_PUT_CODE=400; rc=$?
[[ $rc -ne 0 ]] && grep -qF 'ERROR dev: PUT sent=1 ok=0 refused=1' "$T/o" && grep -qF 'answered 400 bad_cost_split' "$T/o" \
  && ! grep -q SecretDetail "$T/o" && pass "6. a refused PUT fails the run, HTTP and error code only" || fail "6. refused: rc=$rc $(cat "$T/o")"

# --- 7. the split already in force ------------------------------------------------
IN_FORCE='{"splits":['"$TOK"',{"split_kind":"tokens_vendor","subject":"claude:2026-01:2026-04","shares":[{"workspace_id":"t1","share_bp":4200},{"workspace_id":"ws-a","share_bp":4000},{"workspace_id":"csitea","share_bp":1800}]}],"people":[],'"$WS"'}'
run DRY_RUN=0 STUB_SPLITS="$IN_FORCE"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^hub PUT' "$T/calls" && grep -qF 'already in force' "$T/o" \
  && pass "7. the split in force: nothing sent" || fail "7. in force: rc=$rc $(cat "$T/calls" "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
