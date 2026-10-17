#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-05: tmux server socket liveness guard (SPL-2369)
# Drives do_fleet_tmux_health_guard against a PRIVATE tmux server
# (TMUX_TMPDIR=<temp> tmux -L test-probe); the box's own tmux server is never
# probed. A frozen server is a real one: the private server gets SIGSTOP.
#   1. responsive server -> OK, sessions=1, exit 0; best of 5 probes < 50 ms
#   2. frozen server (SIGSTOP), DRY_RUN=1 -> HUNG in < 5 s, exit 1, PLAN only,
#      nothing sent, no stamp; the server lives on after SIGCONT (not killed)
#   3. frozen server, DRY_RUN=0 -> one note to orchestrator, --no-poke, stamp HUNG
#   4. same state again -> throttled, nothing sent
#   5. state change (server gone, DOWN) -> sent at once despite the throttle
#   6. throttle expired (old stamp) -> sent again
#   7. server back, DRY_RUN=1 keeps the stamp; DRY_RUN=0 clears it (exit 0)
#   8. socket of another uid -> NOT_OWNER, exit 2, tmux never called
#  8b. socket dir this user cannot enter (mode 700) -> NOT_OWNER, not DOWN
#   9. unexpected probe failure -> ERROR with its message, exit 1
#  10. TMUX_HEALTH_TIMEOUT outside 1..4 -> exit 2, tmux never called
#  11. ./run -a do_fleet_tmux_health_guard (the plan's name) and
#      ./run -a do_tmux_health_guard (the file's name) both run it
#  12. a failed send writes no stamp
#  13. no TMUX_HEALTH_SEND_CMD -> the repo-relative spool-send.sh is used
#      (a sentinel under the temp dir), from tmux-health-guard@<box>
#  14. the socket is SPOOL_TMUX_SOCKET (the fleet's) when set, else
#      $TMUX_TMPDIR/tmux-<uid>/default
#  15. LIVE GUARD: every guard probe used a socket under the temp dir; no call
#      reached a spool-send.sh outside it, nor the spool binary
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="${TMUX_HEALTH_TST_FUNC_SH:-$UTL_ROOT/src/bash/run/tmux-health-guard.func.sh}"

if ! command -v tmux >/dev/null 2>&1; then
  fail "no tmux on PATH: the private-server cases did not run and prove nothing"
  echo "tmux-health-guard: $fails failure(s)"; exit 1
fi
REAL_TMUX="$(command -v tmux)"

T=$(mktemp -d /tmp/thg.XXXXXX)
BIN="$T/bin" STATE="$T/state"
SENT="$T/sent.log" PROBES="$T/probes.log" LIVE_LOG="$T/live-calls.log" SENTINEL_LOG="$T/sentinel.log"
mkdir -p "$BIN" "$STATE" "$T/tt"
: >"$SENT"; : >"$PROBES"; : >"$LIVE_LOG"; : >"$SENTINEL_LOG"
unset TMUX TMUX_PANE SPOOL_AGENT_ID TMUX_HEALTH_ALERT_FROM TMUX_HEALTH_SOCKET SPOOL_TMUX_SOCKET
export TMUX_TMPDIR="$T/tt"
SOCK="$T/tt/tmux-$(id -u)/test-probe"

