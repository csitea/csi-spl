#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_hub_agent_kinds (rdb 0149, t1 41fa1f2d), with the hub
#          operator call stubbed:
#   1. dry run prints and calls nothing
#   2. bad input (an unknown kind, every kind off, a bad ORDERED_BY, no
#      ORDERED_BY with DRY_RUN=0) is refused before any call
#   3. KINDS_OFF=grok PATCHes {agent_kinds_off:[grok], ordered_by, ordered_via};
#      'none' sends []; the order is the hub's, whatever the input order
#   4. KINDS_OFF unset reads (GET) and prints the kinds off and the pauses
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
    do_spl_hub_agent_kinds' >"$T/o" 2>&1
}
OK_BODY='{"low":50,"high":75,"agent_kinds_off":["grok"],"agent_kinds_paused":{"agy":{"until":"2026-10-08T01:00:00Z","reason":"usage limit: a-1","box":"b1"}},"source":"hub"}'

# --- 1. dry run ---------------------------------------------------------------
run KINDS_OFF=grok; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'DRY_RUN would ask the hub https://hub.invalid to switch off the agent kinds \[grok\]' "$T/o" \
  && pass "1. dry run prints and calls nothing" || fail "1. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. refusals --------------------------------------------------------------
for bad in "KINDS_OFF=gpt" "KINDS_OFF=vibe" "KINDS_OFF=claude,grok,agy,qwen,mistral,codex" "KINDS_OFF=grok;rm" "ORDERED_BY=bob" "DRY_RUN=2"; do
  run KINDS_OFF=grok ORDERED_BY=HUM-10 DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "2. $bad refused before any call" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done
run KINDS_OFF=grok DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'ORDERED_BY .* is required' "$T/o" \
  && pass "2. DRY_RUN=0 without ORDERED_BY is refused" || fail "2. ordered_by: rc=$rc $(cat "$T/o")"

# --- 3. set ---------------------------------------------------------------------
run KINDS_OFF=grok ORDERED_BY=HUM-10 ORDERED_VIA=c-496 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF 'hub PATCH /v1/operator/fleet-load {"agent_kinds_off":["grok"],"ordered_by":"HUM-10","ordered_via":"c-496"}' "$T/calls" \
  && grep -q '^OK dev instance agent kinds: off \[grok\], paused \[agy until 2026-10-08T01:00:00Z (usage limit: a-1)\] (set by ordered_by=HUM-10 via c-496' "$T/o" \
  && pass "3. KINDS_OFF=grok PATCHes the set as the SA" || fail "3. set: rc=$rc $(cat "$T/calls" "$T/o")"
run KINDS_OFF="qwen, grok" ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
grep -qF '{"agent_kinds_off":["grok","qwen"],"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "3. the set goes in the hub's order, spaces dropped" || fail "3. order: $(cat "$T/calls" "$T/o")"
run KINDS_OFF=none ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY='{"agent_kinds_off":[],"agent_kinds_paused":{}}'; rc=$?
[[ $rc -eq 0 ]] && grep -qF '{"agent_kinds_off":[],"ordered_by":"HUM-10"}' "$T/calls" && grep -q 'off \[\], paused \[\]' "$T/o" \
  && pass "3. 'none' switches every kind on" || fail "3. none: rc=$rc $(cat "$T/calls" "$T/o")"
run KINDS_OFF="mistral,grok" ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qF '{"agent_kinds_off":["grok","mistral"],"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "3. mistral is a kind (spec 110), last in the hub's order" || fail "3. mistral: rc=$rc $(cat "$T/calls" "$T/o")"
run KINDS_OFF=claude,grok,agy,qwen,mistral ORDERED_BY=HUM-10 DRY_RUN=0 STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qF '{"agent_kinds_off":["claude","grok","agy","qwen","mistral"],"ordered_by":"HUM-10"}' "$T/calls" \
  && pass "3. control: five kinds off is no longer every kind (codex stays on, SPL-5454)" || fail "3. five off: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 4. read --------------------------------------------------------------------
