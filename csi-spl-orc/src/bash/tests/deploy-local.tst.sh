#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the LOCAL cloud deploys do_deploy_hub / do_deploy_wui (owner order
#          2026-10-06: deploy from a box while the GitHub deploys are held)
#          and their shared half lib/bash/funcs/spl-local-deploy.func.sh.
#   1. ENV must be dev|prd, DRY_RUN 0|1 (both actions)
#   2. SHA defaults to origin/master head; a sha NOT on origin/master is
#      refused (a fixture repo with its own bare origin)
#   3. the lock: a second deploy of the same component + env is refused while
#      the first holds it; another env or component is not blocked
#   4. the checkout is a detached worktree of exactly the sha, and is removed
#   5. the mint: version + key read from do_release_version's output; a stale
#      target is rc 3; a malformed key is refused
#   6. DRY_RUN=1 (the default) prints the plan and makes NO gcloud, docker,
#      firebase or git-push call (stubs record every call)
#   7. build.json carries the sha and the minted version; config.json this
#      env's api base (wf 30's two files)
#   8. neither action touches .github/ or dispatches a workflow
# CONTROL: the stubs record every call, so "no call" means not made.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
orc_stub 0 gcloud docker firebase
printf '#!/bin/sh\necho "curl $*" >>"$STUB_LOG"\nexit 7\n' >"$T/stub/curl"
chmod +x "$T/stub/curl"

# fixture: a bare origin with two trunk commits, a clone, one commit only local
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
g() { git -C "$T/repo" -c user.name=t -c user.email=t@example.com "$@"; }
g checkout -q -b master
echo a >"$T/repo/a"; g add a; g commit -q -m a
echo b >"$T/repo/b"; g add b; g commit -q -m b
g push -q origin master 2>/dev/null
HEAD_SHA="$(g rev-parse HEAD)"
echo c >"$T/repo/c"; g add c; g commit -q -m local-only
LOCAL_SHA="$(g rev-parse HEAD)"

