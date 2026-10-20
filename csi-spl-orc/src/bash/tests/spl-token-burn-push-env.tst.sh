#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_token_burn_push_env (spl-token-burn-push-env.func.sh),
#          hermetic (test round 2 row 09). No hub, no real spool binary, no
#          live lease.conf: SPOOL_ROOT, TOKEN_BURN_STATE_DIR and the desk
#          state dir are temp dirs, spool / curl are stubs on PATH and
#          spl_host_spool is a stubbed function. The action takes no token
#          and has no dry run: it resolves the lane-map hub settings and
#          writes them, paths and the hub URL only, to push.env.
#   1. local mode (no LANE_FLEET, no lease.conf) is refused: exit 1, FATAL,
#      the state dir is not even created
#   2. validation before anything is written: a LANE_FLEET, LANE_BOX or
#      LANE_TENANT that is not a slug, no LANE_TENANT, a LANE_ENV outside
#      dev|prd|self, a desk box that is not pinned -> exit 1 + its FATAL
#   3. hub mode: exit 0, the state dir is created, push.env is mode 600 and
#      holds exactly the six keys: the desk paths, box, tenant, the env's
#      hub URL (read from the cnf, no literal domain here) and the spool
#      binary; no temp file is left behind
#   4. the fleet settings come from dispatch/lease.conf when the env has
#      none; the env beats lease.conf
#   5. a re-run replaces push.env whole (no stale line survives)
#   6. a state dir that cannot be created -> exit 1, nothing written
#   7. no key material is written: the key file's content never reaches
#      push.env; the stubs record no spool / curl call
#   8. CONTROL: the stubs record a call, so 7 can fail
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 0 spool curl gcloud docker psql
ROOT="$T/root"; mkdir -p "$ROOT/dispatch"
STATE="$T/state/dev"
DESK="$STATE/desk/t1/desk-a"
mkdir -p "$DESK/keys"
echo pinned >"$DESK/pinned"
printf 'PRIVATE-KEY-MATERIAL-7f3a\n' >"$DESK/keys/box.key"

# The env's hub host, read the way the action reads it (no literal domain here)
API=$(SNIPPET='do_spl_cloud_cnf >/dev/null && yq -r .env.dns.api_fqdn "$SPL_CNF"' in_orc 2>/dev/null | tail -n 1)
[[ -n "$API" && "$API" != null ]] || { echo "FAIL: cannot read the dev cnf api_fqdn"; exit 1; }

# One run of the action in a fresh shell. Every LANE_* / LEASE_* the caller's
# env carries is dropped first, then the case's VAR=value lines (one per
# line in a file, so a value with a space stays one value) are exported.
run_case() {
  printf '%s\n' "$@" >"$T/case.lst"
  : >"$T/calls.log"
  SNIPPET='unset LANE_HUB_CMD LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX LANE_BOX LEASE_FLEET LEASE_ENV LEASE_TENANT LEASE_DESK_BOX
    while IFS= read -r kv; do [[ -n "$kv" ]] && export "${kv?}"; done <"$CASE_FILE"
    spl_host_spool() { SPL_SPOOL="$STUB_DIR/spool"; }
    do_spl_token_burn_push_env' \
    in_orc SPOOL_ROOT="$ROOT" STUB_DIR="$T/stub" CASE_FILE="$T/case.lst" TOKEN_BURN_STATE_DIR="${OUT:-$T/burn}" 2>&1
}
HUB=(LANE_FLEET=fleet-a LANE_ENV=dev LANE_TENANT=t1 LANE_DESK_BOX=desk-a LANE_BOX=box-b)
reset() { rm -rf "$T/burn"; rm -f "$ROOT/dispatch/lease.conf"; }

# --- 1. local mode is refused ------------------------------------------------------------
reset
out=$(run_case); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL the token burn lives on the hub"* && ! -e "$T/burn" ]] &&
  pass "1. no LANE_FLEET and no lease.conf -> exit 1, FATAL, no state dir" ||
  fail "1. local mode: rc=$rc out=$out"

# --- 2. validation, nothing written ------------------------------------------------------
refused() {   # refused <label> <fatal-substring> <VAR=value>...
  local label="$1" want="$2"; shift 2
  reset
  out=$(run_case "$@"); rc=$?
  [[ $rc -eq 1 && "$out" == *"$want"* && ! -e "$T/burn/push.env" ]] &&
    pass "2. $label -> exit 1, '$want', no push.env" ||
    fail "2. $label: rc=$rc out=$out"
}
refused "LANE_FLEET not a slug" "FATAL LANE_FLEET must be a lowercase slug" LANE_FLEET=Fleet_A LANE_ENV=dev LANE_TENANT=t1 LANE_DESK_BOX=desk-a LANE_BOX=box-b
refused "LANE_FLEET over 32 chars" "FATAL LANE_FLEET must be a lowercase slug" "LANE_FLEET=f$(printf 'x%.0s' {1..32})" LANE_ENV=dev LANE_TENANT=t1 LANE_DESK_BOX=desk-a LANE_BOX=box-b
refused "LANE_BOX with a space" "FATAL LANE_BOX must be a lowercase slug" LANE_FLEET=fleet-a LANE_ENV=dev LANE_TENANT=t1 LANE_DESK_BOX=desk-a "LANE_BOX=box b"
refused "no LANE_TENANT" "FATAL LANE_TENANT is not set" LANE_FLEET=fleet-a LANE_ENV=dev LANE_DESK_BOX=desk-a LANE_BOX=box-b
refused "LANE_TENANT not a slug" "FATAL LANE_TENANT is not set" LANE_FLEET=fleet-a LANE_ENV=dev LANE_TENANT=T1 LANE_DESK_BOX=desk-a LANE_BOX=box-b
refused "LANE_ENV=stg" "FATAL LANE_ENV must be dev, prd or self" LANE_FLEET=fleet-a LANE_ENV=stg LANE_TENANT=t1 LANE_DESK_BOX=desk-a LANE_BOX=box-b
refused "desk box not pinned" "FATAL desk-z is not pinned in t1" LANE_FLEET=fleet-a LANE_ENV=dev LANE_TENANT=t1 LANE_DESK_BOX=desk-z LANE_BOX=box-b

