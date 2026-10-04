#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the pre-push gate refuses only NEW failures, never pre-existing trunk
#          red (SPL-1252 deadlock fix), and never hangs (SPL-1251 timeout).
#          _pp_run re-runs a FAILED part against origin/master and blocks only
#          when it passes there.
#     1. green trunk + a break        -> FAIL (blocks): fails on HEAD, ok on base
#     2. red trunk + a real fix       -> PASS: passes on HEAD (no failure at all)
#     3. red trunk + still broken     -> WARN, NOT blocking: fails on HEAD AND base
#     4. a part that HANGS            -> killed by the timeout, counted, compared
#   A stub part passes iff <tree>/flag contains 'good'; HEAD and the base ref
#   carry different flags, so the same part yields different verdicts per tree.
#------------------------------------------------------------------------------
set -uo pipefail
# Defensive git-env scrub: this test creates commits in throwaway repos; a leaked
# GIT_DIR/GIT_INDEX_FILE (e.g. when run through the pre-push hook) would override
# "git -C" and land commits on the real pushing branch. The hook scrubs them; do
# it here too so the test is safe however it is invoked.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

do_log() { :; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

# a stub part: pass iff <tree>/flag contains 'good'
_stub_part() { grep -q good "$1/flag" 2>/dev/null; }

# Build a repo whose base ref 'trunkbase' has flag=$1 and whose worktree HEAD
# has flag=$2, then run one part and report the verdict via the arrays.
verdict() {  # <base-flag> <head-flag> <part-fn>
  local bflag="$1" hflag="$2" fn="$3" R
  R="$ROOT/r$RANDOM$RANDOM"
  {
    git init -q "$R"
    cd "$R"
    echo "$bflag" >flag; git add flag; git commit -qm base
    git branch trunkbase
    echo "$hflag" >flag; git add flag; git commit --allow-empty -qm head
    cd - >/dev/null
  } >/dev/null 2>&1
  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT=""
  _pp_run "stub" "$fn" "$R" trunkbase >/dev/null 2>&1
  _pp_baseline_cleanup "$R" >/dev/null 2>&1
  printf '%s|%s' "$_PP_FAILED" "${_PP_STAT[0]:-}"
}

# 1. green trunk (base good), broken HEAD (bad) -> NEW break, blocks
eq "1. green trunk + break -> FAIL (blocks)" "1|FAIL" "$(verdict good bad _stub_part)"
# 2. red trunk (base bad), fixed HEAD (good) -> the part passes, no failure
eq "2. red trunk + real fix -> PASS (lands)" "0|PASS" "$(verdict bad good _stub_part)"
# 3. red trunk (base bad), still broken HEAD (bad) -> pre-existing, WARN not block
eq "3. red trunk + still broken -> WARN (not blocking)" "0|WARN" "$(verdict bad bad _stub_part)"

# 4. the per-part timeout kills a hanging suite (the tf-steps hang) instead of
#    blocking the push forever. Point _pp_part_iac at a fake hanging suite.
FT="$ROOT/faketree"; mkdir -p "$FT/csi-spl-iac/src/bash/tests"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$FT/csi-spl-iac/src/bash/tests/run-all-tests.sh"
_pp_timeout=1
t0=$SECONDS; _pp_part_iac "$FT" >/dev/null 2>&1; trc=$?; tel=$((SECONDS - t0))
[ "$trc" -eq 124 ] && pass "4. a hanging suite is killed (rc 124)" || fail "4. a hanging suite is killed (rc 124)" "rc=$trc"
[ "$tel" -lt 10 ] && pass "4. ... within the timeout, not the full 30s" || fail "4. ... within the timeout" "took ${tel}s"

# 5. a dead run's baseline worktree is reaped; a live run's is kept; a TERM
#    mid-run removes the run's own one
R5="$ROOT/r5"; git init -q "$R5"; echo a >"$R5/f"; git -C "$R5" add -A; git -C "$R5" commit -qm s
dead="$(mktemp -d "${TMPDIR:-/tmp}/csi-spl-pre-push-base.999999.XXXXXX")"; rmdir "$dead"
git -C "$R5" worktree add -q --detach "$dead" HEAD
live="$(mktemp -d "${TMPDIR:-/tmp}/csi-spl-pre-push-base.$$.XXXXXX")"; rmdir "$live"
git -C "$R5" worktree add -q --detach "$live" HEAD
_pp_baseline_reap "$R5"
wl="$(git -C "$R5" worktree list)"
{ ! grep -qF "$dead" <<<"$wl" && [[ ! -d "$dead" ]]; } && pass "5a. a dead run's baseline worktree is reaped" || fail "5a. reap dead" "$wl"
grep -qF "$live" <<<"$wl" && pass "5b. a live run's baseline worktree is kept" || fail "5b. keep live" "$wl"
git -C "$R5" worktree remove --force "$live" >/dev/null 2>&1
( _PP_BASE_WT=""; _pp_baseline_tree "$R5" HEAD; echo "$_PP_BASE_WT" >"$ROOT/r5.wt"
  trap "_pp_baseline_cleanup '$R5'; exit 143" TERM; kill -TERM $BASHPID; sleep 5 ) 2>/dev/null
wt5="$(cat "$ROOT/r5.wt")"
{ [[ -n "$wt5" ]] && ! git -C "$R5" worktree list | grep -F "$wt5" >/dev/null && [[ ! -d "$wt5" ]]; } \
  && pass "5c. TERM mid-run removes the run's own baseline worktree" || fail "5c. term cleanup" "$(git -C "$R5" worktree list)"

# 6. regression: a part that fails on HEAD AND on the base (the re-check
#    builds a baseline worktree) leaves NO worktree behind after the run
R6="$ROOT/r6"; git init -q "$R6"; echo bad >"$R6/flag"; git -C "$R6" add -A; git -C "$R6" commit -qm base
git -C "$R6" branch trunkbase; git -C "$R6" commit -q --allow-empty -m head
( _PP_NAMES=(); _PP_STAT=(); _PP_SECS=(); _PP_FAILED=0; _PP_BASE_WT=""
  _pp_run "stub" _stub_part "$R6" trunkbase >/dev/null 2>&1; _pp_baseline_cleanup "$R6" >/dev/null 2>&1 )
n6="$(git -C "$R6" worktree list | wc -l)"
eq "6. a pre-existing re-check leaves no baseline worktree behind" 1 "$n6"

echo "-- check-pre-push-baseline.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
