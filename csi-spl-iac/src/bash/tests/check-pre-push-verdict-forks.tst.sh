#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: _pp_verdict writes its line with bash builtins, no fork per line.
#          Its date + dirname + mkdir on every verdict line were 1598 of the
#          2831 execs of one check-pre-push-tree-pass.tst.sh run (c-973,
#          strace, n=3), and each fork costs most on a loaded CI runner.
#          A PATH shim counts every date / dirname / mkdir / id call.
#   1. 20 verdict lines into a log whose dir does not exist yet -> <= 1 fork
#      (the one mkdir), 20 lines
#   2. 20 more into the now existing dir -> 0 forks
#   3. a log path with no dir part ('pp.log' in the cwd) -> 0 forks, written
#   4. the line's bytes: '<UTC ts>Z <who> PART <part> <V> <n>s tree=<t>
#      HEAD=<h>[ <detail>]', the ts in UTC even with TZ set elsewhere, between
#      a `date -u` taken before and one taken after
#   CONTROL: the same function with its timestamp forked again
#      (now="$(date -u +%FT%TZ)") -> the shim counts 20 date calls: the
#      counter sees a fork when one is there
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FUNC="$TEST_DIR/../run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want '$2' got '$3'"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CNT="$T/forks"; mkdir -p "$T/shim"
for c in date dirname mkdir id; do
  real="$(command -v "$c")" || { fail "setup: no $c on PATH"; exit 1; }
  printf '#!/bin/sh\necho %s >>"%s"\nexec "%s" "$@"\n' "$c" "$CNT" "$real" >"$T/shim/$c"
  chmod +x "$T/shim/$c"
done

# <func-file> <log> <n> -> writes n verdict lines under the shim PATH (in $T,
# so a relative log lands there); prints how many date/dirname/mkdir/id ran.
verdicts() {
  : >"$CNT"
  # shellcheck source=/dev/null
  ( cd "$T" && . "$1" && _PP_LOG="$2" _PP_TOP=/t _PP_HEAD=abc123 && export TZ=Europe/Helsinki SPOOL_AGENT_ID=c-x \
      && PATH="$T/shim:$PATH" \
      && for ((i = 1; i <= $3; i++)); do _pp_verdict "part$i" PASS "$i" "d=$i"; done ) >/dev/null 2>&1
  wc -l <"$CNT" | tr -d ' '
}

LOG="$T/new/dir/pp.log"
n=$(verdicts "$FUNC" "$LOG" 20)
if [[ "$n" -le 1 ]]; then pass "1. 20 lines into a new dir: $n fork(s) (<= 1)"
else fail "1. 20 lines into a new dir" "$n forks: $(sort "$CNT" | uniq -c | tr '\n' ' ')"; fi
eq "1. 20 lines written" 20 "$(wc -l <"$LOG" | tr -d ' ')"

n=$(verdicts "$FUNC" "$LOG" 20)
eq "2. 20 lines into an existing dir: 0 forks" 0 "$n"
eq "2. 40 lines in all" 40 "$(wc -l <"$LOG" | tr -d ' ')"

n=$(verdicts "$FUNC" pp.log 20)
eq "3. a log with no dir part: 0 forks" 0 "$n"
eq "3. ... and it is written" 20 "$(wc -l <"$T/pp.log" | tr -d ' ')"

before="$(date -u +%FT%TZ)"
: >"$LOG"; verdicts "$FUNC" "$LOG" 1 >/dev/null
after="$(date -u +%FT%TZ)"
line="$(cat "$LOG")"
re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z c-x PART part1 PASS 1s tree=/t HEAD=abc123 d=1$'
if [[ "$line" =~ $re ]]; then pass "4. the line's bytes"; else fail "4. the line's bytes" "$line"; fi
ts="${line%% *}"
if [[ ! "$ts" < "$before" && ! "$ts" > "$after" ]]; then pass "4. the ts is UTC ($before <= $ts <= $after)"
else fail "4. the ts is UTC" "$ts not in [$before, $after]"; fi

# CONTROL: put the date fork back in a copy of the gate.
mkdir -p "$T/ctl"; cp "$(dirname "$FUNC")"/check-pre-push*.func.sh "$T/ctl/"
sed -i "s|TZ=UTC printf -v now '%(%FT%TZ)T' -1|now=\"\$(date -u +%FT%TZ)\"|" "$T/ctl/check-pre-push.func.sh"
# shellcheck disable=SC2016  # the literal line, not an expansion
if grep -qF 'now="$(date -u +%FT%TZ)"' "$T/ctl/check-pre-push.func.sh"; then
  n=$(verdicts "$T/ctl/check-pre-push.func.sh" "$LOG" 20)
  eq "CONTROL: the date fork put back is counted 20 times" 20 "$n"
else
  fail "CONTROL: could not put the date fork back" "the sed matched nothing: update it with _pp_verdict"
fi

echo "--- $fails failed ---"
[[ "$fails" -eq 0 ]]
