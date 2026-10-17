#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the pre-push gate survives errexit leaking in (SPL-2315). ./run
#          sources every *.func.sh into one shell; on 2026-10-17 a lane's file
#          ran a top-level `set -euo pipefail`, and with no baseline worktree
#          registered _pp_baseline_reap's grep exited 1: the gate died after
#          1 s, REFUSED, with no PART line and no summary.
#     1. set -euo pipefail forced on, no baseline worktree -> the gate reaches
#        its summary, passes, logs a WARN naming the leak, and errexit is back
#        on when it returns
#     2. same, a failing part -> the summary names it and the gate returns 1
#        (the verdict is unchanged), and errexit is back on
#     3. _pp_baseline_reap alone under errexit with nothing to reap returns 0
#     4. MUTATION control: the gate with the guard line and the reap's
#        `|| true` cut out (the old code) dies with no summary -- legs 1-3
#        prove the fix, not the harness
#   STUB parts (pass iff <tree>/<dir>/flag says 'good'), so nothing heavy runs.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$(cd "$TEST_DIR/../run" && pwd)
FUNC="$RUN_DIR/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

R="$ROOT/repo"
git init -q "$R"
for d in csi-spl-api csi-spl-iac; do mkdir -p "$R/$d"; echo good >"$R/$d/flag"; done
git -C "$R" add -A; git -C "$R" commit -qm seed; git -C "$R" branch trunk; git -C "$R" checkout -q -b lane
echo x >"$R/csi-spl-iac/a.sh"; echo y >"$R/csi-spl-api/a.go"; git -C "$R" add -A; git -C "$R" commit -qm lane

# One gate run in a fresh shell with errexit ON, as ./run is once a sourced
# file set it. Prints the gate's output, then "returned rc=<rc> opts=<$->" only
# if the shell survived the call; a bare call, so nothing masks errexit.
gate() {  # <func-file> [env...]
  local f="$1"; shift
  ( env "$@" PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$ROOT/pp.log" PRE_PUSH_CACHE="$ROOT/parts.green" \
      PRE_PUSH_PASS="$ROOT/tree.pass" PRE_PUSH_PIDFILE="$ROOT/pp.pid" PRE_PUSH_EXTRA_PATH='' RUN_DIR="$RUN_DIR" \
      bash -c 'for g in "$RUN_DIR"/check-pre-push-*.func.sh "$RUN_DIR"/check-release-note.func.sh; do . "$g"; done
        . "$0"
        do_log() { echo "LOG $*"; }
        do_check_dist_hygiene() { :; }; _pp_part_hygiene() { :; }
        _pp_missing_tools() { :; }; _ppl_plan() { _PPL_SELECTED=""; }; _ppl_typos() { :; }; _pp_release_note() { :; }
        _ppe_parts() { :; }; _ppf_parts() { :; }; _ppx_parts() { :; }; _pp_part_stale_tree() { :; }
        _pp_part_iac() { grep -q good "$1/csi-spl-iac/flag"; }
        _pp_part_api() { grep -q good "$1/csi-spl-api/flag" || { echo "FAIL: api flag is not good"; return 1; }; }
        set -euo pipefail
        trap '"'"'echo "returned rc=$? opts=$-"'"'"' EXIT
        do_check_pre_push
        echo "after the gate opts=$-"' "$f" ) 2>&1
}
has() { grep -qF -- "$2" <<<"$1"; }

# 1. errexit on, no baseline worktree, every part green
[[ "$(git -C "$R" worktree list --porcelain | grep -c csi-spl-pre-push-base)" == 0 ]] || fail "1. precondition" "a baseline worktree is registered"
out="$(gate "$FUNC")"
has "$out" "pre-push summary" && pass "1. errexit on, no baseline worktree -> the gate reaches its summary" \
  || fail "1. summary" "$out"
has "$out" "all parts PASSED" && pass "1. ... and passes" || fail "1. pass" "$out"
has "$out" "WARN pre-push: errexit (set -e) leaked in" && pass "1. ... and logs a WARN naming the leak" || fail "1. warn" "$out"
o="$(sed -n 's/^after the gate opts=//p' <<<"$out")"
[[ "$o" == *e* ]] && pass "1. ... and errexit is back on when it returns (opts=$o)" || fail "1. errexit restored" "opts='$o' out=$out"

# 2. errexit on, a failing part: same verdict as without errexit
rm -f "$ROOT/parts.green"
echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "api: bad"
out="$(gate "$FUNC")"
has "$out" "pre-push summary" && has "$out" "part(s) FAILED" && pass "2. a failing part -> the summary names the failure" \
  || fail "2. summary" "$out"
has "$out" "returned rc=1 opts=" && ! has "$out" "after the gate" \
  && pass "2. ... the gate returns 1 and the restored errexit stops the caller" || fail "2. rc" "$out"
git -C "$R" reset -q --hard HEAD~1

# 3. the reap alone under errexit, nothing to reap
out="$(bash -c 'do_log() { :; }; . "$0"; set -euo pipefail; _pp_baseline_reap "$1"; echo reaped' "$FUNC" "$R" 2>&1)"
eq "3. _pp_baseline_reap under errexit with nothing to reap returns 0" reaped "$out"

# 4. MUTATION: cut the guard line and the reap's `|| true` (the old code)
M="$ROOT/mut.func.sh"
sed -e '/^  \[\[ \$- == \*e\* \]\] && { set +e;/d' -e 's/^    done || true  # no leftover.*/    done/' "$FUNC" >"$M"
n="$(diff "$FUNC" "$M" | grep -c '^<')"
eq "4. MUTATION: two lines cut from the gate" 2 "$n"
rm -f "$ROOT/parts.green"
out="$(gate "$M")"
! has "$out" "pre-push summary" && ! has "$out" "after the gate" \
  && pass "4. MUTATION: the old code under errexit dies with no summary ($(sed -n 's/^returned //p' <<<"$out"))" \
  || fail "4. mutation" "$out"

echo ""
if [[ "$fails" -eq 0 ]]; then echo "check-pre-push-errexit: ALL PASS"; exit 0; fi
echo "check-pre-push-errexit: $fails FAILED"; exit 1
