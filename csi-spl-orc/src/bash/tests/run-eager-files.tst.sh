#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the orc ./run loader stubs the five files that cost most of its
#          eager phase (spec 027, perf round 7 row 04, p7-04): their
#          dependency `source` lines and constants run on the first call, not
#          at source time. Measured on ccef654f0: 236 ms of a 494 ms eager
#          phase (n=5), 98 eager files.
#   Round 8 row 01 (p8-01) stubs the next five (NEXT5) the same way.
#   1. the run.sh index lists none of the five, nor of NEXT5, as eager
#   2. the orc eager count is at most 88
#   3. each file, sourced alone in a clean shell, prints nothing, runs no
#      dpkg (gh-runner-add used to at source time) and defines its action
#      (spl-rotate-lib, a library, its entry spl_rotate_conf)
#   Control: the same index over a copy of one file of each list with a
#   top-level `source` put back reads that file eager, and check 1 fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
RUN_DIR="$PROJ_ROOT/src/bash/run"
FIVE=(spl-agent-restart spl-sender-audit gh-runner-add spl-box-restart-after spl-agent-login-check)
NEXT5=(spl-watchdog spl-gc spl-agent-login2-sync spl-box-leave spl-rotate-lib)
MAX_EAGER=88

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed '/^main "\$@"$/d' "$RUN_DIR/run.sh" >"$T/nomain.sh"

# eager_of <file...>: the files the run.sh index calls eager, one per line
eager_of() {
  bash -c 'source "$1" >/dev/null 2>&1; trap - ERR; set +u; shift
    _rl_eager=(); _rl_cand=(); declare -A _rl_files=()
    eval "$(printf "%s\0" "$@" | xargs -0 -r awk "$_RUN_INDEX_AWK")"
    printf "%s\n" "${_rl_eager[@]}"' _ "$T/nomain.sh" "$@"
}

# check_five <eager list> <label>: none of the five, nor of NEXT5, in the list
check_five() {
  local hit="" f
  for f in "${FIVE[@]}" "${NEXT5[@]}"; do grep -q "/$f\.func\.sh$" <<<"$1" && hit+=" $f"; done
  if [[ -z "$hit" ]]; then pass "$2: none of the five is eager"; else fail "$2: eager" "$hit"; fi
}

mapfile -d '' files < <(find "$PROJ_ROOT/lib/bash/funcs" "$RUN_DIR" -type f -name '*.func.sh' -print0 | sort -z)
eager="$(eager_of "${files[@]}")"
n=$(grep -c . <<<"$eager")
check_five "$eager" "1. orc index"
if (( n > 0 && n <= MAX_EAGER )); then pass "2. orc eager files: $n (at most $MAX_EAGER)"
else fail "2. orc eager files at most $MAX_EAGER" "$n"; fi

# 3. sourced alone: a dpkg shim records any call
mkdir -p "$T/shim"; printf '#!/bin/sh\necho "$0 $*" >>"%s/dpkg.log"\nexit 1\n' "$T" >"$T/shim/dpkg"
cp "$T/shim/dpkg" "$T/shim/dpkg-query"; chmod +x "$T/shim/dpkg" "$T/shim/dpkg-query"
for f in "${FIVE[@]}" "${NEXT5[@]}"; do
  act="do_${f//-/_}"; [[ "$f" == spl-rotate-lib ]] && act=spl_rotate_conf; : >"$T/dpkg.log"
  out=$(env -i HOME="$T" PATH="$T/shim:/usr/bin:/bin" bash -c 'do_log() { :; }; source "$1" </dev/null; declare -F "$2" >/dev/null || echo "NOACTION $2"' _ "$RUN_DIR/$f.func.sh" "$act" 2>&1)
  if [[ -z "$out" && ! -s "$T/dpkg.log" ]]; then pass "3. $f sourced alone: silent, no dpkg, defines $act"
  else fail "3. $f sourced alone" "out='$out' dpkg='$(cat "$T/dpkg.log")'"; fi
done

# Control: one top-level `source` put back reads that file eager
# control <file> <its action>: plant it in a copy of <file>, re-index
control() {
  local f="$1" act="$2" planted
  cp "$RUN_DIR/$f.func.sh" "$T/$f.func.sh"
  sed -i "0,/^$act() {\$/s//source \/dev\/null\n&/" "$T/$f.func.sh"
  planted=("${files[@]/#$RUN_DIR\/$f.func.sh/$T/$f.func.sh}")
  if ! grep -q '^source /dev/null$' "$T/$f.func.sh"; then fail "CONTROL $f the plant applied" "sed matched nothing"; return; fi
  local before=$fails
  check_five "$(eager_of "${planted[@]}")" "CONTROL planted" >/dev/null
  if (( fails > before )); then fails=$before; pass "CONTROL $f: a top-level source put back reads the file eager, check 1 fails"
  else fail "CONTROL $f: a top-level source put back fails check 1" "it passed"; fi
}
control spl-sender-audit do_spl_sender_audit
control spl-gc do_spl_gc

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
