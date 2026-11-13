#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: ./run (the run.sh of csi-spl-iac, -orc and -utl) starts its Bash
#          with GLIBC_TUNABLES glibc.malloc.top_pad=134217728 (spec 027
#          os-tweaks-analysis.md row 1b, SPL-5421): malloc then grows the heap
#          in steps huge pages can back, and each fork of a loaded ./run costs
#          less kernel time. glibc reads the tunable only at exec, so run.sh
#          re-execs itself once (do_run_top_pad); an export alone would not
#          reach the ./run Bash.
#   Checks, for each run.sh, on a fixture tree BASE/org/app/app-iac:
#     1. no GLIBC_TUNABLES: the action's /proc/$$/environ (what the Bash got
#        at exec) carries glibc.malloc.top_pad=134217728, in the same pid
#     2. an existing GLIBC_TUNABLES is kept, the pad appended after it
#     3. an existing top_pad wins: no re-exec, value unchanged
#     4. the args reach the action unchanged (a space, an empty one) and its
#        exit status is ./run's
#   Control: the same tree with the do_run_top_pad call removed fails check 1.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PAD=glibc.malloc.top_pad=134217728

# fixture <dir> <run.sh source>: a project tree whose one action prints
# what its Bash got at exec, its pid and its args, then exits PROBE_RC.
fixture() {
  local P="$1/base/org1/app1/app1-iac"
  mkdir -p "$P/src/bash/run" "$P/lib/bash/funcs"
  cp "$2" "$P/src/bash/run/run.sh" && chmod +x "$P/src/bash/run/run.sh"
  ln -s src/bash/run/run.sh "$P/run"
  printf '%s\n' 'do_detect_base_paths(){ :; }' 'do_load_config(){ :; }' \
    'do_require_bin(){ :; }' 'do_verify_symlinks(){ :; }' 'do_parse_metadata(){ :; }' >"$P/lib/bash/funcs/fw.func.sh"
  cat >"$P/src/bash/run/probe.func.sh" <<'EOP'
do_probe() {
  echo "ENVIRON=$(tr '\0' '\n' </proc/$$/environ | sed -n 's/^GLIBC_TUNABLES=//p')"
  echo "PID=$$ PADPID=${RUN_TOP_PAD_PID:-}"
  printf 'ARG=<%s>\n' "$@"
  return "${PROBE_RC:-0}"
}
EOP
  echo "$P"
}

# run_probe <proj> [env...] -- <args>: ./run -a do_probe with a clean env
run_probe() {
  local P="$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  (cd "$P" && env -u GLIBC_TUNABLES -u RUN_TOP_PAD_PID HOME="$T/home" RUN_LOG=compact \
    "${envs[@]}" ./run -a do_probe "$@" 2>&1)
}

for mod in iac orc utl; do
  src="$REPO_ROOT/csi-spl-$mod/src/bash/run/run.sh"
  [ -f "$src" ] || { fail "$mod run.sh exists" "$src"; continue; }
  P=$(fixture "$T/$mod" "$src")

  out=$(run_probe "$P" --)
  grep -qx "ENVIRON=$PAD" <<<"$out" && pass "$mod: 1. the ./run Bash starts with $PAD" \
    || fail "$mod: 1. the ./run Bash starts with $PAD" "$out"
  pid=$(sed -n 's/^PID=\([0-9]*\) PADPID=\([0-9]*\)$/\1 \2/p' <<<"$out")
  [[ -n "$pid" && "${pid% *}" == "${pid#* }" ]] && pass "$mod: 1. re-exec kept the pid" \
    || fail "$mod: 1. re-exec kept the pid" "$out"

  out=$(run_probe "$P" GLIBC_TUNABLES=glibc.malloc.hugetlb=1 --)
  grep -qx "ENVIRON=glibc.malloc.hugetlb=1:$PAD" <<<"$out" && pass "$mod: 2. an existing GLIBC_TUNABLES is kept, the pad appended" \
    || fail "$mod: 2. an existing GLIBC_TUNABLES is kept" "$out"

  out=$(run_probe "$P" GLIBC_TUNABLES=glibc.malloc.top_pad=131072 --)
  grep -qx "ENVIRON=glibc.malloc.top_pad=131072" <<<"$out" && grep -qx "PID=[0-9]* PADPID=" <<<"$out" \
    && pass "$mod: 3. an existing top_pad wins, no re-exec" \
    || fail "$mod: 3. an existing top_pad wins" "$out"

  out=$(run_probe "$P" PROBE_RC=3 -- "a b" "" --json); rc=$?
  args=$(grep '^ARG=' <<<"$out")
  [[ "$args" == $'ARG=<a b>\nARG=<>\nARG=<--json>' ]] \
    && pass "$mod: 4. args reach the action unchanged" || fail "$mod: 4. args reach the action unchanged" "$out"
  [[ $rc -eq 3 ]] && pass "$mod: 4. the action's exit status is ./run's" || fail "$mod: 4. exit status" "rc=$rc"
done

# Control: without the call, check 1 sees no pad
sed '/^  do_run_top_pad "\$@"$/d' "$REPO_ROOT/csi-spl-iac/src/bash/run/run.sh" >"$T/run-nopad.sh"
cmp -s "$T/run-nopad.sh" "$REPO_ROOT/csi-spl-iac/src/bash/run/run.sh" && fail "CONTROL the call was removed" "sed matched nothing"
P=$(fixture "$T/control" "$T/run-nopad.sh")
out=$(run_probe "$P" --)
if ! grep -q '^ENVIRON=' <<<"$out"; then fail "CONTROL the probe ran" "$out"
elif grep -qx "ENVIRON=$PAD" <<<"$out"; then fail "CONTROL without do_run_top_pad the Bash has no pad" "$out"
else pass "CONTROL without do_run_top_pad check 1 fails (the probe ran, no pad)"; fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
