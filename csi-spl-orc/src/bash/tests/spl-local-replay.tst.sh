#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_local_replay (spec 176 4.8, T0.1, SPL-5556) on a fixture git
# repo and brief store in a temp dir: no network, no model, no key.
#   1. pick: the lanes of the kind, newest landing first, then the i18n
#      slice; a review brief that carries the author's key is not a lane; a
#      key whose commits interleave with another lane's is skipped; a brief
#      with no Issue: line joins only through the keymap
#   2. prepare: per case a fresh repo of the base tree in ONE commit (the
#      landed change is not in it, nor any later commit), the brief beside
#      it, the landed diff under answers/ outside every case; a second
#      prepare into the same dir is refused
#   3. a stub candidate that applies the landed diff -> every case PASS,
#      exit 0; the report states version, tree and n, per slice
#   4. red control: a stub that applies nothing -> every case FAIL
#   5. a stub that writes another change -> R7-PENDING, exit 3, with an
#      r7-request.md; a review.line for another sha keeps it pending; a
#      PASS line for the candidate's sha decides it -> exit 0
#   6. keymap: the hub issue title matches the brief heading (spool issue
#      get stubbed); a title two briefs share maps neither; a dry run calls
#      no hub
#   7. refusals: no kind, an unknown REPLAY_CMD, run with no candidate
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
R="$T/repo" B="$T/briefs"
G=(git -C "$R" -c user.name=t -c user.email=t@example.com)

commit() {  # MSG FILE TEXT
  printf '%s\n' "$3" >"$R/$2"
  "${G[@]}" add "$2" && "${G[@]}" commit -q -m "$1"
}

brief() {  # NAME BODY
  printf '%s\n' "$2" >"$B/$1"
}

mkdir -p "$R" "$B"
git -C "$R" init -q -b master
commit "chore: init" a.txt "one"
commit "feat(orc, SPL-11): add b" b.txt "bee"
commit "feat(orc, SPL-14): part one" c.txt "c1"
commit "fix(api, SPL-99): someone else" d.txt "d"
commit "feat(orc, SPL-14): part two" c.txt "c2"
commit "feat(wui, SPL-13): de strings" de.json '{"hello": "Grüß Gott"}'
commit "fix(orc, SPL-12): change a" a.txt "two"
brief 11.md $'# Lane brief: add b\n\nIssue: SPL-11\nKind: complex_coding\n\nAdd b.txt.'
brief 11r.md $'# Lane brief: SPL-11 add b, R7 reviewer: grok, review only\n\nIssue: SPL-11\nKind: complex_coding'
brief 12.md $'# Lane brief: change a\n\nKind: complex_coding\n\nChange a.txt.'
brief 13.md $'# Lane brief: de strings\n\nIssue: SPL-13\nKind: i18n'
brief 14.md $'# Lane brief: c in two parts\n\nIssue: SPL-14\nKind: complex_coding'

replay() {  # VAR=value... : the action, its stdout + stderr
  SNIPPET='do_spl_local_replay' in_orc REPLAY_REPO="$R" REPLAY_REF=master REPLAY_BRIEFS="$B" \
    REPLAY_KEYMAP="$T/keymap.tsv" "$@" 2>&1
}

# 1. pick
out="$(replay REPLAY_CMD=pick REPLAY_KIND=complex_coding)"
keys="$(cut -f1,2 <<<"$out" | tr '\t\n' ': ')"
[[ "$keys" == "complex_coding:SPL-11 i18n:SPL-13 " ]] && pass "1a pick: SPL-11, then the i18n slice; review brief, interleaved SPL-14, keyless SPL-12 out" ||
  fail "1a pick: got '$keys' ($out)"
printf '12.md\tSPL-12\n' >"$T/keymap.tsv"
out="$(replay REPLAY_CMD=pick REPLAY_KIND=complex_coding REPLAY_N=1 REPLAY_I18N=0)"
[[ "$(cut -f2 <<<"$out")" == SPL-12 ]] && pass "1b keymap joins SPL-12, newest first, N=1, no slice" || fail "1b pick: $out"
out="$(replay REPLAY_CMD=pick REPLAY_KIND=i18n REPLAY_N=3)"
[[ "$(cut -f1,2 <<<"$out" | tr '\t\n' ': ')" == "i18n:SPL-13 " ]] && pass "1c kind i18n: no second slice" || fail "1c: $out"

