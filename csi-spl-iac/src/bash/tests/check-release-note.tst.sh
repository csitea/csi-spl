#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the pre-push part `release-note` (spec 065 L2, L11 the refusal).
#   1. a full note (six trailers) passes, exit 0
#   2. a missing trailer REFUSES (exit 1), names the commit and the key; the
#      red control: the same commit amended with its note passes
#   3. an empty trailer refuses as "empty"
#   4. a doc-only commit with Lay-What + Lay-Why passes; without Lay-Why refuses
#   5. 'Release-Note: skip' + Lay-Why passes; without Lay-Why refuses
#   6. a git revert + Lay-Why passes
#   7. a merge commit is skipped (merge=1, not counted)
#   8. trailers NOT in the last paragraph do not count
#   9. the RELEASE_NOTE_CHECK line counts commits and misses over a range;
#      RELEASE_NOTE_MODE=warn measures with exit 0; an unknown mode is exit 2
#  10. do_check_pre_push FAILS on a commit without its note (rc 1, verdict FAIL)
#  11. an empty range logs SKIP-untouched
#  12. PRE_PUSH_LINT=0 and the override skip it, as before (CI is their backstop)
#  13. the hook's PASS-tree shortcut still refuses an amend that dropped the note
#  14. a git note on refs/notes/release-notes stands in for the message in CI,
#      never in the pre-push part (only the message counts before the push)
#  15. RELEASE_NOTE_BASE=switch checks every commit after the switch commit (CI)
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); G=$(mktemp -d); trap 'rm -rf "$T" "$G"' EXIT
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
{ [[ "$rc" -eq 1 && "$(field warn)" == 1 ]] && grep -q "FAIL release-note: $sha (full) missing Tech-How -- fix: b" <<<"$out" \
  && grep -q "the push is REFUSED.*git commit --amend.*git rebase -i.*release-notes.md" <<<"$out" \
  && [[ "$(grep -cE '^(Lay|Tech)-(What|How|Why): <' <<<"$out")" == 6 ]]; } \
  && pass "2. a missing trailer refuses (exit 1), names the commit, the key, the fix and prints the six-trailer template" \
  || fail "2. a missing trailer refuses (exit 1), names the commit, the key, the fix and prints the six-trailer template" "rc=$rc $out"
# red control: the same commit with its note added by an amend passes
git -C "$T" commit -q --amend -m "fix: b"$'\n\n'"$FULL"
check HEAD~1
[[ "$rc" -eq 0 && "$(field warn)" == 0 ]] \
  && pass "2. control: amended with its note it passes" || fail "2. control: amended with its note it passes" "rc=$rc $out"

# 2b. no note at all names every key
commit a.sh "fix: none"
check HEAD~1
{ [[ "$rc" -eq 1 ]] && grep -q "missing Lay-What Lay-How Lay-Why Tech-What Tech-How Tech-Why" <<<"$out"; } \
  && pass "2b. no note names all six keys" || fail "2b. no note names all six keys" "$out"

# 3. empty trailer
commit a.sh "fix: c"$'\n\n'"$(sed 's/^Lay-How:.*/Lay-How:   /' <<<"$FULL")"
check HEAD~1
{ [[ "$rc" -eq 1 && "$(field warn)" == 1 ]] && grep -q "(full) empty Lay-How" <<<"$out"; } \
  && pass "3. an empty trailer refuses (exit 1)" || fail "3. an empty trailer refuses (exit 1)" "rc=$rc $out"

# 4. doc-only: Lay-What + Lay-Why suffice; a code file needs all six
commit d.md "docs: d"$'\n\nLay-What: the text says more\nLay-Why: it was unclear'
check HEAD~1
{ [[ "$rc" -eq 0 && "$(field warn)" == 0 && "$(field doc)" == 1 ]]; } \
  && pass "4. doc-only with Lay-What + Lay-Why passes" || fail "4. doc-only with Lay-What + Lay-Why passes" "$out"
