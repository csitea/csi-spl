#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the wui-lang-review part of do_check_pre_push and its CI action
#          do_check_pre_push_lang_review (SPL-5551): a commit that adds or changes
#          a key in csi-spl-wui/i18n/locales/*.json carries a
#          'Lang-review: a-NNN <msg id>' line.
#   1. plan: a push touching a locale file selects wui-lang-review; a push
#      touching other wui files only does not; a lint-only run has none
#   2. RED: a commit adding a key with no line -> the part fails, one FAIL line
#      saying how to get the review
#   3. the same commit with the line -> PASS
#   4. a commit that only removes keys -> PASS
#   5. a changed value (no new key) with no line -> FAIL
#   6. an en-only change of a key listed under 'keys' -> PASS; the same key
#      changed in fi.json too -> FAIL
#   7. a commit listed by its full sha under 'commits' -> PASS
#   8. a locale file that is not JSON at the commit -> FAIL
#   9. through the whole gate: rc 1, logged PART wui-lang-review FAIL; the
#      re-check on the base never turns it into WARN-pre-existing
#  10. the CI action: default range starts at the commit that added the exempt
#      list (an older commit without the line is not checked, a newer one is)
#  11. a malformed line (no msg id, a claude seat) does not count
#  12. the action CI workflow 10 calls resolves through ./run (the loader maps
#      do_a_b to a-b.func.sh; a name that maps nowhere is "NOT found" in CI)
#  13. a Claude seat with the owner's waiver (SPL-5767): 'c-NNN[@box] <msg>
#      waiver <8hex>' passes; a bare c-NNN line, a waiver with no id and the
#      g-/m-/x- prefixes FAIL; a-NNN still passes. Each case through both
#      callers: the pre-push range and the CI range (LANG_REVIEW_RANGE)
#  14. 'Lang-review: gct <run id>' (SPL-6174, Cloud Translation): the line with
#      its report in the commit's tree, covering the committed fi text -> PASS;
#      RED controls, each FAIL: the line with no report, neither line, a
#      report of another run id, a report whose text is not the committed
#      text, a report missing a key, a row marked placeholder, a committed
#      string whose {placeholder} differs from en although the report says
#      match, a malformed run id, a row with no reference / no back / no en
#      or another mark, a row whose en is not the committed en. A commit that
#      changes an en value checks the locales holding that key: no row, or a
#      row of the old en -> FAIL; a row of the committed en -> PASS. A report
#      landed in an earlier commit of the range still holds. Each case
#      through both callers
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
unset PRE_PUSH_BASE PRE_PUSH_MODE PRE_PUSH_TIER PRE_PUSH_ONLY PRE_PUSH_PLAN PRE_PUSH_LINT PRE_PUSH_LINT_ONLY PRE_PUSH_SKIP_PASSED LANG_REVIEW_RANGE LANG_REVIEW_TREE 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="${LANG_REVIEW_TEST_FUNC:-$PROJ_ROOT/src/bash/run/check-pre-push.func.sh}"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

