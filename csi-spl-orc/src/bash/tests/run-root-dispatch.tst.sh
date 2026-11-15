#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the repo-root ./run hands `-a do_x` to the module that defines it
#          (SPL-5550, spec 011). Runs the real root copy of run.sh in a
#          fixture repo: modules alpha and beta, their own run.sh copies.
#   1. the root copy is a real file, byte-identical to orc's, and root ./run
#      points to it
#   2. one owner: root ./run -a do_only_a runs alpha's action in alpha
#      (PROJ=alpha), with the caller's argv and env, kebab name too
#   3. two owners (do_both): named, refused with exit 2, nothing runs
#   4. -m picks: -m beta runs beta's do_both, -m alpha alpha's; an unknown
#      -m is refused (exit 2)
#   5. no owner: the modules' "NOT found" and exit 1
#   6. ./run --help lists the actions grouped by module
#   7. a module's own ./run is unchanged: it runs its action and refuses
#      the other module's (exit 1)
#   8. two actions of two modules in one call: refused (exit 2)
#   9. an action of the root's own src/bash/run/ runs at the root
#   Control: the same fixture with the pre-SPL-5550 root (./run a symlink to
#   a module's run, run.sh without its do_root_dispatch call) fails 2, 3
#   and 6, so the checks are not blind.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
RUN_SH="$REPO_ROOT/csi-spl-orc/src/bash/run/run.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1. the real tree
if [[ -f "$REPO_ROOT/src/bash/run/run.sh" && ! -L "$REPO_ROOT/src/bash/run/run.sh" ]] &&
  cmp -s "$RUN_SH" "$REPO_ROOT/src/bash/run/run.sh"; then
  pass "1. the root run.sh is a real file, byte-identical to orc's"
else fail "1. the root run.sh is a real copy of orc's" "$REPO_ROOT/src/bash/run/run.sh"; fi
if [[ "$(readlink "$REPO_ROOT/run")" == src/bash/run/run.sh ]]; then
  pass "1. root ./run points to src/bash/run/run.sh"
else fail "1. root ./run points to src/bash/run/run.sh" "$(readlink "$REPO_ROOT/run")"; fi

# mk_action <dir> <name> <body>: <dir>/src/bash/run/<kebab>.func.sh
mk_action() {
  local f="$1/src/bash/run/${2//_/-}.func.sh"
  printf '#!/bin/bash\n# @description fixture\n# @example ./run -a do_%s\ndo_%s() {\n  %s\n}\n' "$2" "$2" "$3" >"${f/do-/}"
}

# the module libs run.sh calls, stubbed
LIB='do_detect_base_paths() { :; }
do_load_config() { :; }
do_require_bin() { :; }
do_verify_symlinks() { :; }
do_parse_metadata() { :; }'

# mk_tree <root> <run.sh>: a fixture repo, <run.sh> in the root and 2 modules
mk_tree() {
  local r="$1" m
  for m in "$r" "$r/alpha" "$r/beta"; do
    mkdir -p "$m/src/bash/run" "$m/lib/bash/funcs"
    cp "$2" "$m/src/bash/run/run.sh"
    ln -s src/bash/run/run.sh "$m/run"
  done
  for m in "$r/alpha" "$r/beta"; do
    printf '%s\n' "$LIB" >"$m/lib/bash/funcs/fixture.func.sh"
    mk_action "$m" both "echo \"BOTH-RAN in \$PROJ\""
  done
  rm -f "$r/lib/bash/funcs" -r
  printf '%s\n' "$LIB" >"$r/src/bash/run/root-fixture-lib.func.sh"
  mk_action "$r/alpha" only_a "echo \"ONLY-A-RAN in \$PROJ args=\$* foo=\${FIXTURE_FOO:-}\""
  mk_action "$r/beta" only_b "echo \"ONLY-B-RAN in \$PROJ\""
  mk_action "$r" root_own "echo \"ROOT-OWN-RAN in \$PROJ\""
}

# run_in <dir> <args...>: ./run in <dir>, a clean env; sets out and rc
run_in() {
  local d="$1"; shift
  out=$(cd "$d" && env -i PATH=/usr/bin:/bin HOME="$T/home" VAR_DIR="$T/var" \
    XDG_CACHE_HOME="$T/cache" RUN_LOG_COMPACT=1 FIXTURE_FOO=bar ./run "$@" 2>&1)
  rc=$?
}

R="$T/repo"; mkdir -p "$R" "$T/home"; mk_tree "$R" "$RUN_SH"