run STUB_BODY="$OK_BODY"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'hub GET /v1/operator/fleet-load ' "$T/calls" && grep -q '^OK dev instance agent kinds: off \[grok\]' "$T/o" \
  && ! grep -q 'set by' "$T/o" && pass "4. KINDS_OFF unset reads (no DRY_RUN needed)" || fail "4. read: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. hub refusals ------------------------------------------------------------
run KINDS_OFF=grok ORDERED_BY=HUM-10 DRY_RUN=0 STUB_CODE=400 STUB_BODY='{"error":"bad_setting","detail":"never all four"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'refused the setting (400): never all four' "$T/o" && pass "5. 400 fails with the hub's detail" || fail "5. 400: rc=$rc $(cat "$T/o")"
run STUB_CODE=403 STUB_BODY='{"error":"not_operator"}'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'SPOOL_HUB_OPERATOR_EMAILS' "$T/o" && pass "5. 403 names the operator allowlist" || fail "5. 403: rc=$rc $(cat "$T/o")"

# --- 6. _spl_hub_fleet_load_error (r01-02 one copy) -----------------------------
out=$(env PROJ_ROOT="$PROJ_ROOT" SPL_HUB_OP_STATUS=400 SPL_HUB_OP_BODY='{"detail":"bad val"}' GCP_ACCOUNT=sa@example.test bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"; _spl_hub_fleet_load_error "x was"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL the hub refused the setting (400): bad val. Nothing changed." ]] \
  && pass "6. _spl_hub_fleet_load_error handles 400" || fail "6. err 400: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" SPL_HUB_OP_STATUS=401 SPL_HUB_OP_BODY='{"error":"unauth"}' GCP_ACCOUNT=sa@example.test bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"; _spl_hub_fleet_load_error "x was"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL the hub refused the operator id token (401): is sa@example.test in SPOOL_HUB_OPERATOR_EMAILS? Nothing changed. unauth" ]] \
  && pass "6. _spl_hub_fleet_load_error handles 401" || fail "6. err 401: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" SPL_HUB_OP_STATUS=404 SPL_HUB_OP_BODY='{"error":"no_op"}' GCP_ACCOUNT=sa@example.test bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"; _spl_hub_fleet_load_error "x was"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL the hub answered 404 (no_op): no operator workspace, or a hub without this door yet. Nothing changed." ]] \
  && pass "6. _spl_hub_fleet_load_error handles 404" || fail "6. err 404: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" SPL_HUB_OP_STATUS=500 SPL_HUB_OP_BODY='{"detail":"boom"}' GCP_ACCOUNT=sa@example.test bash -c '
  do_log(){ echo "$*"; }; source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"; _spl_hub_fleet_load_error "x was"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL x was not read or changed (http 500): boom" ]] \
  && pass "6. _spl_hub_fleet_load_error handles wildcard status with subject_verb" || fail "6. err 500: rc=$rc $out"
run STUB_CODE=404 STUB_BODY='{"error":"no_op"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qxF 'FATAL the hub answered 404 (no_op): no operator workspace, or a hub without this door yet. Nothing changed.' "$T/o" \
  && pass "6. agent-kinds 404 fails with exact message" || fail "6. kinds 404: rc=$rc $(cat "$T/o")"
run STUB_CODE=500 STUB_BODY='{"detail":"boom"}'; rc=$?
[[ $rc -eq 1 ]] && grep -qxF 'FATAL the instance agent kinds were not read or changed (http 500): boom' "$T/o" \
  && pass "6. agent-kinds 500 fails with exact subject_verb message" || fail "6. kinds 500: rc=$rc $(cat "$T/o")"