do_log() { :; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
R="$ROOT/r" L=csi-spl-wui/i18n/locales X=csi-spl-wui/i18n/i18n-lang-review-exempt.json
git init -q "$R"; mkdir -p "$R/$L" "$R/csi-spl-wui/src"
printf '{"a":{"b":"Hello","c":"Bye"}}\n' >"$R/$L/en.json"
printf '{"a":{"b":"Hei","c":"Hei hei"}}\n' >"$R/$L/fi.json"
printf '{"_doc":"t","keys":{"a.c":"en typo"},"commits":{}}\n' >"$R/$X"
echo x >"$R/csi-spl-wui/src/x.ts"
git -C "$R" add -A; git -C "$R" commit -qm seed; git -C "$R" branch trunk

commit() {  # <msg> -> commits the working tree
  git -C "$R" add -A; git -C "$R" commit -qm "$1"
}
part() {  # -> rc of the part on trunk..HEAD; output in $ROOT/part
  PRE_PUSH_BASE=trunk _pp_part_wui_lang_review "$R" >"$ROOT/part" 2>&1
}
reset() { git -C "$R" checkout -q -B lane trunk; }

# 1. the plan
plan() {  # [env...] -> the parts= field
  ( for kv in "$@"; do export "${kv?}"; done; PRE_PUSH_PLAN=1 PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk do_check_pre_push 2>/dev/null ) \
    | sed -n 's/^PRE_PUSH_PLAN .* parts=//p'
}
reset; echo y >>"$R/csi-spl-wui/src/x.ts"; commit "feat(wui): code only"
p="$(plan)"; case " $p " in *" wui-lang-review "*) fail "1. a wui code-only push has no wui-lang-review" "$p" ;; *) pass "1. a wui code-only push has no wui-lang-review" ;; esac
reset; printf '{"a":{"b":"Hello","c":"Bye","d":"New"}}\n' >"$R/$L/en.json"; commit "feat(wui): a new key"
p="$(plan)"; case " $p " in *" wui-lang-review "*) pass "1. a locale push plans wui-lang-review" ;; *) fail "1. a locale push plans wui-lang-review" "$p" ;; esac
p="$(plan PRE_PUSH_ONLY=lint)"; case " $p " in *" wui-lang-review "*) fail "1. a lint-only run has none" "$p" ;; *) pass "1. a lint-only run has none" ;; esac

# 2. RED: a new key, no line
part; eq "2. a new key with no Lang-review line -> FAIL (rc 1)" 1 "$?"
eq "2. ... one FAIL line" 1 "$(grep -c '^wui-lang-review: FAIL ' "$ROOT/part")"
grep -q "first: $L/en.json a.d" "$ROOT/part" && pass "2. ... names the first key" || fail "2. ... names the key" "$(cat "$ROOT/part")"
grep -q 'do_spl_lang_review_gct' "$ROOT/part" && pass "2. ... says how to get the check (do_spl_lang_review_gct)" || fail "2. ... says how" "$(cat "$ROOT/part")"

# 3. the line
git -C "$R" commit -q --amend -m "feat(wui): a new key" -m "Lang-review: a-511 d30773a7"
part; eq "3. the same commit with 'Lang-review: a-511 d30773a7' -> PASS" 0 "$?"
git -C "$R" commit -q --amend -m "feat(wui): a new key" -m "Lang-review: a-511@box1 1f5e074b-aaaa-bbbb-cccc-0123456789ab"
part; eq "3. a box-tagged id and a full uuid msg id -> PASS" 0 "$?"

# 4. removal only
reset; printf '{"a":{"b":"Hello"}}\n' >"$R/$L/en.json"; printf '{"a":{"b":"Hei"}}\n' >"$R/$L/fi.json"; commit "refactor(wui): drop a.c"
part; eq "4. a commit that only removes keys -> PASS" 0 "$?"

# 5. a changed value
reset; printf '{"a":{"b":"Moi","c":"Hei hei"}}\n' >"$R/$L/fi.json"; commit "fix(wui): wording"
part; eq "5. a changed value with no line -> FAIL" 1 "$?"

# 6. the en-only allow-list
reset; printf '{"a":{"b":"Hello","c":"Goodbye"}}\n' >"$R/$L/en.json"; commit "fix(wui): en typo"
part; eq "6. an en-only change of a listed key -> PASS (exempt)" 0 "$?"
grep -q 'exempt by' "$ROOT/part" && pass "6. ... says exempt" || fail "6. ... says exempt" "$(cat "$ROOT/part")"
printf '{"a":{"b":"Hei","c":"Hyvasti"}}\n' >"$R/$L/fi.json"; commit "fix(wui): fi too"
part; eq "6. the listed key changed in fi.json -> FAIL" 1 "$?"