# --- 3. hub mode writes push.env ---------------------------------------------------------
reset
out=$(run_case "${HUB[@]}"); rc=$?
want="SPOOL_ROOT=$DESK/spool
SPOOL_KEYS_DIR=$DESK/keys
SPOOL_BOX_ID=desk-a
SPOOL_HUB_URL=https://$API
SPOOL_TENANT=t1
SPL_SPOOL=$T/stub/spool"
got=$(cat "$T/burn/push.env" 2>/dev/null)
[[ $rc -eq 0 && "$out" == *"OK wrote $T/burn/push.env (desk desk-a of t1)"* ]] &&
  pass "3. hub mode -> exit 0, the OK line names the file, desk and tenant" || fail "3. hub mode: rc=$rc out=$out"
[[ "$got" == "$want" ]] && pass "3. push.env holds exactly the six keys and values" ||
  fail "3. push.env content: $(diff <(echo "$want") <(echo "$got"))"
mode=$(stat -c %a "$T/burn/push.env" 2>/dev/null)
[[ "$mode" == 600 ]] && pass "3. push.env is mode 600" || fail "3. push.env mode: $mode"
left=$(find "$T/burn" -name 'push.env.*' | wc -l)
[[ $left -eq 0 ]] && pass "3. no temp file left behind" || fail "3. $left temp file(s) left"

# --- 4. lease.conf fallback, the env wins ------------------------------------------------
reset
printf 'LEASE_FLEET=fleet-c\nLEASE_ENV=dev\nLEASE_TENANT=t1\nLEASE_DESK_BOX=desk-a\nnot-a-setting\n' >"$ROOT/dispatch/lease.conf"
out=$(run_case LANE_BOX=box-b); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'SPOOL_BOX_ID=desk-a' "$T/burn/push.env" && grep -qx 'SPOOL_TENANT=t1' "$T/burn/push.env" &&
  pass "4. no LANE_* in env -> fleet, env, tenant and desk box from lease.conf" || fail "4. lease.conf: rc=$rc out=$out"
rm -rf "$T/burn"
out=$(run_case LANE_BOX=box-b LANE_DESK_BOX=desk-z); rc=$?
[[ $rc -eq 1 && "$out" == *"desk-z is not pinned"* && ! -e "$T/burn/push.env" ]] &&
  pass "4. LANE_DESK_BOX in env beats LEASE_DESK_BOX" || fail "4. env over lease.conf: rc=$rc out=$out"

# --- 5. a re-run replaces push.env whole -------------------------------------------------
reset
mkdir -p "$T/burn"; printf 'STALE=1\nSPOOL_TENANT=old\n' >"$T/burn/push.env"
out=$(run_case "${HUB[@]}"); rc=$?
[[ $rc -eq 0 && "$(cat "$T/burn/push.env")" == "$want" ]] &&
  pass "5. a re-run replaces the old push.env, no stale line" || fail "5. re-run: rc=$rc got=$(cat "$T/burn/push.env")"

# --- 6. a state dir that cannot be created -----------------------------------------------
reset
: >"$T/blocker"
out=$(OUT="$T/blocker/burn" run_case "${HUB[@]}"); rc=$?
[[ $rc -eq 1 && ! -e "$T/blocker/burn" ]] && pass "6. state dir under a file -> exit 1, nothing written" ||
  fail "6. mkdir failure: rc=$rc out=$out"

# --- 7. no key material, no hub call -----------------------------------------------------
reset
out=$(run_case "${HUB[@]}"); rc=$?
! grep -rq 'PRIVATE-KEY-MATERIAL' "$T/burn" && [[ "$out" != *PRIVATE-KEY-MATERIAL* ]] &&
  pass "7. the key file's content never reaches push.env or the log" || fail "7. key material leaked"
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && pass "7. no spool / curl / gcloud call" ||
  fail "7. external calls: rc=$rc $(cat "$T/calls.log")"

# --- 8. CONTROL: the stubs record a call -------------------------------------------------
: >"$T/calls.log"
STUB_LOG="$T/calls.log" "$T/stub/spool" push --probe >/dev/null
grep -qx 'spool push --probe' "$T/calls.log" && pass "8. CONTROL: a spool call is recorded" ||
  fail "8. CONTROL: the stub records nothing, so 7 proves nothing"

echo "fails=$fails"
[[ $fails -eq 0 ]]
