#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_deploy_record (spec 143 T026, SPL-2788), the deploy step's
#          report to the hub's POST /v1/operator/deploys, and its two
#          workflow steps. No network, no GCP, no hub:
#   1. DRY_RUN (default) prints the body and calls nothing; the sha defaults
#      to GITHUB_SHA, the run id to GITHUB_RUN_ID
#   2. DRY_RUN=0 POSTs that body once to /v1/operator/deploys and prints the
#      stored row; a hub refusal is FATAL, rc 1
#   3. argument validation: ENV, component, version, status, sha, run id
#   4. GATE: 20 (hub) and 30 (WUI) each carry the step in the deploy job,
#      after the roll / the firebase deploy, with continue-on-error (a
#      failed report never fails the deploy), DRY_RUN=0, the right
#      component, the minted version, and no key literal. RED CONTROL: the
#      same check on a copy with the step removed fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SHA=0123456789abcdef0123456789abcdef01234567

# act <env...> -> stdout = the action's stdout; stderr in $T/err; rc kept
act() {
  env -u GITHUB_SHA -u GITHUB_RUN_ID PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    # the cloud side, stubbed: only the hub call is observed
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@test.invalid; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "$1 $2" >>"$CALLS"; printf "%s\n" "$3" >>"$BODIES"
      SPL_HUB_OP_STATUS="${STUB_CODE:-200}"
      SPL_HUB_OP_BODY="$(jq -c "{deploy: (. + {deploy_id: \"d-1\", source: \"ci\"}), stored: true}" <<<"$3")"
    }
    do_spl_deploy_record' 2>"$T/err"
}
export CALLS="$T/calls" BODIES="$T/bodies"
: >"$CALLS"; : >"$BODIES"

# --- 1. dry run -------------------------------------------------------------
out=$(act ENV=dev DEPLOY_COMPONENT=hub DEPLOY_VERSION=3.2.5 GITHUB_SHA=$SHA GITHUB_RUN_ID=185623910); rc=$?
want='{"env":"dev","component":"hub","version":"3.2.5","commit_sha":"'$SHA'","status":"success","workflow_run_id":"185623910"}'
[[ $rc == 0 && "$out" == "$want" ]] && pass "DRY_RUN default: the body, sha and run id from GITHUB_SHA / GITHUB_RUN_ID" \
  || fail "dry body: rc $rc '$out' err '$(cat "$T/err")'"
[[ ! -s "$CALLS" ]] && pass "DRY_RUN (default) calls nothing" || fail "dry run called: $(cat "$CALLS")"
out=$(act ENV=prd DEPLOY_COMPONENT=wui DEPLOY_VERSION=v1.0.1-c2 DEPLOY_SHA=$SHA DEPLOY_STATUS=failed); rc=$?
[[ $rc == 0 && "$(jq -r '"\(.env) \(.component) \(.version) \(.status) \(has("workflow_run_id"))"' <<<"$out")" == "prd wui v1.0.1-c2 failed false" ]] &&
  pass "a failed WUI deploy past the wrap, no run id -> no workflow_run_id field" || fail "failed wui: rc $rc '$out'"

# --- 2. DRY_RUN=0 posts once ------------------------------------------------
out=$(act ENV=dev DRY_RUN=0 DEPLOY_COMPONENT=hub DEPLOY_VERSION=3.2.5 DEPLOY_SHA=$SHA DEPLOY_RUN_ID=7); rc=$?
if [[ $rc == 0 && "$(cat "$CALLS")" == "POST /v1/operator/deploys" && "$(jq -r .workflow_run_id "$BODIES")" == 7 ]]; then
  pass "DRY_RUN=0 -> one POST /v1/operator/deploys carrying the body"
else fail "post: rc $rc calls '$(cat "$CALLS")' err '$(cat "$T/err")'"; fi
[[ "$(jq -r '"\(.deploy_id) \(.stored) \(.sha)"' <<<"$out")" == "d-1 true $SHA" ]] && grep -q "^OK the dev hub deploy of ${SHA:0:8} recorded" "$T/err" &&
  pass "prints the stored row and an OK line" || fail "summary: '$out' err '$(cat "$T/err")'"
out=$(act ENV=dev DRY_RUN=0 DEPLOY_COMPONENT=hub DEPLOY_VERSION=3.2.5 DEPLOY_SHA=$SHA STUB_CODE=403); rc=$?
[[ $rc == 1 ]] && grep -q 'FATAL POST /v1/operator/deploys answered HTTP 403' "$T/err" &&
  pass "hub HTTP 403 -> FATAL, rc 1 (the workflow step's continue-on-error keeps the deploy green)" || fail "403: rc $rc err '$(cat "$T/err")'"

# --- 3. argument validation -------------------------------------------------
: >"$CALLS"
for bad in "ENV=lde" "ENV=" "DEPLOY_COMPONENT=inf" "DEPLOY_COMPONENT=" "DEPLOY_VERSION=3.2" "DEPLOY_VERSION=latest" \
  "DEPLOY_STATUS=ok" "DEPLOY_SHA=${SHA:0:8}" "DEPLOY_SHA=${SHA^^}" "DEPLOY_RUN_ID=a;b"; do
  # shellcheck disable=SC2086 # the case is a word list on purpose
  out=$(act ENV=dev DRY_RUN=0 DEPLOY_COMPONENT=hub DEPLOY_VERSION=3.2.5 DEPLOY_SHA=$SHA $bad); rc=$?
  [[ $rc == 1 && -z "$out" ]] && pass "$bad -> rc 1" || fail "$bad: rc $rc out '$out'"
done
[[ ! -s "$CALLS" ]] && pass "no refused argument reached the hub" || fail "a refused argument called: $(cat "$CALLS")"

# --- 4. the workflow steps --------------------------------------------------
STEP='Record the deploy (do_spl_deploy_record)'
# check_wf <workflow file> <component> <the step that deploys> -> rc 0 when wired
check_wf() {
  local f="$1" comp="$2" after="$3" names i j s
  names="$(yq -r '.jobs.deploy.steps[].name // ""' "$f")"
  i="$(grep -nxF -- "$after" <<<"$names" | cut -d: -f1)"
  j="$(grep -nxF -- "$STEP" <<<"$names" | cut -d: -f1)"
  [[ -n "$i" && -n "$j" && "$j" -gt "$i" ]] || { echo "step missing or before '$after' ($i/$j)"; return 1; }
  s="$(yq -o=json ".jobs.deploy.steps[] | select(.name == \"$STEP\")" "$f")"
  jq -e --arg c "$comp" '.["continue-on-error"] == true
    and (.run | test("DRY_RUN=0") and test("DEPLOY_COMPONENT=" + $c + " ") and test("-a do_spl_deploy_record$"))
    and (.env.DEPLOY_VERSION | test("steps\\.ver\\.outputs\\.version"))
    and (.env.DEPLOY_STATUS | test("job\\.status"))
    and (.if | test("!cancelled\\(\\)"))' <<<"$s" >/dev/null || { echo "step wiring: $s"; return 1; }
  ! grep -qiE 'private_key|BEGIN [A-Z ]*PRIVATE' <<<"$s" || { echo "key literal in the step"; return 1; }
}
WF="$APP_ROOT/.github/workflows"
msg=$(check_wf "$WF/20_hub-build-deploy.yml" hub "Roll the 030 service to the minted image") &&
  pass "GATE 20: the hub step follows the roll, continue-on-error, DRY_RUN=0, component hub, minted version" || fail "20: $msg"
msg=$(check_wf "$WF/30_wui-build-deploy.yml" wui "firebase deploy --only hosting") &&
  pass "GATE 30: the WUI step follows the firebase deploy, continue-on-error, DRY_RUN=0, component wui, minted version" || fail "30: $msg"
[[ "$(yq -r '.jobs.deploy.steps[] | select(.name == "'"$STEP"'") | .env.ENV' "$WF/30_wui-build-deploy.yml")" == '${{ matrix.environment }}' ]] &&
  pass "30's step names ENV itself (the job sets none)" || fail "30 step has no ENV"
for wf in 20_hub-build-deploy 30_wui-build-deploy; do
  yq "del(.jobs.deploy.steps[] | select(.name == \"$STEP\"))" "$WF/$wf.yml" >"$T/$wf.yml"
done
! check_wf "$T/20_hub-build-deploy.yml" hub "Roll the 030 service to the minted image" >/dev/null &&
  ! check_wf "$T/30_wui-build-deploy.yml" wui "firebase deploy --only hosting" >/dev/null &&
  pass "RED CONTROL: a copy of 20 and 30 without the step fails the check" || fail "RED CONTROL: the check passed with the step removed"

echo "spl-deploy-record: $fails failure(s)"
((fails == 0))