# check_all <label prefix>: checks 2..9 on the fixture $R
check_all() {
  local p="$1"
  run_in "$R" -a do_only_a x1 --flag v
  if [[ $rc -eq 0 && "$out" == *"ONLY-A-RAN in alpha args=x1 --flag v foo=bar"* ]]; then
    pass "$p 2. one owner: runs in alpha with the argv and env"
  else fail "$p 2. one owner runs in alpha" "rc=$rc $(tail -3 <<<"$out")"; fi
  run_in "$R" -a only-b
  if [[ $rc -eq 0 && "$out" == *"ONLY-B-RAN in beta"* ]]; then pass "$p 2. kebab name runs in beta"
  else fail "$p 2. kebab name runs in beta" "rc=$rc $(tail -3 <<<"$out")"; fi

  run_in "$R" -a do_both
  if [[ $rc -eq 2 && "$out" == *alpha*beta*"-m <module>"* && "$out" != *BOTH-RAN* ]]; then
    pass "$p 3. two owners: named and refused, exit 2"
  else fail "$p 3. two owners refused" "rc=$rc $(tail -3 <<<"$out")"; fi

  run_in "$R" -m beta -a do_both
  if [[ $rc -eq 0 && "$out" == *"BOTH-RAN in beta"* ]]; then pass "$p 4. -m beta picks beta"
  else fail "$p 4. -m beta picks beta" "rc=$rc $(tail -3 <<<"$out")"; fi
  run_in "$R" -a do_both -m alpha
  if [[ $rc -eq 0 && "$out" == *"BOTH-RAN in alpha"* ]]; then pass "$p 4. -m alpha picks alpha"
  else fail "$p 4. -m alpha picks alpha" "rc=$rc $(tail -3 <<<"$out")"; fi
  run_in "$R" -m gamma -a do_both
  if [[ $rc -eq 2 && "$out" == *"no such module"* ]]; then pass "$p 4. an unknown -m is refused"
  else fail "$p 4. an unknown -m is refused" "rc=$rc $(tail -3 <<<"$out")"; fi

  run_in "$R" -a do_no_such_action
  if [[ $rc -eq 1 && "$out" == *'"do_no_such_action" NOT found'* ]]; then pass "$p 5. no owner: NOT found, exit 1"
  else fail "$p 5. no owner: NOT found, exit 1" "rc=$rc $(tail -3 <<<"$out")"; fi

  run_in "$R" --help
  if [[ $rc -eq 0 && "$out" == *$'alpha:\n'*do_both*do_only_a*$'beta:\n'*do_both*do_only_b* ]]; then
    pass "$p 6. --help groups the actions by module"
  else fail "$p 6. --help groups the actions by module" "rc=$rc $(head -12 <<<"$out")"; fi

  run_in "$R/alpha" -a do_only_a
  local a_rc=$rc a_out=$out
  run_in "$R/alpha" -a do_only_b
  if [[ $a_rc -eq 0 && "$a_out" == *"ONLY-A-RAN in alpha"* && $rc -eq 1 && "$out" == *"NOT found"* ]]; then
    pass "$p 7. a module's ./run runs its own action, refuses beta's"
  else fail "$p 7. module ./run unchanged" "rc=$a_rc/$rc $(tail -2 <<<"$out")"; fi

  run_in "$R" -a do_only_a -a do_only_b
  if [[ $rc -eq 2 && "$out" == *"one ./run call per module"* ]]; then pass "$p 8. actions of two modules: refused"
  else fail "$p 8. actions of two modules refused" "rc=$rc $(tail -3 <<<"$out")"; fi

  run_in "$R" -a do_root_own
  if [[ $rc -eq 0 && "$out" == *"ROOT-OWN-RAN in repo"* ]]; then pass "$p 9. a root action runs at the root"
  else fail "$p 9. a root action runs at the root" "rc=$rc $(tail -3 <<<"$out")"; fi
}
check_all ""

# Control: the old root, a symlink to a module's ./run, and run.sh without
# its do_root_dispatch call
before=$fails
sed '/^  do_root_dispatch "\$@"$/d' "$RUN_SH" >"$T/old-run.sh"
cmp -s "$RUN_SH" "$T/old-run.sh" && fail "CONTROL the sed removed no do_root_dispatch call"
rm -rf "$R"; mkdir -p "$R"; mk_tree "$R" "$T/old-run.sh"
rm -rf "$R/run" "$R/src"; ln -s alpha/run "$R/run"
check_all "CONTROL" >"$T/control.out"
cf=$((fails - before)); fails=$before
if grep -q '^FAIL: CONTROL 2\. one owner' "$T/control.out" &&
  grep -q '^FAIL: CONTROL 3\.' "$T/control.out" && grep -q '^FAIL: CONTROL 6\.' "$T/control.out"; then
  pass "CONTROL the old root ./run fails 2, 3 and 6 ($cf checks red)"
else fail "CONTROL the old root ./run must fail 2, 3 and 6" "$(grep -m5 FAIL "$T/control.out")"; fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
