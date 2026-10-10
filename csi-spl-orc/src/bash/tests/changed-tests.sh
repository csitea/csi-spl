#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the plan of `run-all-tests.sh --changed` (doc
#          fleet-hot-commands-2026-10-07.md section 3.9): map the files this
#          tree changed since its merge-base with ORC_TEST_BASE (default
#          origin/master; committed, staged, unstaged and untracked) to the
#          *.tst.sh files next to this script. Not a test itself.
#
# A changed file selects every test that names it: its basename, its stem
# (basename without .func.sh / .inc.sh / .sh, at least 5 characters) or a
# shell function it defines now or defined at the base (so a renamed or
# deleted action still selects its old test). Only function names with a _
# or - count: a one-word name such as start or flush reads as prose in every
# test. A changed *.tst.sh selects itself. The functions a TEST file
# defines (*.tst.sh, test-*.sh, *.proof.sh, anything under fixtures/) are
# stubs, not the real thing: they never key a selection (an iac test that
# stubs do_log once selected all 198 orc tests). Its basename and stem
# still do. A shared test library (test-lib.inc.sh, lib.inc.sh) defines
# real helpers, so its functions still count. Prints tab-separated lines:
#   run<TAB><test file name><TAB><why>
#   ignore<TAB><repo path><TAB><why>
#   full<TAB><why>          (then nothing else: run the whole suite)
# It FAILS SAFE to `full`: no git tree, no merge-base, the ./run dispatcher
# changed, or a changed file under csi-spl-orc (not a .md) that no test
# names. A file outside csi-spl-orc that no orc test names is ignored, with
# its reason.
# The always-run tests (ORC_TEST_ALWAYS, space separated) join any selection.
# A test that reaches the changed file only through another file is NOT
# selected: CI and the default mode still run the whole suite.
# ORC_TEST_FILES (repo paths, space or newline separated) replaces the git
# change set, e.g. to see what a past commit would have run.
#------------------------------------------------------------------------------
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
base_ref="${ORC_TEST_BASE:-origin/master}"
always="${ORC_TEST_ALWAYS-require-cloud-env.tst.sh}"
# the action dispatcher every ./run -a test goes through: a change there is
# a change to every action
shared=' run src/bash/run/run.sh '

full() { printf 'full\t%s\n' "$1"; exit 0; }

top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || full "not a git tree"
tests_rel=$(git -C "$dir" rev-parse --show-prefix)   # <orc>/src/bash/tests/
orc="${tests_rel%src/bash/tests/}"                   # <orc>/
base=$(git -C "$top" merge-base "$base_ref" HEAD 2>/dev/null) || full "no merge-base with $base_ref (git fetch origin master first)"

if [[ -n "${ORC_TEST_FILES:-}" ]]; then
  changed=$(tr ' ' '\n' <<<"$ORC_TEST_FILES" | sort -u)   # a given change set (repo paths)
else
  changed=$( {
    git -C "$top" diff --name-only "$base"
    git -C "$top" ls-files --others --exclude-standard
  } | sort -u)
fi

# keys <repo path>: the names a test would use for this file, one per line
keys() {
  local f="$1" b stem
  b=$(basename "$f")
  (( ${#b} >= 5 )) && echo "$b"
  stem="${b%.func.sh}"; stem="${stem%.inc.sh}"; stem="${stem%.sh}"
  [[ "$stem" != "$b" ]] && (( ${#stem} >= 5 )) && echo "$stem"
  case "$b" in *.sh|*.bash|run) ;; *) return 0 ;; esac
  case "$b" in *.tst.sh|test-*.sh|*.proof.sh) return 0 ;; esac
  [[ "/$f" == */fixtures/* ]] && return 0
  { [[ -f "$top/$f" ]] && cat "$top/$f"; git -C "$top" show "$base:$f" 2>/dev/null; } \
    | sed -nE 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_:.-]*)[[:space:]]*\(\).*$/\2/p' \
    | while read -r fn; do
        (( ${#fn} >= 5 )) && [[ "$fn" == *[_-]* ]] || continue
        echo "$fn"
      done
  return 0
}

declare -A why=()
add() { [[ -n "${why[$1]:-}" ]] || why[$1]="$2"; }
kf=$(mktemp); trap 'rm -f "$kf"' EXIT
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  t="${f#"$tests_rel"}"
  [[ "$f" == "$orc"* && "$shared" == *" ${f#"$orc"} "* ]] && full "$f is shared by every action"
  if [[ "$f" == "$tests_rel"* && "$t" == *.tst.sh && "$t" != */* ]]; then
    if [[ -f "$dir/$t" ]]; then add "$t" "changed itself"; else printf 'ignore\t%s\t%s\n' "$f" "deleted test"; fi
    continue
  fi
  keys "$f" | sort -u >"$kf"
  hits=""
  [[ -s "$kf" ]] && hits=$(cd "$dir" && grep -lwF -f "$kf" -- *.tst.sh 2>/dev/null)
  if [[ -n "$hits" ]]; then
    while IFS= read -r t; do add "$t" "names $f"; done <<<"$hits"
  elif [[ "$f" == *.md ]]; then
    printf 'ignore\t%s\t%s\n' "$f" "doc"
  elif [[ "$f" == "$orc"* ]]; then
    full "no test names $f"
  else
    printf 'ignore\t%s\t%s\n' "$f" "outside ${orc%/}, no orc test names it"
  fi
done <<<"$changed"
for a in $always; do [[ -f "$dir/$a" ]] && add "$a" "always-run"; done
for t in "${!why[@]}"; do printf 'run\t%s\t%s\n' "$t" "${why[$t]}"; done | sort
