#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_attach_name_repair_revoked (SPL-1808 option A): the hub call
#          is a stub that records the body and answers a canned status.
#   1. no TENANT_IDS, or a bad slug, fails before any call
#   2. DRY_RUN (default) sends dry_run:true, one call per workspace
#   3. DRY_RUN=0 sends dry_run:false and prints the counts
#   4. a failed message, or a 404 (old hub), fails the run
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux

run() {
  : >"$T/calls"
  SNIPPET='do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
spl_hub_operator_url() { :; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam.gserviceaccount.com; }
do_gcp_require_live_account() { :; }
spl_hub_operator_call() { echo "$1 $2 $3" >>"$CALLS"; SPL_HUB_OP_STATUS="${STUB_CODE:-200}"; SPL_HUB_OP_BODY="${STUB_BODY:-}"; }
do_spl_attach_name_repair_revoked'
  in_orc SNIPPET="$SNIPPET" CALLS="$T/calls" "$@" >"$T/o" 2>&1
  rc=$?
}
OK='{"tenant":"t1","dry_run":false,"found":130,"live_box":5,"messages":125,"renamed":350,"unknown":2,"by_type":{"png":340,"md":10},"samples":[],"failed":[],"more":false}'
BAD='{"tenant":"t1","dry_run":false,"found":3,"live_box":0,"messages":2,"renamed":2,"unknown":0,"by_type":{},"samples":[],"failed":[{"msg_id":"x","error":"blob: not found"}],"more":false}'

run; r1=$rc; run TENANT_IDS=T1; r2=$rc
[[ $r1 -ne 0 && $r2 -ne 0 && ! -s "$T/calls" ]] && grep -q 'TENANT_ID must be a tenant slug' "$T/o" &&
  pass "1. no TENANT_IDS / a bad slug fails before any call" || fail "1. r1=$r1 r2=$r2 $(cat "$T/o")"

run TENANT_IDS='t1,csitea' STUB_BODY="$OK"
[[ $rc -eq 0 && "$(grep -c '^POST /v1/operator/attachment-names/repair ' "$T/calls")" == 2 && "$(grep -c '"dry_run":true' "$T/calls")" == 2 ]] &&
  grep -q '"tenant":"csitea"' "$T/calls" && grep -q 'OK DRY_RUN nothing was renamed' "$T/o" &&
  pass "2. the dry run sends dry_run:true once per workspace" || fail "2. rc=$rc $(cat "$T/calls") $(cat "$T/o")"

run TENANT_IDS=t1 DRY_RUN=0 STUB_BODY="$OK"
[[ $rc -eq 0 ]] && grep -q '"dry_run":false' "$T/calls" && grep -q 'OK t1: 125 message(s), 350 file(s) named, 2 unknown kept, 5 left to their live box' "$T/o" &&
  pass "3. DRY_RUN=0 sends dry_run:false and prints the counts" || fail "3. rc=$rc $(cat "$T/o")"

run TENANT_IDS=t1 DRY_RUN=0 STUB_BODY="$BAD"; r1=$rc
run TENANT_IDS=t1 DRY_RUN=0 STUB_CODE=404 STUB_BODY='{}'; r2=$rc
[[ $r1 -ne 0 && $r2 -ne 0 ]] && grep -q 'deploy the hub first' "$T/o" &&
  pass "4. a failed message or a 404 fails the run" || fail "4. r1=$r1 r2=$r2 $(cat "$T/o")"

echo "fails=$fails"
exit $(( fails > 0 ))
