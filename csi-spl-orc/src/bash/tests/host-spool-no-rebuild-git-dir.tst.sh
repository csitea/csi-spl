#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: host-spool-no-rebuild.tst.sh never writes the CALLER's repo (spec 131
#          C5, c-829). A git hook (the pre-push gate) exports GIT_DIR, and
#          git -C does not override it, so the fixture's init/add/commit landed
#          5 commits in the repo that ran the test.
#   1. run under GIT_DIR=<a throwaway repo>/.git -> green, that repo's commit
#      count unchanged
#   2. CONTROL: the same test without its GIT_* unset -> the count grows
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
SUT="$TEST_DIR/host-spool-no-rebuild.tst.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Commits in the throwaway caller repo after running $1 with GIT_DIR exported.
leak_run() {
  local r="$T/caller.$2"
  mkdir -p "$r" && git -c user.name=t -c user.email=t@example.com -C "$r" init -q
  git -c user.name=t -c user.email=t@example.com -C "$r" commit -q --allow-empty -m base
  GIT_DIR="$r/.git" bash "$1" >"$T/out.$2" 2>&1
  echo "$? $(env -u GIT_DIR git -C "$r" rev-list --count HEAD)"
}

read -r rc n <<<"$(leak_run "$SUT" fixed)"
[[ "$rc" == 0 ]] && pass "1 green with GIT_DIR exported" || { fail "1 rc=$rc"; tail -5 "$T/out.fixed"; }
[[ "$n" == 1 ]] && pass "1 the caller repo still has 1 commit" || fail "1 the caller repo has $n commits (want 1)"

grep -v '^unset GIT_DIR ' "$SUT" >"$TEST_DIR/.host-spool-no-rebuild-ctl.$$.tst.sh"
read -r _ n <<<"$(leak_run "$TEST_DIR/.host-spool-no-rebuild-ctl.$$.tst.sh" control)"
rm -f "$TEST_DIR/.host-spool-no-rebuild-ctl.$$.tst.sh"
[[ "$n" -gt 1 ]] && pass "2 CONTROL without the unset the caller repo grows to $n commits" ||
  fail "2 CONTROL the leak did not reproduce ($n commits): the guard proves nothing"

echo "--- $fails failure(s)"
[[ "$fails" -eq 0 ]]
