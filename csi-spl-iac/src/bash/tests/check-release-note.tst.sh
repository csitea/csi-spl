#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the pre-push part `release-note` (spec 065 L2) in WARNING mode.
#   1. a full note (six trailers) passes, no warning
#   2. a missing trailer warns, names the commit and the key, and exits 0
#   3. an empty trailer warns as "empty" and exits 0
#   4. a doc-only commit with Lay-What + Lay-Why passes
#   5. 'Release-Note: skip' + Lay-Why passes
#   6. a git revert + Lay-Why passes
#   7. a merge commit is skipped (merge=1, not counted)
#   8. trailers NOT in the last paragraph do not count
#   9. the RELEASE_NOTE_CHECK line counts commits and warnings over a range
#  10. do_check_pre_push writes the release-note verdict and never fails on it
#  11. an empty range logs SKIP-untouched
#  12. PRE_PUSH_LINT=0 skips it, like every lint part
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$T" init -q -b master
echo x >"$T/seed.txt"; git -C "$T" add -A; git -C "$T" commit -qm seed
git -C "$T" branch base

do_log() { echo "$*"; }
do_check_dist_hygiene() { return 0; }
# shellcheck source=../run/check-pre-push.func.sh
. "$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"
# shellcheck source=../run/check-release-note.func.sh
. "$PROJ_ROOT/src/bash/run/check-release-note.func.sh"

FULL=$'Lay-What: a thing changed\nLay-How: it was changed\nLay-Why: it was wrong\nTech-What: t\nTech-How: t\nTech-Why: t'

# commit <file> <message>: one commit touching <file> on HEAD
commit() { echo "$RANDOM" >>"$T/$1"; git -C "$T" add -A; git -C "$T" commit -qm "$2"; }
# check <base>: run the action, print its output, keep its rc in $rc
check() { rc=0; out="$(RELEASE_NOTE_TREE="$T" RELEASE_NOTE_BASE="$1" do_check_release_note 2>&1)" || rc=$?; }
field() { sed -n "s/^RELEASE_NOTE_CHECK .* $1=\([0-9]*\).*/\1/p" <<<"$out"; }

# 1. full note
commit a.sh "fix: a"$'\n\nbody\n\n'"$FULL"
check HEAD~1
{ [[ "$rc" -eq 0 && "$(field warn)" == 0 && "$(field ok)" == 1 ]] && ! grep -q 'WARN release-note' <<<"$out"; } \
  && pass "1. a full note passes" || fail "1. a full note passes" "$out"

# 2. missing trailer
commit a.sh "fix: b"$'\n\n'"$(grep -v '^Tech-How' <<<"$FULL")"
check HEAD~1
sha="$(git -C "$T" rev-parse HEAD | cut -c1-8)"
{ [[ "$rc" -eq 0 && "$(field warn)" == 1 ]] && grep -q "WARN release-note: $sha (full) missing Tech-How -- fix: b" <<<"$out"; } \
  && pass "2. a missing trailer warns with exit 0" || fail "2. a missing trailer warns with exit 0" "rc=$rc $out"

# 2b. no note at all names every key
commit a.sh "fix: none"
check HEAD~1
{ [[ "$rc" -eq 0 ]] && grep -q "missing Lay-What Lay-How Lay-Why Tech-What Tech-How Tech-Why" <<<"$out"; } \
  && pass "2b. no note names all six keys" || fail "2b. no note names all six keys" "$out"

# 3. empty trailer
commit a.sh "fix: c"$'\n\n'"$(sed 's/^Lay-How:.*/Lay-How:   /' <<<"$FULL")"
check HEAD~1
{ [[ "$rc" -eq 0 && "$(field warn)" == 1 ]] && grep -q "(full) empty Lay-How" <<<"$out"; } \
  && pass "3. an empty trailer warns with exit 0" || fail "3. an empty trailer warns with exit 0" "$out"

# 4. doc-only: Lay-What + Lay-Why suffice; a code file needs all six
commit d.md "docs: d"$'\n\nLay-What: the text says more\nLay-Why: it was unclear'
check HEAD~1
{ [[ "$(field warn)" == 0 && "$(field doc)" == 1 ]]; } \
  && pass "4. doc-only with Lay-What + Lay-Why passes" || fail "4. doc-only with Lay-What + Lay-Why passes" "$out"
commit d.txt "docs: d2"$'\n\nLay-What: the text says more\nLay-Why: it was unclear'
check HEAD~1
[[ "$(field warn)" == 1 ]] && pass "4b. the doc form does not cover a non-.md file" || fail "4b. the doc form does not cover a non-.md file" "$out"