commit d.md "docs: d1"$'\n\nLay-What: the text says more'
check HEAD~1
{ [[ "$rc" -eq 1 ]] && grep -q "(doc) missing Lay-Why" <<<"$out"; } \
  && pass "4a. doc-only without Lay-Why refuses" || fail "4a. doc-only without Lay-Why refuses" "rc=$rc $out"
commit d.txt "docs: d2"$'\n\nLay-What: the text says more\nLay-Why: it was unclear'
check HEAD~1
[[ "$rc" -eq 1 && "$(field warn)" == 1 ]] && pass "4b. the doc form does not cover a non-.md file" || fail "4b. the doc form does not cover a non-.md file" "$out"

# 5. skip
commit t.tst.sh "test: e"$'\n\nRelease-Note: skip\nLay-Why: a test only'
check HEAD~1
{ [[ "$rc" -eq 0 && "$(field warn)" == 0 && "$(field skip)" == 1 ]]; } \
  && pass "5. Release-Note: skip + Lay-Why passes" || fail "5. Release-Note: skip + Lay-Why passes" "$out"
commit t.tst.sh "test: e2"$'\n\nRelease-Note: skip'
check HEAD~1
{ [[ "$rc" -eq 1 ]] && grep -q "(skip) missing Lay-Why" <<<"$out"; } && pass "5b. skip without Lay-Why refuses" || fail "5b. skip without Lay-Why refuses" "$out"

# 6. revert
git -C "$T" revert --no-edit HEAD >/dev/null
git -C "$T" commit -q --amend -m "$(git -C "$T" log -1 --format=%B)"$'\n\nLay-Why: the change was wrong'
check HEAD~1
{ [[ "$rc" -eq 0 && "$(field warn)" == 0 && "$(field revert)" == 1 ]]; } \
  && pass "6. a revert + Lay-Why passes" || fail "6. a revert + Lay-Why passes" "$out"

# 7. merge commit skipped
m0="$(git -C "$T" rev-parse HEAD)"
git -C "$T" checkout -q -b side; commit s.sh "fix: side"$'\n\n'"$FULL"
git -C "$T" checkout -q master; commit a.sh "fix: main"$'\n\n'"$FULL"
git -C "$T" merge -q --no-ff -m "Merge side" side
check "$m0"
{ [[ "$rc" -eq 0 && "$(field merge)" == 1 && "$(field commits)" == 2 && "$(field warn)" == 0 ]]; } \
  && pass "7. a merge commit is skipped" || fail "7. a merge commit is skipped" "$out"

# 8. trailers in a middle paragraph, then a prose paragraph, do not count
commit a.sh "fix: f"$'\n\n'"$FULL"$'\n\nA closing remark.'
check HEAD~1
[[ "$rc" -eq 1 && "$(field warn)" == 1 ]] && pass "8. trailers must be the last paragraph" || fail "8. trailers must be the last paragraph" "$out"

# 9. counts over the whole range (misses: 2b, 3, 4a, 4b, 5b, 8)
check base
{ [[ "$rc" -eq 1 && "$(field commits)" -ge 12 && "$(field warn)" == 6 && "$(field merge)" == 1 ]] \
  && grep -q '^RELEASE_NOTE_CHECK mode=refuse ' <<<"$out" && grep -q '6 of [0-9]* commit(s) lack their release note -- the push is REFUSED' <<<"$out"; } \
  && pass "9. the range line counts commits=$(field commits) warn=6, exit 1" || fail "9. range counts" "rc=$rc $out"
rc=0; out="$(RELEASE_NOTE_MODE=warn RELEASE_NOTE_TREE="$T" RELEASE_NOTE_BASE=base do_check_release_note 2>&1)" || rc=$?
{ [[ "$rc" -eq 0 && "$(field warn)" == 6 ]] && grep -q '^RELEASE_NOTE_CHECK mode=warn ' <<<"$out" \
  && grep -q 'WARN release-note: 6 of' <<<"$out" && ! grep -q 'FAIL release-note' <<<"$out"; } \
  && pass "9b. RELEASE_NOTE_MODE=warn measures the same range with exit 0" || fail "9b. warn mode" "rc=$rc $out"