ak_f="$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
[[ "$(grep -c "FATAL the hub refused the setting (400):" "$ak_f")" -eq 1 && "$(grep -c "SPOOL_HUB_OPERATOR_EMAILS?" "$ak_f")" -eq 1 && "$(grep -c "FATAL the hub answered 404 (" "$ak_f")" -eq 1 && "$(grep -c "_spl_hub_fleet_load_error " "$ak_f")" -ge 1 ]] \
  && pass "6. one copy: spl-hub-agent-kinds.func.sh defines and calls _spl_hub_fleet_load_error once" || fail "6. kinds one copy"

# --- 7. _spl_hub_fleet_load_prep (r03-01 one copy) ------------------------------
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; do_spl_cloud_cnf(){ echo "CNF"; SPL_PROJECT=csi-spl-dev; }
  spl_hub_operator_url(){ echo "URL"; SPL_HUB_URL=https://hub.test; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep __read__ "" "" "change x" || exit 1
  printf "DONE=%s\n" "$SPL_FL_DRY_DONE"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"CNF"* && "$out" == *"URL"* && "$out" == *"DONE=0"* ]] \
  && pass "7. _spl_hub_fleet_load_prep read mode loads cnf/url and sets SPL_FL_DRY_DONE=0" || fail "7. prep read: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; spl_dry_run(){ return 0; }
  do_spl_cloud_cnf(){ SPL_PROJECT=csi-spl-dev; }; spl_hub_operator_url(){ SPL_HUB_URL=https://hub.test; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok HUM-10 c-496 "change x" || exit 1
  printf "DONE=%s\n" "$SPL_FL_DRY_DONE"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"OK DRY_RUN would ask the hub https://hub.test to change x for the whole instance (ordered_by=HUM-10 via c-496), as the csi-spl-dev service account. Re-run with DRY_RUN=0."* && "$out" == *"DONE=1"* ]] \
  && pass "7. _spl_hub_fleet_load_prep dry run logs exact message and sets SPL_FL_DRY_DONE=1" || fail "7. prep dry: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; do_spl_cloud_cnf(){ echo "CNF-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok bob "" "change x"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL ORDERED_BY must be a HUM-* id, got: 'bob'" && "$out" != *"CNF-CALLED"* ]] \
  && pass "7. _spl_hub_fleet_load_prep refuses bad ORDERED_BY before cloud cnf" || fail "7. prep bad by: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; do_spl_cloud_cnf(){ echo "CNF-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok HUM-10 "$(printf '\''a%.0s'\'' {1..65})" "change x"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL ORDERED_VIA is at most 64 chars" && "$out" != *"CNF-CALLED"* ]] \
  && pass "7. _spl_hub_fleet_load_prep refuses ORDERED_VIA over 64 chars before cloud cnf" || fail "7. prep long via: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; spl_dry_run(){ return 1; }
  do_spl_cloud_cnf(){ SPL_PROJECT=csi-spl-dev; }; spl_hub_operator_url(){ SPL_HUB_URL=https://hub.test; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok "" "" "change x"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == "FATAL ORDERED_BY (a HUM-* id: who ordered this) is required with DRY_RUN=0" ]] \
  && pass "7. _spl_hub_fleet_load_prep requires ORDERED_BY on DRY_RUN=0" || fail "7. prep req by: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" bash -c '
  do_log(){ echo "$*"; }; spl_dry_run(){ return 1; }
  do_spl_cloud_cnf(){ SPL_PROJECT=csi-spl-dev; }; spl_hub_operator_url(){ SPL_HUB_URL=https://hub.test; }
  source "$PROJ_ROOT/src/bash/run/spl-hub-agent-kinds.func.sh"
  _spl_hub_fleet_load_prep grok HUM-10 "" "change x" || exit 1
  printf "DONE=%s\n" "$SPL_FL_DRY_DONE"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "DONE=0" ]] \
  && pass "7. _spl_hub_fleet_load_prep live write with ORDERED_BY returns 0 with SPL_FL_DRY_DONE=0" || fail "7. prep live: rc=$rc $out"
[[ "$(grep -c "FATAL ORDERED_BY must be a HUM-\* id" "$ak_f")" -eq 1 && "$(grep -c "FATAL ORDERED_VIA is at most 64 chars" "$ak_f")" -eq 1 && "$(grep -c "is required with DRY_RUN=0" "$ak_f")" -eq 1 && "$(grep -c "_spl_hub_fleet_load_prep " "$ak_f")" -ge 1 ]] \
  && pass "7. one copy: spl-hub-agent-kinds.func.sh defines and calls _spl_hub_fleet_load_prep once" || fail "7. kinds prep one copy"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