# 2. prepare (the keymap of 1b stays: the set is SPL-12, SPL-11, i18n SPL-13)
out="$(replay REPLAY_DIR="$T/ok" REPLAY_KIND=complex_coding)"; rc=$?
C="$T/ok/complex_coding"
if (( rc == 0 )) && [[ -f "$C/cases/SPL-11/brief.md" && -f "$C/answers/SPL-11.patch" && -f "$C/set.env" ]] &&
  [[ "$(git -C "$C/cases/SPL-11/wt" rev-list --count HEAD)" == 1 && ! -e "$C/cases/SPL-11/wt/b.txt" ]] &&
  [[ "$(cat "$C/cases/SPL-11/wt/a.txt")" == one ]] && ! git -C "$C/cases/SPL-12/wt" cat-file -e "$("${G[@]}" rev-parse master)" 2>/dev/null; then
  pass "2a prepare: base tree in one commit, brief beside it, answer outside, no later commit in reach"
else fail "2a prepare rc=$rc: $out"; fi
grep -q 'Grüß' "$C/answers/SPL-13.patch" && pass "2b the i18n slice's answer keeps its UTF-8" || fail "2b i18n answer"
out="$(replay REPLAY_DIR="$T/ok" REPLAY_KIND=complex_coding)"; rc=$?
(( rc != 0 )) && grep -q 'already holds a set' <<<"$out" && pass "2c a second prepare into the same dir is refused" || fail "2c rc=$rc: $out"

# 3. stub candidate: applies the landed diff -> PASS
out="$(replay REPLAY_DIR="$T/ok" REPLAY_KIND=complex_coding REPLAY_CMD=run \
  REPLAY_CANDIDATE="git apply \"$C/answers/\$REPLAY_KEY.patch\"")"; rc=$?
(( rc == 0 )) && pass "3a run: the stub ran in every case" || fail "3a run rc=$rc: $out"
out="$(replay REPLAY_DIR="$T/ok" REPLAY_KIND=complex_coding REPLAY_CMD=judge REPLAY_LABEL=stub-landed)"; rc=$?
rep="$(cat "$C/report.md" 2>/dev/null)"
if (( rc == 0 )) && [[ "$(grep -c 'PASS (same patch-id' <<<"$out")" == 3 ]] && grep -q '| version | candidate `stub-landed`; harness `' <<<"$rep" &&
  grep -q "| tree | set picked from \`master\` = \`$("${G[@]}" rev-parse master)\`" <<<"$rep" && grep -q '| n | 3 |' <<<"$rep" &&
  grep -q '| slice `i18n` | n=1 PASS=1 FAIL=0' <<<"$rep"; then
  pass "3b judge: applies-the-landed-diff -> 3 PASS, rc 0, report has version, tree, n and the i18n slice"
else fail "3b judge rc=$rc: $out // $rep"; fi

# 4. red control: applies nothing -> FAIL
replay REPLAY_DIR="$T/none" REPLAY_KIND=complex_coding >/dev/null
replay REPLAY_DIR="$T/none" REPLAY_KIND=complex_coding REPLAY_CMD=run REPLAY_CANDIDATE=true >/dev/null
out="$(replay REPLAY_DIR="$T/none" REPLAY_KIND=complex_coding REPLAY_CMD=judge)"; rc=$?
[[ "$(grep -c 'FAIL (no change)' <<<"$out")" == 3 ]] && ! grep -q ': PASS' <<<"$out" &&
  grep -q '| slice `complex_coding` | n=2 PASS=0 FAIL=2' "$T/none/complex_coding/report.md" &&
  pass "4 red control: applies-nothing -> 3 FAIL, no PASS" || fail "4 rc=$rc: $out"

# 5. another change -> R7 decides
replay REPLAY_DIR="$T/r7" REPLAY_KIND=complex_coding REPLAY_N=1 REPLAY_I18N=0 >/dev/null
W="$T/r7/complex_coding/cases/SPL-12"
replay REPLAY_DIR="$T/r7" REPLAY_KIND=complex_coding REPLAY_CMD=run REPLAY_CANDIDATE='echo two >a.txt; echo x >extra.txt' >/dev/null
out="$(replay REPLAY_DIR="$T/r7" REPLAY_KIND=complex_coding REPLAY_CMD=judge)"; rc=$?
sha="$(git -C "$W/wt" rev-parse HEAD)"
(( rc == 3 )) && grep -q 'R7-PENDING' <<<"$out" && grep -q "PASS|FAIL $sha ran:" "$W/r7-request.md" &&
  pass "5a another change -> R7-PENDING, rc 3, the request names the candidate sha" || fail "5a rc=$rc: $out"
