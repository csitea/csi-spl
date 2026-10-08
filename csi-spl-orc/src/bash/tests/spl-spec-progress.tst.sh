#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_spec_progress (spec 112 5.1, task ORC-1) on the fixture tree
#          fixtures/spec-progress: one spec per state plus 006, whose only
#          open box is [~], which must read in-progress with
#          pct = floor(100 x / (x+p+o)) = 75.
#   1. the TSV rows, the header and the total line
#   2. --exclude drops a spec; a bad argument is refused
#   3. --sha reads git archive of the ref, never the worktree
#   4. --json: the roadmap.json shape
#   5. CONTROL: an action that counts [~] as done turns case 006 red
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-spec-progress.func.sh"
FIX="$TEST_DIR/fixtures/spec-progress"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# progress <func-file> <root> [args...] -> the action's stdout in $T/out, rc.
progress() {
  local func="$1" root="$2"; shift 2
  env -u APP_PATH SPEC_PROGRESS_ROOT="$root" FUNC_FILE="$func" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { command -v "$@" >/dev/null; }
    source "$FUNC_FILE"
    do_spl_spec_progress "$@"' _ "$@" >"$T/out" 2>"$T/err" </dev/null
}

# row_is <spec-prefix> <expected "state x p o pct"> -> 0 when the TSV row matches.
row_is() {
  local got
  got="$(awk -F'\t' -v s="$1" 'index($1, s "-") == 1 { print $2, $3, $4, $5, $6 }' "$T/out")"
  [[ "$got" == "$2" ]] || { echo "  $1: got '$got', want '$2'"; return 1; }
}

# check_rows -> 0 when every fixture row reads by the 5.1 rule.
check_rows() {
  local bad=0
  row_is 001 "done 3 0 0 100" || bad=1
  row_is 002 "in-progress 1 1 2 25" || bad=1
  row_is 003 "planned 0 0 3 0" || bad=1
  row_is 004 "no-boxes 0 0 0 " || bad=1
  row_is 005 "no-tasks 0 0 0 " || bad=1
  row_is 006 "in-progress 3 1 0 75" || bad=1
  return "$bad"
}

bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"

# --- 1. TSV -------------------------------------------------------------------
progress "$FUNC" "$FIX"; rc=$?
[[ $rc -eq 0 ]] && pass "1. rc 0" || fail "1. rc=$rc $(cat "$T/err")"
[[ "$(head -1 "$T/out")" == $'spec\tstate\tx\tp\to\tpct' ]] && pass "1. header" || fail "1. header: $(head -1 "$T/out")"
check_rows && pass "1. one row per state, [~]-only-open spec is in-progress at 75" || fail "1. rows"
[[ "$(grep -c '^[0-9]' "$T/out")" == 6 ]] && pass "1. one row per spec dir (no-tasks included)" || fail "1. row count"
grep -qE '^# total sha=[^ ]*worktree specs=6 tasks.md=5 done=1 in-progress=2 no-boxes=1 planned=1 no-tasks=1$' <<<"$(tail -1 "$T/out")" \
  && pass "1. total line" || fail "1. total: $(tail -1 "$T/out")"

# --- 2. --exclude and refusals --------------------------------------------------
progress "$FUNC" "$FIX" --exclude 006,003
! grep -qE '^00[36]-' "$T/out" && grep -q 'specs=4 ' "$T/out" && pass "2. --exclude drops 003 and 006" || fail "2. exclude: $(cat "$T/out")"
progress "$FUNC" "$FIX" --bogus; rc=$?
[[ $rc -eq 2 && ! -s "$T/out" ]] && pass "2. unknown argument refused" || fail "2. bogus rc=$rc"
progress "$FUNC" "$T/nope"; rc=$?
[[ $rc -eq 2 ]] && pass "2. missing root refused" || fail "2. missing root rc=$rc"

# --- 3. --sha reads git archive, not the worktree -------------------------------
R="$T/repo"; mkdir -p "$R"; cp -r "$FIX/csi-spl-doc" "$R/"
git -C "$R" init -q && git -C "$R" add -A \
  && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm fixture || fail "3. git setup"
sha="$(git -C "$R" rev-parse HEAD)"
printf -- '- [ ] T005 added in the worktree only\n' >>"$R/csi-spl-doc/specs/001-all-done/tasks.md"
progress "$FUNC" "$R" --sha HEAD; rc=$?
[[ $rc -eq 0 ]] && check_rows && grep -q "^# total sha=$sha " "$T/out" \
  && pass "3. --sha HEAD reads the commit, names its sha" || fail "3. --sha: rc=$rc $(cat "$T/out" "$T/err")"
progress "$FUNC" "$R"
row_is 001 "in-progress 3 0 1 75" && grep -q "^# total sha=$sha+worktree " "$T/out" \
  && pass "3. without --sha the worktree is read and marked" || fail "3. worktree: $(cat "$T/out")"
progress "$FUNC" "$R" --sha no-such-ref; rc=$?
[[ $rc -eq 2 ]] && pass "3. unknown ref refused" || fail "3. bad ref rc=$rc"

# --- 4. --json ----------------------------------------------------------------
if command -v jq >/dev/null; then
  progress "$FUNC" "$R" --sha HEAD --json; rc=$?
  got="$(jq -c '[.sha, .totals, (.specs | length), (.specs[] | select(.id == "006-partial-only-open")
    | [.state, .x, .p, .o, .pct, .title, (.tasks_changed | length > 0)]), (.specs[] | select(.id == "005-no-tasks") | .pct)]' "$T/out" 2>&1)"
  want="[\"$sha\",{\"specs\":6,\"done\":1,\"in-progress\":2,\"no-boxes\":1,\"planned\":1,\"no-tasks\":1},6,[\"in-progress\",3,1,0,75,\"Spec 006: the only open box is [~]\",true],null]"
  [[ $rc -eq 0 && "$got" == "$want" ]] && pass "4. --json roadmap.json shape" || fail "4. json: rc=$rc got $got"
else
  fail "4. no jq"
fi

# --- 5. CONTROL: [~] counted as done must turn case 006 red ---------------------
sed -e 's/\\\[\[xX\]\\\]/\\[[xX~]\\]/' -e 's/\\\[~\\\]/\\[NEVER\\]/' "$FUNC" >"$T/mutant.func.sh"
cmp -s "$FUNC" "$T/mutant.func.sh" && fail "5. control: the mutant equals the action"
progress "$T/mutant.func.sh" "$FIX"
if row_is 006 "in-progress 3 1 0 75" >/dev/null; then
  fail "5. control: counting [~] as done did NOT turn case 006 red"
else
  row_is 006 "done 4 0 0 100" >/dev/null && pass "5. control: counting [~] as done reads 006 done (red)" \
    || fail "5. control: unexpected mutant row: $(grep '^006' "$T/out")"
fi

echo "=== $fails failure(s)"
[[ $fails -eq 0 ]]
