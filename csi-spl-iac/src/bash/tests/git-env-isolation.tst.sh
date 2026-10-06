#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a test's fixture repo never writes the CALLER's repo (2026-10-06).
#   A git pre-push hook runs with GIT_DIR exported (in a linked worktree it is
#   <main>/.git/worktrees/<wt>, whose config IS the shared .git/config). The
#   iac suite runs under that hook, and with GIT_DIR inherited a fixture's
#   `git -C "$T/app" init` re-initialised the caller's repo (core.bare=true) and
#   its `remote add/set-url` rewrote the caller's origin: every worktree on the
#   box then failed to fetch or push.
#     1. run-all-tests.sh starts every test with no GIT_* location variable
#     2. spl-gh-wire / gh-set-ci-vars, run alone with GIT_DIR exported (a
#        worktree's gitdir, and a main .git), still pass and leave that repo's
#        remote.origin.url and core.bare unchanged
#   CONTROL: the fixture pattern itself, with GIT_DIR set and nothing unset,
#   does rewrite the throwaway repo (so the checks in 2 can see a leak).
#   Every repo here is a throwaway under mktemp; GIT_DIR never points at a
#   real checkout.
#------------------------------------------------------------------------------
# test-timeout: 240
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
URL=https://throwaway.invalid/caller.git

# --- the throwaway caller: a main repo with one linked worktree --------------
git init -q "$T/main"
git -C "$T/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$T/main" remote add origin "$URL"
git -C "$T/main" worktree add -q "$T/wt" -b wt
WT_GITDIR="$T/main/.git/worktrees/wt"
[[ -d "$WT_GITDIR" ]] || { echo "FAIL: no worktree gitdir $WT_GITDIR"; exit 1; }
reset_caller() { git --git-dir="$T/main/.git" config remote.origin.url "$URL"; git --git-dir="$T/main/.git" config core.bare false; }
caller_state() { echo "url=$(git --git-dir="$T/main/.git" config --get remote.origin.url) bare=$(git --git-dir="$T/main/.git" config --get core.bare)"; }
CLEAN="url=$URL bare=false"

# --- 1. run-all-tests.sh hands its tests no GIT_* location variable ----------
mkdir -p "$T/suite"
cp "$TEST_DIR/run-all-tests.sh" "$T/suite/"
cat >"$T/suite/probe.tst.sh" <<'PROBE'
env | grep -E '^GIT_(DIR|WORK_TREE|INDEX_FILE|COMMON_DIR|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|PREFIX)=' && exit 1
exit 0
PROBE
out=$(GIT_DIR="$WT_GITDIR" GIT_PREFIX='' GIT_WORK_TREE="$T/wt" GIT_INDEX_FILE="$WT_GITDIR/index" \
  GIT_COMMON_DIR="$T/main/.git" IAC_TEST_JOBS=1 bash "$T/suite/run-all-tests.sh" 2>&1)
[[ $? -eq 0 ]] && pass "1. run-all-tests.sh unsets the GIT_* location vars before a test" \
  || fail "1. a test saw a GIT_* location var: $out"

# --- 2. each fixture test with GIT_DIR exported ------------------------------
for t in spl-gh-wire gh-set-ci-vars; do
  for gd in "$WT_GITDIR" "$T/main/.git"; do
    reset_caller
    out=$(GIT_DIR="$gd" GIT_PREFIX='' bash "$TEST_DIR/$t.tst.sh" 2>&1); rc=$?
    st=$(caller_state)
    [[ $rc -eq 0 && "$st" == "$CLEAN" ]] \
      && pass "2. $t with GIT_DIR=${gd#"$T"/}: passes, caller untouched" \
      || fail "2. $t with GIT_DIR=${gd#"$T"/}: rc=$rc caller $st (want $CLEAN) $(grep -m3 '^FAIL' <<<"$out")"
  done
done

# --- CONTROL: the fixture pattern, nothing unset, does leak -------------------
reset_caller
mkdir -p "$T/ctl"
( export GIT_DIR="$WT_GITDIR"
  git -C "$T/ctl" init -q && git -C "$T/ctl" remote set-url origin git@github.com:o/app.git ) >/dev/null 2>&1
st=$(caller_state)
[[ "$st" != "$CLEAN" ]] && pass "CONTROL: an inherited GIT_DIR does rewrite the caller ($st)" \
  || fail "CONTROL: the inherited GIT_DIR left the caller as is: the checks in 2 prove nothing"

[[ "$fails" -eq 0 ]] && echo "PASS: all $(basename "$0") assertions"
exit "$fails"
