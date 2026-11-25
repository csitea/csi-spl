#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_gh_master_ruleset (gh stubbed; no real ruleset is written):
#   1. DRY_RUN default, none live: prints the body (rules deletion +
#      non_fast_forward only, bypass_actors [], master + ruleset-proof/**,
#      active) and the diff, "would create", no write
#   2. DRY_RUN=0 creates it with ONE POST of that body, reads it back, prints the id
#   3. a second run is a no-op (no write, "already holds")
#   4. drift (an admin bypass added by hand): DRY_RUN shows it in the diff and
#      writes nothing; DRY_RUN=0 PUTs the body back, bypass_actors [] again
#   5. CONTROL: a write that does not stick (live keeps the bypass) -> rc 1,
#      the read-back says it does not hold
#   6. no repo (no GH_RULESET_REPO, no origin) -> FATAL, no gh write
#  6b. no GH_RULESET_REPO: the repo from an https origin; a GH_CI_VARS_REPO
#      of the caller never names it
#  6c. the repo from an ssh origin
#   7. one copy: the origin parse is _gscv_repo of gh-set-ci-vars.func.sh
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
require_action "$RUN/spl-gh-master-ruleset.func.sh"

mkdir -p "$T/bin" "$T/gh"
# gh: the repo's rulesets live as $GH/rs<id>.json; writes are logged
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh|$*" >>"$STUB_LOG"
case "$*" in
  "api repos/o/r/rulesets --paginate")
    shopt -s nullglob; f=("$GH"/rs*.json)
    if ((${#f[@]})); then jq -s 'map({id, name})' "${f[@]}"; else echo '[]'; fi ;;
  "api repos/o/r/rulesets/"[0-9]*) cat "$GH/rs${2##*/}.json" ;;
  "api -X POST repos/o/r/rulesets --input -") jq '. + {id: 42}' >"$GH/rs42.json" ;;
  "api -X PUT repos/o/r/rulesets/"[0-9]*" --input -")
    id="${4##*/}"; b="$(cat)"
    [[ "${STUB_IGNORE_PUT:-0}" == 1 ]] || jq --argjson i "$id" '. + {id: $i}' <<<"$b" >"$GH/rs$id.json" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$T/bin/gh"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u DRY_RUN -u GH_MASTER_RULESET_NAME PATH="$T/bin:$PATH" STUB_LOG="$T/calls.log" GH="$T/gh" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/no-repo" GH_RULESET_REPO=o/r "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; do_require_bin() { :; }
    source "$PROJ_PATH/src/bash/run/spl-gh-master-ruleset.func.sh"
    do_spl_gh_master_ruleset' >"$T/out" 2>&1
}
writes() { grep -cE 'gh\|api -X (POST|PUT|PATCH|DELETE)' "$T/calls.log"; }
holds() {
  jq -e '.name == "master-no-force" and .target == "branch" and .enforcement == "active"
    and .rules == [{type: "deletion"}, {type: "non_fast_forward"}] and .bypass_actors == []
    and .conditions.ref_name.include == ["refs/heads/master", "refs/heads/ruleset-proof/**"]' "$1" >/dev/null
}

# --- 1. dry run, nothing live -------------------------------------------------
act; rc=$?
sed -n '/^{/,/^}/p' "$T/out" >"$T/body.json"
[[ $rc == 0 && "$(writes)" == 0 ]] && holds "$T/body.json" && grep -q 'DRY_RUN would create ruleset master-no-force on o/r' "$T/out" \
  && grep -q '^> .*non_fast_forward' "$T/out" \
  && pass "1. DRY_RUN: prints the body (2 rules, no bypass, master + proof refs) and the diff, no write" || fail "1. rc=$rc $(cat "$T/out")"

# --- 2. create ----------------------------------------------------------------
act DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(writes)" == 1 ]] && grep -q 'gh|api -X POST repos/o/r/rulesets --input -' "$T/calls.log" && holds "$T/gh/rs42.json" \
  && grep -q 'OK read-back ruleset_id=42 ' "$T/out" \
  && pass "2. DRY_RUN=0: one POST of the body, read back, id 42 printed" || fail "2. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 3. idempotent ------------------------------------------------------------
act DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(writes)" == 0 ]] && grep -q 'already holds: no change' "$T/out" && grep -q 'ruleset_id=42' "$T/out" \
  && pass "3. a second run is a no-op" || fail "3. rc=$rc $(cat "$T/out")"

# --- 4. drift -----------------------------------------------------------------
jq '.bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]' "$T/gh/rs42.json" >"$T/x" && mv "$T/x" "$T/gh/rs42.json"
act; rc=$?
[[ $rc == 0 && "$(writes)" == 0 ]] && grep -q '^< .*RepositoryRole' "$T/out" && grep -q 'DRY_RUN would update ruleset' "$T/out" \
  && pass "4. drift: DRY_RUN shows the bypass in the diff, no write" || fail "4. dry: rc=$rc $(cat "$T/out")"
act DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(writes)" == 1 ]] && grep -q 'gh|api -X PUT repos/o/r/rulesets/42 --input -' "$T/calls.log" && holds "$T/gh/rs42.json" \
  && pass "4. drift: DRY_RUN=0 PUTs the body back, bypass_actors [] again" || fail "4. put: rc=$rc $(cat "$T/out") $(cat "$T/gh/rs42.json")"

# --- 5. CONTROL: a write that does not stick ----------------------------------
jq '.bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]' "$T/gh/rs42.json" >"$T/x" && mv "$T/x" "$T/gh/rs42.json"
act DRY_RUN=0 STUB_IGNORE_PUT=1; rc=$?
[[ $rc == 1 ]] && grep -q 'ERROR read-back of ruleset 42 does not hold' "$T/out" \
  && pass "5. CONTROL: a bypass still live after the write -> rc 1, read-back refuses" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6. no repo ---------------------------------------------------------------
act GH_RULESET_REPO=; rc=$?
[[ $rc == 1 && ! -s "$T/calls.log" ]] && grep -q 'FATAL no GitHub repo' "$T/out" \
  && pass "6. no repo -> FATAL, no gh call" || fail "6. rc=$rc $(cat "$T/out")"

# --- 6b/6c. the repo from the origin remote -----------------------------------
mkdir -p "$T/app"; git -C "$T/app" init -q
[[ "$(git -C "$T/app" rev-parse --absolute-git-dir)" == "$T/app/.git" ]] || { echo "FAIL: fixture repo is not isolated"; exit 1; }
git -C "$T/app" remote add origin https://github.com/o/r.git
act GH_RULESET_REPO= APP_PATH="$T/app" GH_CI_VARS_REPO=wrong/leak; rc=$?
[[ $rc == 0 ]] && grep -q 'INFO wanted ruleset master-no-force on o/r:' "$T/out" && ! grep -q 'wrong/leak' "$T/out" "$T/calls.log" \
  && pass "6b. no GH_RULESET_REPO: o/r from an https origin, GH_CI_VARS_REPO does not leak" || fail "6b. rc=$rc $(cat "$T/out")"
git -C "$T/app" remote set-url origin git@github.com:o/r.git
act GH_RULESET_REPO= APP_PATH="$T/app"; rc=$?
[[ $rc == 0 ]] && grep -q 'INFO wanted ruleset master-no-force on o/r:' "$T/out" \
  && pass "6c. no GH_RULESET_REPO: o/r from an ssh origin" || fail "6c. rc=$rc $(cat "$T/out")"

# --- 7. one copy --------------------------------------------------------------
F7="$RUN/spl-gh-master-ruleset.func.sh"
own=$(grep -nE '_sgmr_repo|remote get-url origin' "$F7" | grep -vE '^[0-9]+:\s*#')
[[ -z "$own" ]] && grep -qF '_gscv_repo "${GH_RULESET_REPO:-}"' "$F7" \
  && pass "7. one copy: spl-gh-master-ruleset.func.sh parses the repo only via _gscv_repo of gh-set-ci-vars.func.sh" \
  || fail "7. one copy: spl-gh-master-ruleset.func.sh keeps its own repo parse, or no _gscv_repo call: $(tr '\n' ' ' <<<"$own")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