# 7. a commit recorded afterwards
reset; printf '{"a":{"b":"Hello","c":"Bye","e":"Late"}}\n' >"$R/$L/en.json"; commit "feat(wui): reviewed later"
sha="$(git -C "$R" rev-parse HEAD)"
part; eq "7. before it is listed -> FAIL" 1 "$?"
printf '{"_doc":"t","keys":{},"commits":{"%s":"a-511 d30773a7"}}\n' "$sha" >"$R/$X"; commit "chore(wui): record the review of $sha"
part; eq "7. listed by full sha under 'commits' -> PASS" 0 "$?"

# 8. not JSON
reset; printf '{"a":\n' >"$R/$L/fi.json"; commit "fix(wui): broken"
part; eq "8. a locale file that is not JSON -> FAIL" 1 "$?"
grep -q 'not valid JSON' "$ROOT/part" && pass "8. ... says not valid JSON" || fail "8. ... says so" "$(cat "$ROOT/part")"

# 9. the whole gate
reset; printf '{"a":{"b":"Hello","c":"Bye","f":"Gate"}}\n' >"$R/$L/en.json"; commit "feat(wui): through the gate"
LOG="$ROOT/pp.log"; : >"$LOG"
( env PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$LOG" PRE_PUSH_CACHE="$ROOT/pp.cache" \
    PRE_PUSH_PASS="$ROOT/pp.pass" PRE_PUSH_EXTRA_PATH='' PRE_PUSH_NO_CACHE=1 \
    bash -c '. "$0"; do_log() { :; }; do_check_dist_hygiene() { :; }; _pp_part_stale_tree() { :; }; _pp_part_owner_orders() { :; }
      _pp_part_commit_links() { :; }; _pp_part_wui() { :; }; _pp_part_wui_vendor() { :; }; _pp_part_wui_e2e() { :; }
      _ppe_parts() { :; }; _ppf_parts() { :; }; _ppx_parts() { :; }
      _pp_missing_tools() { :; }; _ppl_plan() { _PPL_SELECTED=""; }; _ppl_typos() { :; }; _pp_release_note() { :; }
      do_check_pre_push' "$FUNC" ) >"$ROOT/out" 2>&1
eq "9. the gate fails (rc 1)" 1 "$?"
grep -q ' PART wui-lang-review FAIL ' "$LOG" && pass "9. ... logged PART wui-lang-review FAIL" || fail "9. ... logged FAIL" "$(cat "$LOG")"
grep -q ' PART wui-lang-review WARN' "$LOG" && fail "9. ... never WARN-pre-existing" "$(cat "$LOG")" || pass "9. ... never WARN-pre-existing"

# 10. the CI action's anchor
A="$ROOT/a"; git init -q "$A"; mkdir -p "$A/$L"
printf '{"k":"one"}\n' >"$A/$L/en.json"; git -C "$A" add -A; git -C "$A" commit -qm seed
printf '{"k":"one","old":"before the gate"}\n' >"$A/$L/en.json"; git -C "$A" commit -qam "feat(wui): before the gate"
mkdir -p "$(dirname "$A/$X")"; printf '{"keys":{},"commits":{}}\n' >"$A/$X"; git -C "$A" add -A; git -C "$A" commit -qm "feat(iac): the gate"
LANG_REVIEW_TREE="$A" do_check_pre_push_lang_review >"$ROOT/ci" 2>&1; eq "10. CI: a commit before the anchor is not checked -> PASS" 0 "$?"
printf '{"k":"one","old":"before the gate","new":"after"}\n' >"$A/$L/en.json"; git -C "$A" commit -qam "feat(wui): after the gate"
LANG_REVIEW_TREE="$A" do_check_pre_push_lang_review >"$ROOT/ci" 2>&1; eq "10. CI: a commit after the anchor with no line -> FAIL" 1 "$?"
grep -q 'commits=1 refused=1' "$ROOT/ci" && pass "10. ... checked exactly that one" || fail "10. ... checked one" "$(cat "$ROOT/ci")"
git -C "$A" commit -q --amend -m "feat(wui): after the gate" -m "Lang-review: a-511 d30773a7"
LANG_REVIEW_TREE="$A" do_check_pre_push_lang_review >"$ROOT/ci" 2>&1; eq "10. CI: with the line -> PASS" 0 "$?"
LANG_REVIEW_TREE="$ROOT/none" do_check_pre_push_lang_review >"$ROOT/ci" 2>&1; eq "10. CI: no anchor (shallow clone) -> FAIL" 1 "$?"

# 11. malformed lines
reset; printf '{"a":{"b":"Hello","c":"Bye","g":"Bad"}}\n' >"$R/$L/en.json"
git -C "$R" add -A; git -C "$R" commit -qm "feat(wui): bad lines" -m "Lang-review: a-511" -m "Lang-review: c-896 d30773a7" -m "reviewed by agy (Lang-review: a-511 d30773a7)"
part; eq "11. no msg id / a claude seat / not at line start -> FAIL" 1 "$?"

# 12. the workflow's action, through the real ./run loader
WF="$PROJ_ROOT/../.github/workflows/10_ci-quality.yml"
act=$(sed -n '/^  wui-lang-review:/,/^  [a-z]/s/.*run: \.\/run -a \(do_[a-z_]*\).*/\1/p' "$WF")
eq "12. workflow 10 job wui-lang-review names do_check_pre_push_lang_review" do_check_pre_push_lang_review "$act"
( cd "$PROJ_ROOT" && LANG_REVIEW_TREE="$A" ./run -a "${act:-none}" ) >"$ROOT/run" 2>&1
eq "12. ... ./run -a $act resolves and passes" 0 "$?"
grep -q 'NOT found' "$ROOT/run" && fail "12. ... no 'NOT found'" "$(tail -3 "$ROOT/run")" || pass "12. ... no 'NOT found'"

# 13. the owner's waiver for a Claude review, both callers
lr() {  # <want rc> <label> <line> -> one commit with <line>, checked by both callers
  reset; printf '{"a":{"b":"Hello","c":"Bye","w":"Waiver %s"}}\n' "$RANDOM" >"$R/$L/en.json"
  git -C "$R" add -A; git -C "$R" commit -qm "feat(wui): waiver case" -m "$3"
  part; eq "13. pre-push: $2" "$1" "$?"
  LANG_REVIEW_TREE="$R" LANG_REVIEW_RANGE=trunk..HEAD do_check_pre_push_lang_review >"$ROOT/ci" 2>&1
  eq "13. CI range: $2" "$1" "$?"
}
lr 0 "c-NNN <msg> waiver <8hex> -> PASS" "Lang-review: c-523 94eea503 waiver 3a71dac1"
lr 0 "c-NNN@box <msg> waiver <8hex> -> PASS" "Lang-review: c-523@box1 94eea503 waiver 3a71dac1"
lr 0 "c-NNN <uuid msg> waiver <uuid> -> PASS" "Lang-review: c-523 94eea503-aaaa-bbbb-cccc-0123456789ab waiver 3a71dac1-aaaa-bbbb-cccc-0123456789ab"
lr 1 "bare c-NNN <msg> -> FAIL" "Lang-review: c-523 94eea503"
lr 1 "c-NNN <msg> waiver (no id) -> FAIL" "Lang-review: c-523 94eea503 waiver"
lr 1 "c-NNN <msg> waiver <short id> -> FAIL" "Lang-review: c-523 94eea503 waiver 3a71"
lr 1 "c-NNN waiver <8hex> (no msg id) -> FAIL" "Lang-review: c-523 waiver 3a71dac1"
lr 0 "a-NNN <msg> -> PASS" "Lang-review: a-511 d30773a7"
lr 0 "a-NNN@box <msg> -> PASS" "Lang-review: a-511@box1 d30773a7"
for px in g m x; do
  lr 1 "$px-NNN <msg> waiver <8hex> -> FAIL" "Lang-review: $px-123 94eea503 waiver 3a71dac1"
done
lr 1 "a waiver line not at line start -> FAIL" "see Lang-review: c-523 94eea503 waiver 3a71dac1"
grep -q "Lang-review: gct <run id>" "$ROOT/part" && pass "13. the FAIL line names the gct form" || fail "13. FAIL names the gct form" "$(cat "$ROOT/part")"

# 14. the gct form (SPL-6174)
G=csi-spl-wui/i18n/lang-review ID=20261121T092858Z-022bbca5 FI_H='Moi {name}'
gct_report() {  # <run id> <file id> <rows json> -> $R/$G/<file id>.json
  mkdir -p "$R/$G"
  printf '{"v":1,"engine":"gct","run_id":"%s","rows":%s}\n' "$1" "$3" >"$R/$G/$2.json"
}
row() {  # <key> <text> <mark> [en] [reference] [back]
  local hi='Hi {name}' moi='Moi {name}'
  printf '{"file":"%s/fi.json","lang":"fi","key":"%s","en":"%s","text":"%s","reference":"%s","back":"%s","mark":"%s"}' \
    "$L" "$1" "${4-$hi}" "$2" "${5-$moi}" "${6-$hi}" "$3"
}
gct() {  # <want rc> <label> <line> [fi text of a.h] -> one commit adding a.h, checked by both callers
  reset; printf '{"a":{"b":"Hello","c":"Bye","h":"Hi {name}"}}\n' >"$R/$L/en.json"
  printf '{"a":{"b":"Hei","c":"Hei hei","h":"%s"}}\n' "${4:-$FI_H}" >"$R/$L/fi.json"
  [[ -n "${GCT_ROWS:-}" ]] && gct_report "${GCT_RUN:-$ID}" "${GCT_FILE:-$ID}" "$GCT_ROWS"
  git -C "$R" add -A; git -C "$R" commit -qm "feat(wui): gct case" -m "$3"
  part; eq "14. pre-push: $2" "$1" "$?"
  LANG_REVIEW_TREE="$R" LANG_REVIEW_RANGE=trunk..HEAD do_check_pre_push_lang_review >"$ROOT/ci" 2>&1
  eq "14. CI range: $2" "$1" "$?"
}
GCT_ROWS="[$(row a.h 'Moi {name}' differs)]" gct 0 "gct line + its report covering the committed text -> PASS" "Lang-review: gct $ID"
grep -q "PASS .* checked by gct $ID" "$ROOT/part" && pass "14. ... says checked by gct" || fail "14. ... says checked by gct" "$(cat "$ROOT/part")"
GCT_ROWS="" gct 1 "gct line, no report -> FAIL" "Lang-review: gct $ID"
grep -q "no report $G/$ID.json" "$ROOT/part" && pass "14. ... names the missing report" || fail "14. ... names the missing report" "$(cat "$ROOT/part")"
GCT_ROWS="[$(row a.h 'Moi {name}' match)]" gct 1 "a report but neither line -> FAIL" "Lang-review: none"
GCT_ROWS="[$(row a.h 'Moi {name}' match)]" GCT_RUN=20261121T000000Z-00000000 gct 1 "a report of another run id -> FAIL" "Lang-review: gct $ID"
GCT_ROWS="[$(row a.h 'Terve {name}' match)]" gct 1 "the report checked other text -> FAIL" "Lang-review: gct $ID"
GCT_ROWS="[$(row a.b 'Hei' match)]" gct 1 "the report misses a key -> FAIL" "Lang-review: gct $ID"
GCT_ROWS="[$(row a.h 'Moi {name}' placeholder)]" gct 1 "a row marked placeholder -> FAIL" "Lang-review: gct $ID"
GCT_ROWS="[$(row a.h 'Moi {nimi}' match)]" gct 1 "a {placeholder} differs from en, the report says match -> FAIL" "Lang-review: gct $ID" 'Moi {nimi}'
grep -q "placeholders .*differ from en" "$ROOT/part" && pass "14. ... names the placeholder" || fail "14. ... names the placeholder" "$(cat "$ROOT/part")"
GCT_ROWS="[$(row a.h 'Moi {name}' match 'Hi {name}' '')]" gct 1 "a row with no reference -> FAIL" "Lang-review: gct $ID"
grep -q "no reference text" "$ROOT/part" && pass "14. ... names the missing reference" || fail "14. ... names the missing reference" "$(cat "$ROOT/part")"
GCT_ROWS="[$(row a.h 'Moi {name}' match 'Hi {name}' 'Moi {name}' '')]" gct 1 "a row with no back -> FAIL" "Lang-review: gct $ID"
GCT_ROWS="[$(row a.h 'Moi {name}' ok)]" gct 1 "a row with another mark -> FAIL" "Lang-review: gct $ID"
GCT_ROWS='[{"file":"'"$L"'/fi.json","key":"a.h","text":"Moi {name}","mark":"differs"}]' gct 1 "a hand-written row (no en, reference, back) -> FAIL" "Lang-review: gct $ID"
GCT_ROWS="[$(row a.h 'Moi {name}' match 'Hello {name}')]" gct 1 "a row whose en is not the committed en -> FAIL" "Lang-review: gct $ID"
grep -q "committed en text is not the en" "$ROOT/part" && pass "14. ... names the en" || fail "14. ... names the en" "$(cat "$ROOT/part")"
# an en value change: the locales holding the key are asked again
gct_en() {  # <want rc> <label> <rows json> -> one commit changing en a.b only
  reset; printf '{"a":{"b":"Hello there","c":"Bye"}}\n' >"$R/$L/en.json"
  [[ -n "$3" ]] && gct_report "$ID" "$ID" "$3"
  git -C "$R" add -A; git -C "$R" commit -qm "feat(wui): en case" -m "Lang-review: gct $ID"
  part; eq "14. pre-push: $2" "$1" "$?"
  LANG_REVIEW_TREE="$R" LANG_REVIEW_RANGE=trunk..HEAD do_check_pre_push_lang_review >"$ROOT/ci" 2>&1
  eq "14. CI range: $2" "$1" "$?"
}
gct_en 1 "en a.b changed, a report with no rows -> FAIL" "[]"
grep -q "fi.json a.b: not in" "$ROOT/part" && pass "14. ... names the fi key of the en change" || fail "14. ... names the fi key" "$(cat "$ROOT/part")"
gct_en 1 "en a.b changed, the fi row checked the old en -> FAIL" "[$(row a.b 'Hei' differs 'Hello' 'Hei' 'Hi')]"
gct_en 0 "en a.b changed, the fi row checked the committed en -> PASS" "[$(row a.b 'Hei' differs 'Hello there' 'Hei siellä' 'Hi')]"
GCT_ROWS="[$(row a.h 'Moi {name}' match)]" GCT_FILE=2026-11-21 gct 1 "a malformed run id -> FAIL" "Lang-review: gct 2026-11-21"
# a report from an earlier commit of the range
reset; gct_report "$ID" "$ID" "[$(row a.h 'Moi {name}' match)]"; commit "chore(wui): the report first"
printf '{"a":{"b":"Hello","c":"Bye","h":"Hi {name}"}}\n' >"$R/$L/en.json"; printf '{"a":{"b":"Hei","c":"Hei hei","h":"Moi {name}"}}\n' >"$R/$L/fi.json"
git -C "$R" add -A; git -C "$R" commit -qm "feat(wui): the text" -m "Lang-review: gct $ID"
part; eq "14. a report landed earlier in the range -> PASS" 0 "$?"

echo "check-pre-push-lang-review: $fails failure(s)"
((fails == 0))