rc=0; out="$(RELEASE_NOTE_MODE=off RELEASE_NOTE_TREE="$T" RELEASE_NOTE_BASE=base do_check_release_note 2>&1)" || rc=$?
[[ "$rc" -eq 2 ]] && pass "9c. an unknown RELEASE_NOTE_MODE is exit 2" || fail "9c. unknown mode" "rc=$rc $out"
rc=0; out="$(RELEASE_NOTE_TREE="$T" RELEASE_NOTE_BASE=no-such-ref do_check_release_note 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] && pass "9d. a base that does not resolve refuses" || fail "9d. unresolved base" "rc=$rc $out"

# 10. through do_check_pre_push: a FAIL verdict line, the push is refused.
# The scanner lint parts are stubbed out (not under test here).
_ppl_plan() { _PPL_SELECTED=""; _PPL_FAST=""; _PPL_SLOW=""; }
_ppl_typos() { :; }
log="$G/pp.log"  # outside the repo: an untracked file would make the tree dirty
# pp [VAR=value...]: one gate run in a subshell with those vars; rc in $rc, log in $log
pp() { rc=0; : >"$log"; out="$( (
  local kv; for kv in "$@"; do export "${kv?}"; done
  PRE_PUSH_TREE="$T" PRE_PUSH_LOG="$log" PRE_PUSH_CACHE="$G/pp.cache" PRE_PUSH_PASS="$G/pp.pass" do_check_pre_push
) 2>&1)" || rc=$?; }
pp PRE_PUSH_BASE=base
{ [[ "$rc" -eq 1 ]] && grep -q 'PART release-note FAIL .*warn=6' "$log" \
  && grep -q 'FAIL .*release-note (6 of' <<<"$out" && grep -q 'part(s) FAILED' <<<"$out"; } \
  && pass "10. do_check_pre_push refuses a range with a commit that lacks its note" || fail "10. pre-push wiring" "rc=$rc $(cat "$log" 2>/dev/null) $out"
# red control: a range whose every commit carries its note passes
commit a.sh "fix: g"$'\n\n'"$FULL"
pp PRE_PUSH_BASE=HEAD~1
{ [[ "$rc" -eq 0 ]] && grep -q 'PART release-note PASS .*warn=0' "$log"; } \
  && pass "10. control: a range with every note passes" || fail "10. control" "rc=$rc $(cat "$log") $out"

# 11. empty range -> SKIP-untouched
pp PRE_PUSH_BASE=HEAD
grep -q 'PART release-note SKIP-untouched' "$log" \
  && pass "11. an empty range is SKIP-untouched" || fail "11. empty range" "$(cat "$log")"

# 12. PRE_PUSH_LINT=0 (the lint rollback knob) and the override skip it with
# the lint parts; the CI job release-note of workflow 10 is their backstop
pp PRE_PUSH_BASE=base PRE_PUSH_LINT=0
! grep -q 'PART release-note' "$log" \
  && pass "12. PRE_PUSH_LINT=0 skips it" || fail "12. PRE_PUSH_LINT=0" "rc=$rc $(cat "$log")"
pp PRE_PUSH_BASE=base PRE_PUSH_ONLY=override
! grep -q 'PART release-note' "$log" \
  && pass "12. the override skips it" || fail "12. override" "rc=$rc $(cat "$log")"

# 13. the hook's second run skips a tree that passed whole; its key holds the
# messages, so an amend that drops the note on the same tree still refuses
pp PRE_PUSH_BASE=HEAD~1
[[ "$rc" -eq 0 ]] || fail "13. (setup) the tree passes" "rc=$rc $(cat "$log")"
git -C "$T" commit -q --amend -m "fix: g, note dropped"
pp PRE_PUSH_BASE=HEAD~1 PRE_PUSH_SKIP_PASSED=1
{ [[ "$rc" -eq 1 ]] && grep -q 'PART release-note FAIL' "$log" && ! grep -q 'PART tree PASS-tree' "$log"; } \
  && pass "13. the PASS-tree shortcut still refuses a dropped note" || fail "13. PASS-tree shortcut" "rc=$rc $(cat "$log") $out"