echo "review: g-901@box-a grok PASS 0123456789abcdef0123456789abcdef01234567 ran: x | read: y | log: g-901@box-a:/p" >"$W/review.line"
out="$(replay REPLAY_DIR="$T/r7" REPLAY_KIND=complex_coding REPLAY_CMD=judge)"; rc=$?
(( rc == 3 )) && grep -q 'stale review line' <<<"$out" && pass "5b a line for another sha keeps it pending" || fail "5b rc=$rc: $out"
echo "review: g-901@box-a grok PASS $sha ran: x | read: y | log: g-901@box-a:/p" >"$W/review.line"
out="$(replay REPLAY_DIR="$T/r7" REPLAY_KIND=complex_coding REPLAY_CMD=judge)"; rc=$?
(( rc == 0 )) && grep -q 'SPL-12: PASS (R7 review)' <<<"$out" && grep -q 'g-901@box-a grok' "$T/r7/complex_coding/report.md" &&
  pass "5c the candidate's R7 PASS line decides it, reviewer in the report" || fail "5c rc=$rc: $out"

# 6. keymap from stubbed hub issues
rm -f "$T/keymap.tsv"
brief 15a.md $'# Lane brief: twin\n\nKind: tests'
brief 15b.md $'# Lane brief: twin\n\nKind: tests'
cat >"$T/issues.sh" <<'EOF'
spl_desk_issue_run() {
  echo "get $*" >>"$STUB_LOG"
  case "$3" in
    SPL-12) printf '{"result": {"issue": {"key": "SPL-12", "title": "Lane brief: change a"}}}\n' ;;
    SPL-14) printf '{"result": {"issue": {"key": "SPL-14", "title": "Lane brief: twin"}}}\n' ;;
    *) printf '{"result": {"issue": {"key": "%s", "title": "other"}}}\n' "$3" ;;
  esac
}
EOF
out="$(SNIPPET="source $T/issues.sh; do_spl_local_replay" in_orc REPLAY_REPO="$R" REPLAY_REF=master REPLAY_BRIEFS="$B" \
  REPLAY_KEYMAP="$T/keymap.tsv" REPLAY_CMD=keymap DRY_RUN=0 2>&1)"; rc=$?
(( rc == 0 )) && [[ "$(cat "$T/keymap.tsv")" == $'12.md\tSPL-12' ]] && grep -q 'get --ref SPL-12' "$T/calls.log" &&
  pass "6a keymap: title = heading maps 12.md; a shared title maps neither" || fail "6a rc=$rc: $out // $(cat "$T/keymap.tsv" 2>&1)"
: >"$T/calls.log"
out="$(SNIPPET="source $T/issues.sh; do_spl_local_replay" in_orc REPLAY_REPO="$R" REPLAY_REF=master REPLAY_BRIEFS="$B" \
  REPLAY_KEYMAP="$T/km2.tsv" REPLAY_CMD=keymap 2>&1)"; rc=$?
(( rc == 0 )) && [[ ! -s "$T/calls.log" && ! -e "$T/km2.tsv" ]] && grep -q 'DRY_RUN would' <<<"$out" &&
  pass "6b keymap dry run calls no hub, writes nothing" || fail "6b rc=$rc: $out"

# 7. refusals
out="$(replay REPLAY_DIR="$T/x" REPLAY_CMD=pick)"; rc=$?
(( rc == 1 )) && grep -q 'REPLAY_KIND must' <<<"$out" && pass "7a no kind -> refused" || fail "7a rc=$rc: $out"
out="$(replay REPLAY_DIR="$T/x" REPLAY_CMD=bogus REPLAY_KIND=tests)"; rc=$?
(( rc == 1 )) && grep -q 'REPLAY_CMD must' <<<"$out" && pass "7b unknown REPLAY_CMD -> refused" || fail "7b rc=$rc: $out"
out="$(replay REPLAY_DIR="$T/ok" REPLAY_CMD=run REPLAY_KIND=complex_coding)"; rc=$?
(( rc == 1 )) && grep -q 'REPLAY_CANDIDATE must' <<<"$out" && pass "7c run with no candidate -> refused" || fail "7c rc=$rc: $out"

echo "spl-local-replay: $fails failure(s)"
exit $((fails > 0))
