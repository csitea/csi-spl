#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_workspace_repo_register (spec 143 releases-projects.md section
#          4.5, row B-6, SPL-5801): the operator registers a workspace's
#          project and repo on the hub. No network, no GCP, no hub: the hub
#          call is stubbed and observed.
#   1. run without WORKSPACE_PROJECT (through ./run and as a function) exits
#      non-zero and sends nothing; so does each other required input
#   2. DRY_RUN (default) prints the two requests, sends nothing
#   3. DRY_RUN=0 PUTs the project first, then the repo with project_slug
#   4. a hub refusal (404 unknown_project) -> FATAL, rc 1
#   5. a malformed input -> rc 1
# RED CONTROL (row B-6): give WORKSPACE_PROJECT a default in the action and
# case 1 fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

GOOD=(ENV=dev WORKSPACE_ID=ws-x WORKSPACE_PROJECT=web-shop WORKSPACE_REPO_SLUG=example-org/web-shop
  WORKSPACE_REPO_WEB_URL=https://example.com/example-org/web-shop)
export CALLS="$T/calls" BODIES="$T/bodies"
: >"$CALLS"; : >"$BODIES"

# act <env...> -> stdout = the action's; stderr in $T/err; rc kept. env -i:
# only the inputs named here reach the action.
act() {
  env -i PATH="$PATH" HOME="$T" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    CALLS="$CALLS" BODIES="$BODIES" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@test.invalid; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "$1 $2" >>"$CALLS"; printf "%s\n" "$3" >>"$BODIES"
      SPL_HUB_OP_STATUS=200 SPL_HUB_OP_BODY="{}"
      if [[ "$2" == */repos && -n "${STUB_REPO_CODE:-}" ]]; then
        SPL_HUB_OP_STATUS="$STUB_REPO_CODE" SPL_HUB_OP_BODY="{\"error\":\"unknown_project\",\"message\":\"no project\"}"
      fi
    }
    do_workspace_repo_register' 2>"$T/err"
}
without() { local v; for v in "${GOOD[@]}"; do [[ "$v" == "$1="* ]] || printf '%s\n' "$v"; done; }

# --- 1. no WORKSPACE_PROJECT, nor any other required input -------------------
mapfile -t no_project < <(without WORKSPACE_PROJECT)
out=$(cd "$PROJ_ROOT" && env "${no_project[@]}" ./run -a do_workspace_repo_register 2>&1); rc=$?
[[ $rc != 0 && "$out" != *"PUT /v1"* ]] && pass "./run without WORKSPACE_PROJECT -> rc $rc, nothing sent" \
  || fail "./run without WORKSPACE_PROJECT: rc $rc out '$out'"
for v in WORKSPACE_PROJECT WORKSPACE_ID WORKSPACE_REPO_SLUG WORKSPACE_REPO_WEB_URL; do
  mapfile -t args < <(without "$v")
  : >"$CALLS"
  out=$(act "${args[@]}" DRY_RUN=0); rc=$?
  [[ $rc == 1 && -z "$out" && ! -s "$CALLS" ]] && grep -q "FATAL $v must be set (no default)" "$T/err" &&
    pass "the action without $v -> rc 1, FATAL, no call" || fail "without $v: rc $rc out '$out' err '$(cat "$T/err")' calls '$(cat "$CALLS")'"
done

# --- 2. dry run ----------------------------------------------------------------
: >"$CALLS"
out=$(act "${GOOD[@]}"); rc=$?
[[ $rc == 0 && ! -s "$CALLS" && "$(grep -c '^PUT /v1/operator/workspaces/ws-x/' <<<"$out")" == 2 ]] &&
  pass "DRY_RUN (default) prints both requests, calls nothing" || fail "dry run: rc $rc out '$out' calls '$(cat "$CALLS")'"

# --- 3. DRY_RUN=0: project first, then the repo ----------------------------------
: >"$CALLS"; : >"$BODIES"
out=$(act "${GOOD[@]}" DRY_RUN=0 WORKSPACE_PROJECT_NAME="Web shop" WORKSPACE_REPO_PRIMARY=1); rc=$?
calls=$(paste -sd'|' "$CALLS")
[[ $rc == 0 && "$calls" == "PUT /v1/operator/workspaces/ws-x/projects/web-shop|PUT /v1/operator/workspaces/ws-x/repos" ]] &&
  pass "DRY_RUN=0 -> PUT the project, then PUT the repo" || fail "calls: rc $rc '$calls' err '$(cat "$T/err")'"
[[ "$(sed -n 1p "$BODIES" | jq -r .name)" == "Web shop" ]] && pass "the project carries its name" || fail "project body: $(sed -n 1p "$BODIES")"
repo=$(sed -n 2p "$BODIES")
[[ "$(jq -r '"\(.repo_slug) \(.project_slug) \(.repo_web_url) \(.trunk_branch) \(.auth_mode) \(.is_primary) \(.notes_public)"' <<<"$repo")" == \
  "example-org/web-shop web-shop https://example.com/example-org/web-shop main github_app true false" ]] &&
  pass "the repo carries its project_slug, url, defaults and flags" || fail "repo body: $repo"

# --- 4. the hub refuses --------------------------------------------------------
: >"$CALLS"
out=$(act "${GOOD[@]}" DRY_RUN=0 STUB_REPO_CODE=404); rc=$?
[[ $rc == 1 ]] && grep -q 'FATAL PUT /v1/operator/workspaces/ws-x/repos answered HTTP 404: unknown_project' "$T/err" &&
  pass "hub 404 unknown_project -> FATAL, rc 1" || fail "404: rc $rc err '$(cat "$T/err")'"

# --- 5. malformed inputs ---------------------------------------------------------
for bad in WORKSPACE_PROJECT=Web WORKSPACE_REPO_SLUG=NoSlash WORKSPACE_REPO_WEB_URL=http://example.com/x WORKSPACE_ID=-x; do
  : >"$CALLS"
  out=$(act "${GOOD[@]}" "$bad" DRY_RUN=0); rc=$?
  [[ $rc == 1 && ! -s "$CALLS" ]] && pass "$bad -> rc 1, no call" || fail "$bad: rc $rc calls '$(cat "$CALLS")'"
done

echo "workspace-repo-register: $fails failure(s)"
((fails == 0))