# lib <snippet> [VAR=value]... - the libs sourced, APP_PATH = the fixture repo
lib() {
  local s="$1"; shift
  env APP_PATH="$T/repo" SPL_ORG_APP=csi-spl ENV=dev DEPLOY_LOCK_DIR="$T/lock" DEPLOY_WORK_DIR="$T/work" \
    STUB_LOG="$T/calls.log" PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "'"$PROJ_ROOT"'"/lib/bash/funcs/*.func.sh; do source "$f"; done
    '"$s"
}

# --- 1. ENV / DRY_RUN ----------------------------------------------------------
SNIPPET='do_deploy_hub' in_orc ENV=qa >"$T/out" 2>&1 && fail "1. hub ENV=qa accepted" || pass "1. hub refuses ENV=qa"
SNIPPET='do_deploy_wui' in_orc ENV=qa >"$T/out" 2>&1 && fail "1. wui ENV=qa accepted" || pass "1. wui refuses ENV=qa"
SNIPPET='do_deploy_hub' in_orc DRY_RUN=yes >"$T/out" 2>&1 && fail "1. DRY_RUN=yes accepted" || pass "1. hub refuses DRY_RUN=yes"
SNIPPET='do_deploy_wui' in_orc DRY_RUN=2 >"$T/out" 2>&1 && fail "1. DRY_RUN=2 accepted" || pass "1. wui refuses DRY_RUN=2"

# --- 2. the sha -------------------------------------------------------------------
got="$(lib 'spl_ld_resolve_sha' 2>/dev/null)"
[[ "$got" == "$HEAD_SHA" ]] && pass "2. default sha = origin/master head" || fail "2. default sha '$got' != $HEAD_SHA"
got="$(lib 'spl_ld_resolve_sha' SHA="${HEAD_SHA:0:9}" 2>/dev/null)"
[[ "$got" == "$HEAD_SHA" ]] && pass "2. a short trunk sha resolves to the full one" || fail "2. short sha -> '$got'"
lib 'spl_ld_resolve_sha' SHA="$LOCAL_SHA" >"$T/out" 2>&1 && fail "2. a sha not on origin/master accepted" \
  || { grep -q 'is not on origin/master' "$T/out" && pass "2. a sha not on origin/master is refused" || fail "2. refusal text: $(cat "$T/out")"; }
lib 'spl_ld_resolve_sha' SHA=nosuchref >/dev/null 2>&1 && fail "2. junk sha accepted" || pass "2. a junk sha is refused"

# --- 3. the lock ----------------------------------------------------------------------
mkdir -p "$T/lock"
( exec 9>>"$T/lock/hub-dev.lock"; flock 9; touch "$T/held"; sleep 5 ) &
holder=$!
for _ in $(seq 1 50); do [[ -f "$T/held" ]] && break; sleep 0.1; done
lib 'spl_ld_lock hub' >"$T/out" 2>&1 && fail "3. a second hub-dev deploy took the held lock" \
  || { grep -q 'another hub deploy to dev holds' "$T/out" && pass "3. a second hub-dev deploy is refused" || fail "3. text: $(cat "$T/out")"; }
lib 'spl_ld_lock hub' ENV=prd >/dev/null 2>&1 && pass "3. hub-prd is not blocked by hub-dev" || fail "3. hub-prd blocked"
lib 'spl_ld_lock wui' >/dev/null 2>&1 && pass "3. wui-dev is not blocked by hub-dev" || fail "3. wui-dev blocked"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
lib 'spl_ld_lock hub' >/dev/null 2>&1 && pass "3. the lock is free once the holder is gone" || fail "3. lock still held"

# --- 4. the checkout ---------------------------------------------------------------------
out="$(lib 'spl_ld_checkout "$SHA" && git -C "$SPL_LD_WT" rev-parse HEAD && git -C "$SPL_LD_WT" status --porcelain | wc -l &&
  spl_ld_cleanup && [[ ! -d "$SPL_LD_WT" ]] && echo removed' SHA="$HEAD_SHA" 2>&1)"
[[ "$(sed -n 1p <<<"$out")" == "$HEAD_SHA" && "$(sed -n 2p <<<"$out")" == 0 ]] \
  && pass "4. the checkout is a clean tree of exactly the sha" || fail "4. checkout: $out"
grep -qx removed <<<"$out" && pass "4. the checkout is removed after the deploy" || fail "4. not removed: $out"
[[ "$(g worktree list | wc -l)" == 1 ]] && pass "4. no worktree is left registered" || fail "4. worktrees: $(g worktree list)"

# --- 5. the mint ---------------------------------------------------------------------------
mint() {  # <lines do_release_version writes to GITHUB_OUTPUT> <its rc>
  lib 'spl_ld_run() { local o; for a in "$@"; do [[ "$a" == GITHUB_OUTPUT=* ]] && o="${a#GITHUB_OUTPUT=}"; done
         printf "%b" "$MINT_OUT" >>"$o"; return "$MINT_RC"; }
       spl_ld_mint wt "$SHA"; rc=$?; echo "rc=$rc v=${SPL_LD_VERSION:-} k=${SPL_LD_KEY:-}"' \
    SHA="$HEAD_SHA" MINT_OUT="$1" MINT_RC="$2" 2>&1 | tail -1
}
[[ "$(mint 'version=1.5.7\nkey=1.5.7-c2\n' 0)" == "rc=0 v=1.5.7 k=1.5.7-c2" ]] && pass "5. version + key read from the mint" || fail "5. mint: $(mint 'version=1.5.7\nkey=1.5.7-c2\n' 0)"
[[ "$(mint 'stale=true\n' 3)" == rc=3* ]] && pass "5. a stale target is rc 3" || fail "5. stale: $(mint 'stale=true\n' 3)"
[[ "$(mint 'version=1.5.7\nkey=1.5.8\n' 0)" == rc=1* ]] && pass "5. a key that is not the version's is refused" || fail "5. bad key accepted"
[[ "$(mint '' 1)" == rc=1* ]] && pass "5. a failed mint is refused" || fail "5. failed mint accepted"

# --- 6. DRY_RUN=1 makes no cloud call ----------------------------------------------------
: >"$T/calls.log"
for a in do_deploy_hub do_deploy_wui; do
  SNIPPET='spl_ld_resolve_sha() { printf %s "'"$HEAD_SHA"'"; }
    spl_ld_run() { echo 1.5.7; }
    '"$a" in_orc >"$T/out.$a" 2>&1; rc=$?
  [[ $rc -eq 0 ]] && grep -q "PLAN dev ${HEAD_SHA:0:12}" "$T/out.$a" && grep -q 'v1.5.7 (predicted' "$T/out.$a" \
    && pass "6. $a DRY_RUN prints the plan with the predicted version" || fail "6. $a rc=$rc $(cat "$T/out.$a")"
done
grep -qE '^(gcloud|docker|firebase) ' "$T/calls.log" && fail "6. a dry run called: $(grep -E '^(gcloud|docker|firebase)' "$T/calls.log")" \
  || pass "6. the dry runs made no gcloud / docker / firebase call"

# --- 7. build.json + config.json ------------------------------------------------------------
mkdir -p "$T/wui/.output/public"
SNIPPET='cfg="$(_deploy_wui_cfg "$APP_PATH")" && _deploy_wui_stamp "'"$T/wui"'" "$cfg" "'"$HEAD_SHA"'" 1.5.7' in_orc SPL_ORG_APP=csi-spl >"$T/out" 2>&1
jq -e --arg s "$HEAD_SHA" '.commit == $s and .version == "1.5.7" and (.built_at | test("Z$"))' "$T/wui/.output/public/build.json" >/dev/null \
  && pass "7. build.json carries the sha and the minted version" || fail "7. build.json: $(cat "$T/wui/.output/public/build.json" 2>&1) $(cat "$T/out")"
api="$(jq -r '.env.dns.api_fqdn' "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.json")"
jq -e --arg a "https://$api" '.apiBase == $a and .envName == "dev"' "$T/wui/.output/public/config.json" >/dev/null \
  && pass "7. config.json carries the dev api base from cnf" || fail "7. config.json: $(cat "$T/wui/.output/public/config.json" 2>&1)"

# --- 8. no workflow in the path -------------------------------------------------------------
files=("$PROJ_ROOT/src/bash/run/deploy-hub.func.sh" "$PROJ_ROOT/src/bash/run/deploy-wui.func.sh" "$PROJ_ROOT/lib/bash/funcs/spl-local-deploy.func.sh")
grep -nE 'gh (workflow|api)|\.github/workflows/' "${files[@]}" && fail "8. a local deploy reaches a workflow" || pass "8. no gh workflow call, no .github/ path"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAIL(S)"; exit 1; }