srv() { "$REAL_TMUX" -L test-probe "$@"; }
SRV_PID=""
cleanup() {
  [[ -n "$SRV_PID" ]] && kill -CONT "$SRV_PID" 2>/dev/null
  srv kill-server >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
start_srv() {
  srv -f /dev/null new-session -d -s probe -x 80 -y 24 "sleep 3600" || return 1
  SRV_PID="$(srv display-message -p '#{pid}')"
}

# the probe tmux records its arguments, then runs the real tmux
cat >"$BIN/tmux-rec" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$PROBES"
exec "$REAL_TMUX" "\$@"
EOF
cat >"$BIN/send-stub" <<EOF
#!/bin/bash
printf 'SEND %s\n' "\$*" >>"$SENT"
EOF
cat >"$BIN/send-fail" <<'EOF'
#!/bin/bash
exit 1
EOF
# LIVE GUARD shims: bash running a spool-send.sh outside $T, and the spool
# binary, are recorded and refused (never executed)
cat >"$BIN/bash" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == */spool-send.sh && "\$a" != "$T"/* ]]; then
    printf 'bash %s\n' "\$*" >>"$LIVE_LOG"; exit 97
  fi
done
exec /bin/bash "\$@"
EOF
cat >"$BIN/spool" <<EOF
#!/bin/bash
printf 'spool %s\n' "\$*" >>"$LIVE_LOG"; exit 97
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

export TMUX_HEALTH_SOCKET="$SOCK" TMUX_HEALTH_TMUX_BIN="$BIN/tmux-rec"
export TMUX_HEALTH_STATE_DIR="$STATE" TMUX_HEALTH_SEND_CMD="$BIN/send-stub"
export PROJ_PATH="$UTL_ROOT"
STAMP="${SOCK//\//_}"; STAMP="$STATE/${STAMP#_}.stamp"

# guard - one guard run, its output through a file under a hard timeout: a
# guard that captures tmux through a pipe hangs on a frozen server (the client
# passes that pipe to the server), so a regression fails here, never hangs
guard() {
  local f="$T/guard.out" rc
  # shellcheck disable=SC2016 # $1 expands in the child bash
  timeout -k 2 15 bash -c 'source "$1" && do_fleet_tmux_health_guard' _ "$FUNC_SH" >"$f" 2>&1
  rc=$?
  cat "$f"
  return "$rc"
}
now_ms() { local t="${EPOCHREALTIME/[.,]/}"; echo $((10#$t / 1000)); }

# ---- 1. responsive server ---------------------------------------------------
if ! start_srv; then
  fail "1. could not start the private tmux server at $SOCK"
  echo "tmux-health-guard: $fails failure(s)"; exit 1
fi
out=$(DRY_RUN=1 guard 2>&1); rc=$?
best=999999
for _ in 1 2 3 4 5; do
  o=$(DRY_RUN=1 guard 2>&1)
  ms=$(sed -n 's/.* ms=\([0-9]*\).*/\1/p' <<<"$o")
  [[ "$ms" =~ ^[0-9]+$ ]] && ((ms < best)) && best=$ms
done
if ((rc == 0)) && [[ "$out" == *"tmux-health OK socket=$SOCK sessions=1 "* ]] && ((best < 50)); then
  pass "1. responsive server: OK, sessions=1, exit 0, best of 5 probes ${best} ms (< 50)"
else
  fail "1. responsive server (rc=$rc best=${best}ms out=$out)"
fi

# ---- 2. frozen server, DRY_RUN=1 ---------------------------------------------
kill -STOP "$SRV_PID"
t0=$(now_ms); out=$(DRY_RUN=1 guard 2>&1); rc=$?; wall=$(( $(now_ms) - t0 ))
kill -CONT "$SRV_PID"
alive=$(srv list-sessions -F '#{session_name}' 2>/dev/null)
if ((rc == 1 && wall < 5000)) && [[ "$out" == *"tmux-health HUNG socket=$SOCK"* ]] \
   && [[ "$out" == *"PLAN note to orchestrator on task tmux-health"* ]] \
   && [[ ! -s "$SENT" && ! -f "$STAMP" && "$alive" == probe ]]; then
  pass "2. frozen server flagged HUNG in ${wall} ms (< 5000), PLAN only, server alive after SIGCONT"
else
  fail "2. frozen server dry run (rc=$rc wall=${wall}ms alive=$alive out=$out)"
fi

# ---- 3. frozen server, DRY_RUN=0 ---------------------------------------------
kill -STOP "$SRV_PID"
out=$(DRY_RUN=0 TMUX_HEALTH_TIMEOUT=1 guard 2>&1); rc=$?
kill -CONT "$SRV_PID"
if ((rc == 1)) && [[ $(grep -c '^SEND ' "$SENT") == 1 ]] \
   && grep -q -- "--to orchestrator --kind note --task tmux-health --no-poke --body tmux-health HUNG" "$SENT" \
   && read -r st _ <"$STAMP" && [[ "$st" == HUNG ]]; then
  pass "3. frozen server, DRY_RUN=0: one note to orchestrator with --no-poke, stamp HUNG"
else
  fail "3. frozen server real run (rc=$rc sent=$(cat "$SENT") out=$out)"
fi

# ---- 4. same state again: throttled ------------------------------------------
: >"$SENT"
kill -STOP "$SRV_PID"
out=$(DRY_RUN=0 TMUX_HEALTH_TIMEOUT=1 guard 2>&1); rc=$?
kill -CONT "$SRV_PID"
if ((rc == 1)) && [[ ! -s "$SENT" && "$out" == *"HUNG alert throttled by"* ]]; then
  pass "4. same HUNG state within the throttle: nothing sent"
else
  fail "4. throttle (rc=$rc sent=$(cat "$SENT") out=$out)"
fi

# ---- 5. state change -> DOWN sent at once ------------------------------------
srv kill-server >/dev/null 2>&1; SRV_PID=""
out=$(DRY_RUN=0 guard 2>&1); rc=$?
if ((rc == 1)) && [[ "$out" == *"tmux-health DOWN socket=$SOCK"* ]] \
   && grep -q "body tmux-health DOWN" "$SENT" && read -r st _ <"$STAMP" && [[ "$st" == DOWN ]]; then
  pass "5. server gone: DOWN sent at once despite the HUNG stamp"
else
  fail "5. state change (rc=$rc sent=$(cat "$SENT") out=$out)"
fi

# ---- 6. throttle expired -----------------------------------------------------
: >"$SENT"
echo "DOWN $(( $(date +%s) - 4000 ))" >"$STAMP"
out=$(DRY_RUN=0 guard 2>&1); rc=$?
if ((rc == 1)) && [[ $(grep -c '^SEND ' "$SENT") == 1 ]]; then
  pass "6. stamp older than TMUX_HEALTH_THROTTLE_S: alert sent again"
else
  fail "6. throttle expiry (rc=$rc sent=$(cat "$SENT") out=$out)"
fi

# ---- 7. recovery -------------------------------------------------------------
start_srv
DRY_RUN=1 guard >/dev/null 2>&1; rc1=$?; kept=$([[ -f "$STAMP" ]] && echo 1 || echo 0)
out2=$(DRY_RUN=0 guard 2>&1); rc2=$?
if ((rc1 == 0 && rc2 == 0 && kept == 1)) && [[ ! -f "$STAMP" ]]; then
  pass "7. server back: DRY_RUN=1 keeps the stamp, DRY_RUN=0 clears it"
else
  fail "7. recovery (rc1=$rc1 rc2=$rc2 kept=$kept out=$out2)"
fi

# ---- 8. socket of another uid -> NOT_OWNER ------------------------------------
np=$(wc -l <"$PROBES"); : >"$SENT"
cat >"$BIN/stat" <<EOF
#!/bin/bash
echo \$(( \$(id -u) + 1 ))
EOF
chmod +x "$BIN/stat"
out=$(DRY_RUN=0 guard 2>&1); rc=$?
rm -f "$BIN/stat"
if ((rc == 2)) && [[ "$out" == *"NOT_OWNER socket=$SOCK"* && "$out" == *"run it as the socket owner"* ]] \
   && [[ $(wc -l <"$PROBES") == "$np" && ! -s "$SENT" ]]; then
  pass "8. socket of another uid: NOT_OWNER, exit 2, tmux never called, nothing sent"
else
  fail "8. not owner (rc=$rc probes=$(wc -l <"$PROBES") vs $np sent=$(cat "$SENT") out=$out)"
fi

# ---- 8b. socket dir of another user (mode 700) -> NOT_OWNER, not DOWN -------
mkdir -p "$T/closed"; chmod 000 "$T/closed"
cat >"$BIN/stat" <<EOF
#!/bin/bash
echo \$(( \$(id -u) + 1 ))
EOF
chmod +x "$BIN/stat"
out=$(DRY_RUN=1 TMUX_HEALTH_SOCKET="$T/closed/default" guard 2>&1); rc=$?
rm -f "$BIN/stat"; chmod 700 "$T/closed"
if (( $(id -u) == 0 )); then
  pass "8b. (root enters every dir: a closed socket dir cannot be simulated; not checked)"
elif ((rc == 2)) && [[ "$out" == *"NOT_OWNER socket=$T/closed/default"* && "$out" != *DOWN* ]]; then
  pass "8b. socket dir this user cannot enter: NOT_OWNER, exit 2, no DOWN false alarm"
else
  fail "8b. closed socket dir (rc=$rc out=$out)"
fi

# ---- 9. unexpected probe failure -> ERROR --------------------------------------
cat >"$BIN/tmux-err" <<'EOF'
#!/bin/bash
echo "protocol version mismatch (client 8, server 7)" >&2; exit 1
EOF
chmod +x "$BIN/tmux-err"
out=$(DRY_RUN=1 TMUX_HEALTH_TMUX_BIN="$BIN/tmux-err" guard 2>&1); rc=$?
if ((rc == 1)) && [[ "$out" == *"tmux-health ERROR socket=$SOCK"*"exit 1: protocol version mismatch"* ]]; then
  pass "9. unexpected probe failure: ERROR with its message, exit 1"
else
  fail "9. error state (rc=$rc out=$out)"
fi

# ---- 10. timeout out of range ------------------------------------------------
np=$(wc -l <"$PROBES")
out=$(TMUX_HEALTH_TIMEOUT=9 guard 2>&1); rc=$?
if ((rc == 2)) && [[ "$out" == *"TMUX_HEALTH_TIMEOUT must be 1..4"* && $(wc -l <"$PROBES") == "$np" ]]; then
  pass "10. TMUX_HEALTH_TIMEOUT=9 refused (exit 2), no probe"
else
  fail "10. timeout range (rc=$rc out=$out)"
fi

# ---- 11. through ./run -------------------------------------------------------
o1=$(cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_fleet_tmux_health_guard 2>&1); r1=$?
o2=$(cd "$UTL_ROOT" && DRY_RUN=1 ./run -a do_tmux_health_guard 2>&1); r2=$?
if ((r1 == 0 && r2 == 0)) && [[ "$o1" == *"tmux-health OK socket=$SOCK"* && "$o2" == *"tmux-health OK socket=$SOCK"* ]]; then
  pass "11. ./run -a do_fleet_tmux_health_guard and do_tmux_health_guard both run the guard"
else
  fail "11. ./run (r1=$r1 r2=$r2 o1=$(tail -3 <<<"$o1") o2=$(tail -3 <<<"$o2"))"
fi

# ---- 12. failed send writes no stamp ------------------------------------------
srv kill-server >/dev/null 2>&1; SRV_PID=""
rm -f "$STAMP"
out=$(DRY_RUN=0 TMUX_HEALTH_SEND_CMD="$BIN/send-fail" guard 2>&1); rc=$?
if ((rc == 1)) && [[ ! -f "$STAMP" && "$out" == *"the note to orchestrator failed"* ]]; then
  pass "12. failed send: logged, no stamp written"
else
  fail "12. failed send (rc=$rc out=$out)"
fi

# ---- 13. default sender, repo-relative, under the temp dir ---------------------
FAKE="$T/repo/csi-spl-utl"
mkdir -p "$FAKE" "$T/repo/csi-spl-orc/src/bash/features/spawn-agents/scripts"
cat >"$T/repo/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" <<EOF
#!/bin/bash
printf 'SENTINEL %s\n' "\$*" >>"$SENTINEL_LOG"
EOF
rm -f "$STAMP"
out=$(DRY_RUN=0 PROJ_PATH="$FAKE" TMUX_HEALTH_SEND_CMD="" guard 2>&1); rc=$?
if ((rc == 1)) && grep -q -- "--from tmux-health-guard@$(hostname -s) --to orchestrator --kind note --task tmux-health --no-poke" "$SENTINEL_LOG"; then
  pass "13. no TMUX_HEALTH_SEND_CMD: repo-relative spool-send.sh used, from tmux-health-guard@<box>"
else
  fail "13. default sender (rc=$rc sentinel=$(cat "$SENTINEL_LOG") out=$out)"
fi

# ---- 14. socket resolution ---------------------------------------------------
start_srv
o1=$(DRY_RUN=1 TMUX_HEALTH_SOCKET="" SPOOL_TMUX_SOCKET="$SOCK" guard 2>&1); r1=$?
o2=$(DRY_RUN=1 TMUX_HEALTH_SOCKET="" SPOOL_TMUX_SOCKET="" guard 2>&1); r2=$?
if ((r1 == 0 && r2 == 1)) && [[ "$o1" == *"tmux-health OK socket=$SOCK "* ]] \
   && [[ "$o2" == *"tmux-health DOWN socket=$T/tt/tmux-$(id -u)/default "* ]]; then
  pass "14. socket: SPOOL_TMUX_SOCKET (the fleet's) when set, else \$TMUX_TMPDIR/tmux-<uid>/default"
else
  fail "14. socket resolution (r1=$r1 r2=$r2 o1=$o1 o2=$o2)"
fi

# ---- 15. LIVE GUARD ----------------------------------------------------------
bad_probe=$(grep -v -- "-S $T/" "$PROBES" || true)
if [[ -s "$PROBES" && -z "$bad_probe" && ! -s "$LIVE_LOG" ]]; then
  pass "15. LIVE GUARD: every probe used a socket under the temp dir; no live spool call"
else
  fail "15. LIVE GUARD (probes outside temp: $bad_probe; live calls: $(cat "$LIVE_LOG"))"
fi

echo "=========================================="
echo "tmux-health-guard: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