git -C "$T" commit -q --amend -m "fix: g"$'\n\n'"$FULL"
pp PRE_PUSH_BASE=HEAD~1 PRE_PUSH_SKIP_PASSED=1
{ [[ "$rc" -eq 0 ]] && grep -q 'PART tree PASS-tree' "$log"; } \
  && pass "13. control: with the note back the shortcut passes" || fail "13. control" "rc=$rc $(cat "$log") $out"

# 14. the fix for a commit already on master: a git note (release-notes.md 4)
commit a.sh "fix: h"
check HEAD~1
[[ "$rc" -eq 1 ]] || fail "14. (setup) no note refuses" "rc=$rc $out"
git -C "$T" notes --ref=release-notes add -m "$FULL" HEAD
check HEAD~1
{ [[ "$rc" -eq 0 && "$(field ok)" == 1 ]]; } \
  && pass "14. a git note on refs/notes/release-notes stands in for the message" || fail "14. git note" "rc=$rc $out"
# R7 c-890 W1: no lane push carries a local note to origin, so the pre-push
# part reads only the message: the same commit with the same local note refuses
pp PRE_PUSH_BASE=HEAD~1
{ [[ "$rc" -eq 1 ]] && grep -q 'PART release-note FAIL' "$log"; } \
  && pass "14. the pre-push part ignores a local git note: only the message counts" || fail "14. pre-push ignores the note" "rc=$rc $(cat "$log") $out"
git -C "$T" notes --ref=release-notes add -f -m "Lay-What: only one" HEAD
check HEAD~1
{ [[ "$rc" -eq 1 ]] && grep -q "(full) missing Lay-How" <<<"$out"; } \
  && pass "14. control: a note that falls short refuses" || fail "14. note control" "rc=$rc $out"
git -C "$T" notes --ref=release-notes add -f -m "$FULL" HEAD

# 15. CI: RELEASE_NOTE_BASE=switch = after the commit that added _RN_SWITCH_MARK
rc=0; out="$(RELEASE_NOTE_TREE="$T" RELEASE_NOTE_BASE=switch do_check_release_note 2>&1)" || rc=$?
{ [[ "$rc" -eq 2 ]] && grep -q 'no commit adds _RN_SWITCH_MARK' <<<"$out"; } \
  && pass "15. no switch commit in the history is exit 2" || fail "15. no anchor" "rc=$rc $out"
mkdir -p "$T/csi-spl-iac/src/bash/run"
grep '^_RN_SWITCH_MARK=' "$PROJ_ROOT/src/bash/run/check-release-note.func.sh" >"$T/csi-spl-iac/src/bash/run/check-release-note.func.sh"
git -C "$T" add -A; git -C "$T" commit -qm "feat: the switch"$'\n\n'"$FULL"
commit a.sh "fix: after the switch, no note"
rc=0; out="$(RELEASE_NOTE_TREE="$T" RELEASE_NOTE_BASE=switch do_check_release_note 2>&1)" || rc=$?
{ [[ "$rc" -eq 1 && "$(field commits)" == 1 && "$(field warn)" == 1 ]] && grep -q 'after the switch, no note' <<<"$out" \
  && grep -q 'on master; attach each note with: .*do_release_note_attach' <<<"$out"; } \
  && pass "15. switch: only the commits after the switch are checked, a miss refuses and names do_release_note_attach" || fail "15. switch" "rc=$rc $out"
git -C "$T" commit -q --amend -m "fix: after the switch"$'\n\n'"$FULL"
rc=0; out="$(RELEASE_NOTE_TREE="$T" RELEASE_NOTE_BASE=switch do_check_release_note 2>&1)" || rc=$?
[[ "$rc" -eq 0 && "$(field commits)" == 1 ]] \
  && pass "15. control: with its note the range since the switch passes" || fail "15. switch control" "rc=$rc $out"

echo ""
if [[ "$fails" -gt 0 ]]; then echo "check-release-note: $fails FAILED"; exit 1; fi
echo "check-release-note: all PASSED"
