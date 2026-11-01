#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for the ./run --help listing of csi-spl-iac and csi-spl-orc
# (SPL-4553; the same blob sits in both, each run against its own component).
# ./run dispatches only the names in its _func_to_file map: the filename
# rule of do_load_functions plus the extra names a file registers itself.
# The help must list exactly those names, so every line it prints runs.
#   1. ./run --help exits 0
#   2. Every "./run -a do_*" the help prints is a name ./run dispatches
#   3. Every name ./run dispatches from src/bash/run/ is printed
#   4. The help names no do_help_with (iac and orc define none)
#   5. The run-all line it prints names a file that exists
# Only the help and the loader run; no action is ever started.
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PRJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The dispatcher's map, built by run.sh's own loader with main left out, so
# the names are the ones ./run -a accepts and nothing is run
P="$PRJ_ROOT" bash -c '
  source <(sed "/^main \"\$@\"\$/d" "$P/src/bash/run/run.sh")
  PROJ_PATH=$P
  do_load_functions
  for k in "${!_func_to_file[@]}"; do
    [[ "${_func_to_file[$k]}" == "$P/src/bash/run/"* ]] && echo "$k"
  done | sort -u' > "$T/dispatched" 2> "$T/loader.err"

# 1. the help runs
out=$(cd "$PRJ_ROOT" && ./run --help 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then pass "1. ./run --help exits 0"; else fail "1. ./run --help rc=$rc"; fi
grep -oE '\./run -a do_[A-Za-z0-9_]+' <<<"$out" | sed 's/^\.\/run -a //' | sort -u > "$T/listed"

if [[ ! -s "$T/dispatched" ]]; then
  fail "the loader probe found no actions ($(head -3 "$T/loader.err"))"
else
  # 2. no listed name that ./run would refuse with "NOT found"
  bad=$(comm -23 "$T/listed" "$T/dispatched" | tr '\n' ' ')
  if [[ -z "$bad" ]]; then
    pass "2. all $(wc -l < "$T/listed") listed names are dispatched by ./run"
  else
    fail "2. listed but ./run -a refuses them: $bad"
  fi

  # 3. no dispatched action missing from the help
  missing=$(comm -13 "$T/listed" "$T/dispatched" | tr '\n' ' ')
  if [[ -z "$missing" ]]; then
    pass "3. all $(wc -l < "$T/dispatched") dispatched names are listed"
  else
    fail "3. dispatched but not listed: $missing"
  fi
fi

# 4. no advertised action that no component defines
if grep -q 'do_help_with' <<<"$out"; then
  fail "4. the help still names do_help_with: $(grep -m1 do_help_with <<<"$out")"
else
  pass "4. the help names no do_help_with"
fi

# 5. the "Run all tests" line points at a file of this component
suite=$(grep -A1 'Run all tests:' <<<"$out" | grep -oE 'bash [^ ]+' | sed 's/^bash //')
if [[ -n "$suite" && -f "$PRJ_ROOT/$suite" ]]; then
  pass "5. the run-all line names $suite, which exists"
else
  fail "5. the run-all line names '${suite}', not a file under $PRJ_ROOT"
fi

echo "=========================================="
echo "print-help: $fails failure(s)"
echo "=========================================="
exit $(( fails > 0 ))