# 5. skip
commit t.tst.sh "test: e"$'\n\nRelease-Note: skip\nLay-Why: a test only'
check HEAD~1
{ [[ "$(field warn)" == 0 && "$(field skip)" == 1 ]]; } \
  && pass "5. Release-Note: skip + Lay-Why passes" || fail "5. Release-Note: skip + Lay-Why passes" "$out"
commit t.tst.sh "test: e2"$'\n\nRelease-Note: skip'
check HEAD~1
grep -q "(skip) missing Lay-Why" <<<"$out" && pass "5b. skip without Lay-Why warns" || fail "5b. skip without Lay-Why warns" "$out"

# 6. revert
git -C "$T" revert --no-edit HEAD >/dev/null
git -C "$T" commit -q --amend -m "$(git -C "$T" log -1 --format=%B)"$'\n\nLay-Why: the change was wrong'
check HEAD~1
{ [[ "$(field warn)" == 0 && "$(field revert)" == 1 ]]; } \
  && pass "6. a revert + Lay-Why passes" || fail "6. a revert + Lay-Why passes" "$out"

# 7. merge commit skipped
m0="$(git -C "$T" rev-parse HEAD)"
git -C "$T" checkout -q -b side; commit s.sh "fix: side"$'\n\n'"$FULL"
git -C "$T" checkout -q master; commit a.sh "fix: main"$'\n\n'"$FULL"
git -C "$T" merge -q --no-ff -m "Merge side" side
check "$m0"
{ [[ "$(field merge)" == 1 && "$(field commits)" == 2 && "$(field warn)" == 0 ]]; } \
  && pass "7. a merge commit is skipped" || fail "7. a merge commit is skipped" "$out"

# 8. trailers in a middle paragraph, then a prose paragraph, do not count
commit a.sh "fix: f"$'\n\n'"$FULL"$'\n\nA closing remark.'
check HEAD~1
[[ "$(field warn)" == 1 ]] && pass "8. trailers must be the last paragraph" || fail "8. trailers must be the last paragraph" "$out"

# 9. counts over the whole range
check base
{ [[ "$rc" -eq 0 && "$(field commits)" -ge 11 && "$(field warn)" == 6 && "$(field merge)" == 1 ]] \
  && grep -q 'WARNING mode, not blocking' <<<"$out"; } \
  && pass "9. the range line counts commits=$(field commits) warn=6" || fail "9. range counts" "$out"

# 10. through do_check_pre_push: a WARN verdict line, the push still passes.
# The scanner lint parts are stubbed out (not under test here); PRE_PUSH_LINT=0
# would skip release-note too, as it skips every lint part.
_ppl_plan() { _PPL_SELECTED=""; _PPL_FAST=""; _PPL_SLOW=""; }
_ppl_typos() { :; }
log="$T/pp.log"
rc=0; out="$(PRE_PUSH_TREE="$T" PRE_PUSH_BASE=base PRE_PUSH_LOG="$log" PRE_PUSH_CACHE="$T/pp.cache" \
  do_check_pre_push 2>&1)" || rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q 'PART release-note WARN-release-note .*warn=6' "$log" \
  && grep -q 'WARN .*release-note (WARN only' <<<"$out"; } \
  && pass "10. do_check_pre_push logs the WARN and still passes" || fail "10. pre-push wiring" "rc=$rc $(cat "$log" 2>/dev/null) $out"

# 11. empty range -> SKIP-untouched
: >"$log"
PRE_PUSH_TREE="$T" PRE_PUSH_BASE=HEAD PRE_PUSH_LOG="$log" PRE_PUSH_CACHE="$T/pp.cache" \
  do_check_pre_push >/dev/null 2>&1
grep -q 'PART release-note SKIP-untouched' "$log" \
  && pass "11. an empty range is SKIP-untouched" || fail "11. empty range" "$(cat "$log")"

# 12. PRE_PUSH_LINT=0 (the lint rollback knob) skips it with the other lint parts
: >"$log"
PRE_PUSH_TREE="$T" PRE_PUSH_BASE=base PRE_PUSH_LOG="$log" PRE_PUSH_CACHE="$T/pp.cache" PRE_PUSH_LINT=0 \
  do_check_pre_push >/dev/null 2>&1
! grep -q 'PART release-note' "$log" \
  && pass "12. PRE_PUSH_LINT=0 skips it" || fail "12. PRE_PUSH_LINT=0" "$(cat "$log")"

echo ""
if [[ "$fails" -gt 0 ]]; then echo "check-release-note: $fails FAILED"; exit 1; fi
echo "check-release-note: all PASSED"
