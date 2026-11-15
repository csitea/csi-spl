#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a part that TIMED OUT on the tree is refused as "not proven your
#          break", never compared by signature, whatever the trunk baseline
#          did (SPL-5588). Before it, only a GREEN baseline got that verdict;
#          on a RED baseline the cut-off run went to _pp_compare, so the
#          verdict depended on where the budget cut the output: c-567's HEAD
#          5b647ab99 read "WARN pre-existing" at 12:34Z and "TIMED OUT ...
#          trunk=9d6043eae-red new=1" at 12:54Z (n=2, box sat, 2026-11-14).
#   a. rc 124, trunk red with another item  -> FAIL, trunk=<sha>-red, no new=,
#      logged "not proven your break", never "NEW on your tree"
#   b. rc 124, trunk red with the same item -> FAIL (a cut-off run is not
#      proof the failure is trunk's either), never WARN pre-existing
#   c. rc 137 (killed), trunk red           -> as a
#   d. rc 124, trunk green                  -> FAIL, "passed on trunkbase"
#   e. rc 124, no baseline tree             -> FAIL, trunk=none, never NEW
#   CONTROL f. rc 1, trunk red, another item -> still FAIL "NEW on your tree"
#   CONTROL g. rc 1, trunk red, same item    -> still WARN pre-existing
#   RED CONTROL: on the gate before SPL-5588 (PP_FUNC_FROM=<that file>)
#   a, b, c and e FAIL; see the commit body.
#   Stub parts: <tree>/flag holds the FAIL lines the part prints and, on the
#   HEAD tree, the rc it returns; no real suite and no real `timeout` runs.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
export PRE_PUSH_BUDGET_CNF="$TEST_DIR/fixtures/pre-push-budgets-pre-spl5574.yaml"  # the pre-SPL-5574 values: these cases test the verdict, not the measured table
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1" "want '$2' in: $3"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1" "did not want '$2' in: $3"; }

do_log() { :; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"
# shellcheck disable=SC1090
[[ -n "${PP_FUNC_FROM:-}" ]] && . "$PP_FUNC_FROM"
_pp_load_read() { _PP_LOAD="0.5 16"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

# Prints each flag line except 'rc=N' as a go-test failure; exits with the
# flag's rc=N (default 1), or 0 when the flag is only 'good'.
_stub() {
  local l rc=1
  grep -qx good "$1/flag" && return 0
  while IFS= read -r l; do
    if [[ "$l" == rc=* ]]; then rc="${l#rc=}"; else echo "--- FAIL: $l (0.$RANDOM""s)"; fi
  done <"$1/flag"
  return "$rc"
}

run() {  # <base-flag> <head-flag> [nobase] -> "<failed>|<stat>|<name>" + verdict + log lines
  local R; R="$ROOT/r$RANDOM$RANDOM"
  { git init -q "$R"; printf '%b\n' "$1" >"$R/flag"; git -C "$R" add flag; git -C "$R" commit -qm base
    git -C "$R" branch trunkbase; printf '%b\n' "$2" >"$R/flag"; git -C "$R" commit -qam head --allow-empty; } >/dev/null 2>&1
  ( local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT="" _PP_PREEXIST=0
    do_log() { echo "LOG $*"; }
    _pp_verdict() { echo "VERDICT $*"; }
    [[ "${3:-}" == nobase ]] && _pp_baseline_tree() { return 1; }
    _pp_run "stub" _stub "$R" trunkbase stub >"$R.out" 2>/dev/null  # no pipe: _pp_run sets this shell's _PP_ arrays
    grep -E '^(LOG FATAL|LOG WARN|VERDICT)' "$R.out"
    _pp_baseline_cleanup "$R" >/dev/null 2>&1
    echo "RESULT $_PP_FAILED|${_PP_STAT[0]:-}|${_PP_NAMES[0]:-}" )
}
# _pp_run with a <part> reads the cache: keep it out of the way
_pp_cache_has() { return 1; }; _pp_cache_add() { :; }; _pp_missing_tools() { :; }
_pp_key() { echo k; }; _pp_paths() { echo x; }

out="$(run TestA 'TestB\nrc=124')"
has   "a. rc 124 on a red trunk with another item -> FAIL" "RESULT 1|FAIL" "$out"
has   "a. ... verdict names the red trunk" "trunk=" "$(grep VERDICT <<<"$out")"
hasnt "a. ... verdict carries no new= count" "new=" "$(grep VERDICT <<<"$out")"
has   "a. ... logged as not proven your break" "not proven your break" "$out"
hasnt "a. ... never 'NEW on your tree'" "NEW on your tree" "$out"
has   "a. ... the log names the red base" "is red too" "$out"

out="$(run TestA 'TestA\nrc=124')"
has   "b. rc 124 on a red trunk with the same item -> FAIL, not WARN" "RESULT 1|FAIL" "$out"
hasnt "b. ... never pre-existing" "pre-existing" "$out"

out="$(run TestA 'TestB\nrc=137')"
has   "c. rc 137 on a red trunk -> FAIL" "RESULT 1|FAIL" "$out"
hasnt "c. ... never 'NEW on your tree'" "NEW on your tree" "$out"
has   "c. ... not proven your break" "not proven your break" "$out"

out="$(run good 'TestB\nrc=124')"
has   "d. rc 124 on a green trunk -> FAIL" "RESULT 1|FAIL" "$out"
has   "d. ... passed on trunkbase" "passed on trunkbase" "$out"
hasnt "d. ... never 'a NEW failure your commits introduce'" "a NEW failure" "$out"

out="$(run TestA 'TestB\nrc=124' nobase)"
has   "e. rc 124 with no baseline tree -> FAIL" "RESULT 1|FAIL" "$out"
has   "e. ... trunk=none" "trunk=none" "$out"
hasnt "e. ... never 'a NEW failure your commits introduce'" "a NEW failure" "$out"

out="$(run TestA 'TestB')"
has   "f. CONTROL: rc 1 on a red trunk with another item -> FAIL" "RESULT 1|FAIL" "$out"
has   "f. CONTROL: ... still NEW on your tree" "NEW on your tree: go-test TestB" "$out"

out="$(run TestA 'TestA')"
has   "g. CONTROL: rc 1 on a red trunk with the same item -> WARN" "RESULT 0|WARN" "$out"

echo "--- $((n - fails))/$n passed ---"
[[ "$fails" -eq 0 ]]
