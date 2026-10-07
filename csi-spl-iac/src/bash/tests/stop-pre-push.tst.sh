#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_stop_pre_push stops ONE pre-push run by its pid, never by a
#          pattern. On 2026-10-06 `pkill -f do_check_pre_push` matched every
#          agent's argv (the action name is in each seed prompt) and killed 15
#          claude sessions in 0.7 s. Two dummies whose argv carries
#          'do_check_pre_push' (a bash -c line, and an exec -a "claude ..."
#          stand-in for an agent) must survive every stop below.
#     1. no run recorded                -> rc 0, nothing signalled
#     2. a running gate writes its pidfile (pid, pgid, start time, tree)
#     3. stop -> the gate and the part it was running are gone, the pidfile
#        is removed, both dummies are alive
#     4. two trees, two gates: stopping tree A leaves tree B's gate running
#     5. a stale pidfile naming a LIVE dummy with another start time (a
#        re-used pid) -> removed, the dummy is NOT signalled
#     6. a gate that finishes normally removes its own pidfile
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d)
declare -a PIDS=()
# Every process this test started is stopped by its pid and the pids below it
# (a killed `bash -c` would orphan its sleep, which holds the caller's pipe
# open), never by a pattern.
cleanup() {
  local p q
  for p in "${PIDS[@]}"; do
    for q in $(_pp_proc_tree "$p"); do kill "$q" 2>/dev/null; done
  done
  rm -rf "$T"
}
trap cleanup EXIT
export XDG_CACHE_HOME="$T/xdg"

do_log() { echo "$*"; }
# The hygiene part stands in for a long part: it records the pid of the
# process it runs, then waits on it.
do_check_dist_hygiene() {
  sleep "${STUB_SLEEP:-0}" & echo "$!" >"$STUB_CHILD"
  wait "$!"
}
# shellcheck source=../run/stop-pre-push.func.sh
. "$PROJ_ROOT/src/bash/run/stop-pre-push.func.sh"

for r in A B; do
  git init -q "$T/$r"; echo x >"$T/$r/f"
  git -C "$T/$r" add -A; git -C "$T/$r" commit -qm seed; git -C "$T/$r" branch trunk
done

gate_bg() {  # <tree> <sleep> -> sets GATE_PID
  ( export PRE_PUSH_TREE="$1" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$T/log" PRE_PUSH_CACHE="$T/cache.$RANDOM" \
      PRE_PUSH_EXTRA_PATH='' PRE_PUSH_LINT=0 STUB_SLEEP="$2" STUB_CHILD="$1.child"
    do_check_pre_push ) >"$1.out" 2>&1 &
  GATE_PID=$!; PIDS+=("$GATE_PID")
}
wait_for() {  # <file> -> 0 once it is non-empty (5 s max)
  local i; for ((i = 0; i < 50; i++)); do [[ -s "$1" ]] && return 0; sleep 0.1; done; return 1
}
stop() {  # <tree>
  ( PRE_PUSH_TREE="$1" PRE_PUSH_STOP_GRACE=3 do_stop_pre_push ) >"$T/stop.out" 2>&1
}

# The dummies: argv carries the action name, as every agent's seed prompt does.
# Dummy 1 has no child (a builtin read on a fifo), so killing it orphans nothing.
mkfifo "$T/fifo"
bash -c 'read -r -t 300 _ <>"$1"; : do_check_pre_push' _ "$T/fifo" >/dev/null 2>&1 &
D1=$!; PIDS+=("$D1")
( exec -a "claude --seed run do_check_pre_push before every push" sleep 300 ) >/dev/null 2>&1 &
D2=$!; PIDS+=("$D2")
sleep 0.2
eq "0. dummy 1 argv carries the action name" 1 "$(tr '\0' ' ' </proc/$D1/cmdline | grep -c do_check_pre_push)"
eq "0. dummy 2 argv carries the action name" 1 "$(tr '\0' ' ' </proc/$D2/cmdline | grep -c do_check_pre_push)"

# 1
stop "$T/A"; eq "1. nothing recorded -> rc 0" 0 "$?"
grep -q 'nothing to stop' "$T/stop.out" && pass "1. ... says nothing to stop" || fail "1. ... says nothing to stop" "$(cat "$T/stop.out")"

# 2
PFA="$(_pp_pidfile "$T/A")"; PFB="$(_pp_pidfile "$T/B")"
[[ "$PFA" != "$PFB" ]] && pass "2. one pidfile per tree" || fail "2. one pidfile per tree" "$PFA"
gate_bg "$T/A" 300; GA=$GATE_PID
gate_bg "$T/B" 300; GB=$GATE_PID
wait_for "$T/A.child" && wait_for "$T/B.child" || fail "2. both gates reached their part" "$(cat "$T/A.out" "$T/B.out")"
CA="$(cat "$T/A.child")"; CB="$(cat "$T/B.child")"; PIDS+=("$CA" "$CB")
read -r p g s tr <"$PFA"
eq "2. pidfile names the gate pid" "$GA" "$p"
eq "2. ... its start time" "$(_pp_starttime "$GA")" "$s"
eq "2. ... its tree" "$T/A" "$tr"
[[ "$g" =~ ^[0-9]+$ ]] && pass "2. ... its pgid" || fail "2. ... its pgid" "'$g'"

# 3 + 4
stop "$T/A"; eq "3. stop tree A -> rc 0" 0 "$?"
sleep 0.3
eq "3. tree A's gate is gone" gone "$(alive "$GA")"
eq "3. ... and the part it was running" gone "$(alive "$CA")"
eq "3. ... its pidfile is removed" no "$([[ -e "$PFA" ]] && echo yes || echo no)"
eq "3. dummy 1 (argv has do_check_pre_push) survives" alive "$(alive "$D1")"
eq "3. dummy 2 (claude stand-in) survives" alive "$(alive "$D2")"
eq "4. tree B's gate still runs" alive "$(alive "$GB")"
eq "4. ... and its part" alive "$(alive "$CB")"
stop "$T/B"; sleep 0.3
eq "4. then stopping tree B stops it" gone "$(alive "$GB")"
eq "4. ... dummy 1 still survives" alive "$(alive "$D1")"

# 5
mkdir -p "$(dirname "$PFA")"
echo "$D1 $D1 1 $T/A" >"$PFA"
stop "$T/A"; eq "5. stale pidfile (re-used pid) -> rc 0" 0 "$?"
eq "5. ... the live process behind it is NOT signalled" alive "$(alive "$D1")"
eq "5. ... the stale pidfile is removed" no "$([[ -e "$PFA" ]] && echo yes || echo no)"
grep -q 'stale pidfile' "$T/stop.out" && pass "5. ... says stale" || fail "5. ... says stale" "$(cat "$T/stop.out")"

# 6
rm -f "$T/A.child"; gate_bg "$T/A" 0; wait "$GATE_PID"
eq "6. a quick gate passes" 0 "$?"
eq "6. ... and removes its own pidfile" no "$([[ -e "$PFA" ]] && echo yes || echo no)"
eq "6. dummy 2 survives to the end" alive "$(alive "$D2")"

echo ""
[ "$fails" -eq 0 ] && { echo "OK: stop-pre-push.tst.sh"; exit 0; }
echo "FAILED: $fails"; exit 1
