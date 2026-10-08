#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the id lock of spec 102 section 4.2 (spl_agent_id_lock in
#          spl-rotate-lib.func.sh) and the actors that take it, in a sandbox:
#          a throwaway spool root, a fake /proc, a private tmux server for the
#          reaper. The live spool root and the box tmux are never touched
#          (SPOOL_TEST=1). Each case has its control: one input flipped.
#   1. two actors on ONE id at once: exactly one runs, the other exits 4; one
#      IDLOCK REFUSED line in rotate.log, under a run id of its own.
#      Control: the same two actors on two different ids both run.
#   2. the lock lives as long as the actor: a child the actor leaves behind
#      (a tmux server started by an actor inherits its fds) does not keep it;
#      the same shell and its subshells take it again (0).
#      Control: while the actor lives, a second actor is refused.
#   3. the real actors refuse a held id with exit 4 before acting: the lane
#      restart, the takeover, the orch rotation, the dispatch heal.
#      Control: the same call on an id nobody holds gets past the lock.
#   4. spl_wd_rotating sees a lane restart in rotate.log while it runs, and an
#      IDLOCK REFUSED line by another actor does not end it.
#      Control: a lane restart of another id is not seen for this one.
#   5. the reaper skips a held-out id and an id whose lock is held.
#      Control: a third id, equally dead, is planned / retired.
#   6. the dispatch rotation holds an id lock only around that id's own swap:
#      while the master phase swaps c-002 (its spawn in flight), the restart's
#      lock call on c-003 is NOT refused (2026-10-07: 12 IDLOCK REFUSED
#      of rs-c-003 during 20261007T1715Z-master), and is again once the run
#      ends. Control: the same call on c-002 is refused meanwhile.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
export SPOOL_TEST=1
unset TMUX TMUX_PANE SPOOL_AGENT_ID SPOOL_BOX_ENV SPOOL_TMUX_SOCKET
T=$(mktemp -d)
cleanup() {
  tmux -S "$T/tmux.sock" kill-server 2>/dev/null || true
  [[ -s "$T/orphan.pid" ]] && kill "$(cat "$T/orphan.pid")" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
S="$T/spool"; D="$S/dispatch"
case "$S" in /var/spool-hub*) echo "FAIL: refusing a live spool root"; exit 1 ;; esac
mkdir -p "$T/bin" "$T/proc" "$D" "$S/c-900/inbox" "$S/c-001/inbox"
echo "100000.00 0.00" >"$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
printf 'LEASE_ORCH=c-001\nLEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\n' >"$D/lease.conf"
export T PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_DESK_BOX=box-desk SPOOL_BOX_TAG=box \
  LEASE_PROC_ROOT="$T/proc" ROTATE_TMUX="$T/bin/none" ROTATE_RUN="$T/bin/none" ROTATE_SEND="$T/bin/none" ROTATE_AI="$T/bin/none" \
  ROTATE_KILL="$T/bin/none" WD_PS_CMD="$T/bin/none" WD_SEND="$T/bin/none" ROTATE_BOOT_GRACE=0 SPOOL_BIN="$T/bin/none"
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/none"

# an actor as ./run runs one (set -E, an ERR trap that ends it): it takes the
# id lock and, holding it, "runs" (a line in ran.<id>) for HOLD seconds;
# ORPHAN=1 leaves a child behind that outlives it, REENTER=1 takes it again
cat >"$T/bin/actor" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-rotate-lib.func.sh"
id="$1" name="$2" hold="${3:-2}" rc=0
spl_agent_id_lock "$id" "$name" "$(date -u +%Y%m%dT%H%M%SZ)-$name-$id" || rc=$?
if (( rc )); then echo "REFUSED $name rc=$rc: $SPL_ID_LOCK_WHY"; exit "$rc"; fi
echo "$name" >>"$T/ran.$id"
if [[ -n "${REENTER:-}" ]]; then
  spl_agent_id_lock "$id" "$name-again" || { echo "REENTER failed"; exit 7; }
  ( spl_agent_id_lock "$id" "$name-sub" ) || { echo "REENTER subshell failed"; exit 7; }
  echo "REENTER ok"
fi
[[ -n "${ORPHAN:-}" ]] && { sleep 30 </dev/null >/dev/null 2>&1 & echo $! >"$T/orphan.pid"; }
exec sleep "$hold"
EOF
# a real action, as ./run runs it
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
for f in "$PROJ_PATH"/src/bash/run/spl-{rotate-lib,dispatch-lease,watchdog,peer-restart,wd-takeover,lane-restart,orch-rotate,dispatch-rotate}.func.sh; do source "$f"; done
"$1" || exit $?
EOF
chmod +x "$T/bin/"*
reset() { rm -f "$T"/ran.* "$D/rotate.log"; }
# holding <root> <id> <name>: wait (up to 30 s) until <name> holds the id. A
# holder lives until it is killed, never for a fixed time: on a starved runner
# (gate 10 run 37793965167, c-551) a 6 s or 8 s hold ran out mid-assertion
holding() { local _; for _ in $(seq 300); do grep -q "^$3 " "$1/$2/lifetime/restart.holder" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
lines() { grep -c . "$1" 2>/dev/null || true; }

# --- 1. two actors on one id ------------------------------------------------------
reset
"$T/bin/actor" c-901 A 600 >"$T/oA" 2>&1 & pa=$!
"$T/bin/actor" c-901 B 600 >"$T/oB" 2>&1 & pb=$!
# the refused one exits; the one that runs holds until it is killed
wait -n "$pa" "$pb"; rcs=$?
kill "$pa" "$pb" 2>/dev/null; wait "$pa" 2>/dev/null; wait "$pb" 2>/dev/null
[[ "$rcs" == 4 && "$(lines "$T/ran.c-901")" == 1 ]] && grep -q 'REFUSED [AB] rc=4: the id lock of c-901 is held by [AB] ' "$T/oA" "$T/oB" &&
  pass "1. two actors on c-901 at once: exactly one runs, the other exits 4" || fail "1. rcs=$rcs ran=$(cat "$T/ran.c-901" 2>/dev/null) $(cat "$T/oA" "$T/oB")"
[[ "$(grep -c ' IDLOCK REFUSED c-901: ' "$D/rotate.log" 2>/dev/null)" == 1 ]] &&
  grep -qE '^[0-9TZ:-]+ [0-9]{8}T[0-9]{6}Z-idlock IDLOCK REFUSED c-901: [AB] ' "$D/rotate.log" &&
  pass "1. one IDLOCK REFUSED line in rotate.log, run id <ts>-idlock" || fail "1. rotate.log: $(cat "$D/rotate.log" 2>/dev/null)"
grep -qE '^[AB] [0-9]{8}T[0-9]{6}Z-[AB]-c-901 pid [0-9]+ since ' "$S/c-901/lifetime/restart.holder" &&
  pass "1. lifetime/restart.holder names the actor that ran" || fail "1. holder: $(cat "$S/c-901/lifetime/restart.holder" 2>/dev/null)"
reset
"$T/bin/actor" c-901 A 2 >"$T/oA" 2>&1 & pa=$!
"$T/bin/actor" c-902 B 2 >"$T/oB" 2>&1 & pb=$!
wait "$pa"; ra=$?; wait "$pb"; rb=$?
[[ "$ra" == 0 && "$rb" == 0 && "$(lines "$T/ran.c-901")" == 1 && "$(lines "$T/ran.c-902")" == 1 && ! -s "$D/rotate.log" ]] &&
  pass "1. control: the same actors on c-901 and c-902 both run" || fail "1. control ra=$ra rb=$rb $(cat "$T/oA" "$T/oB")"

# --- 2. the lock lives as long as the actor ---------------------------------------------
reset
ORPHAN=1 REENTER=1 "$T/bin/actor" c-903 A 1 >"$T/oA" 2>&1; ra=$?
[[ "$ra" == 0 ]] && grep -q 'REENTER ok' "$T/oA" && pass "2. the same shell and a subshell take the held lock again" || fail "2. reenter ra=$ra $(cat "$T/oA")"
"$T/bin/actor" c-903 B 0 >"$T/oB" 2>&1; rb=$?
kill -0 "$(cat "$T/orphan.pid")" 2>/dev/null && [[ "$rb" == 0 && "$(lines "$T/ran.c-903")" == 2 ]] &&
  pass "2. the actor ended: its id is free though a child it left behind still runs" || fail "2. orphan rb=$rb $(cat "$T/oB")"
kill "$(cat "$T/orphan.pid")" 2>/dev/null; rm -f "$T/orphan.pid"
"$T/bin/actor" c-903 A 600 >"$T/oA" 2>&1 & pa=$!
holding "$S" c-903 A
"$T/bin/actor" c-903 B 0 >"$T/oB" 2>&1; rb=$?
kill "$pa" 2>/dev/null; wait "$pa" 2>/dev/null
[[ "$rb" == 4 ]] && grep -q 'held by A ' "$T/oB" && pass "2. control: while the actor lives, a second one is refused" || fail "2. control rb=$rb $(cat "$T/oB")"

# --- 3. the real actors refuse a held id ---------------------------------------------
# hold ID by a stand-in actor until free() kills it, run the action, check
held() {  # ID
  "$T/bin/actor" "$1" X 600 >/dev/null 2>&1 & hp=$!
  holding "$S" "$1" X
}
free() { kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null; sleep 0.5; }
act() { env "${@:2}" "$T/bin/act" "$1"; }

reset; held c-900
act do_spl_lane_restart ID=c-900 DRY_RUN=1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 4 ]] && grep -q 'GATE REFUSED id lock (spec 102 4.2): the id lock of c-900 is held by X ' "$T/o" && ! grep -qE ' GATE (OK|FAIL) ' "$T/o" &&
  [[ -z "$(awk '$2 ~ /-c-900$/' "$D/rotate.log" 2>/dev/null)" ]] &&
  pass "3. lane restart on a held id: exit 4 before its gate, no line under its run id" || fail "3. lane rc=$rc $(cat "$T/o")"
act do_spl_lane_restart ID=c-904 DRY_RUN=1 >"$T/o" 2>&1; rc=$?
grep -q 'GATE FAIL no live claude carries c-904' "$T/o" && ! grep -q 'id lock' "$T/o" &&
  pass "3. control: lane restart on a free id gets past the lock (to its gate)" || fail "3. lane control rc=$rc $(cat "$T/o")"
act do_spl_wd_takeover ID=c-900 REASON=S3 DRY_RUN=1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 4 ]] && grep -q 'REFUSED c-900: id lock (spec 102 4.2): the id lock of c-900 is held by X ' "$T/o" &&
  pass "3. takeover on a held id: exit 4" || fail "3. takeover rc=$rc $(cat "$T/o")"
act do_spl_wd_takeover ID=c-904 REASON=S3 DRY_RUN=1 >"$T/o" 2>&1; rc=$?
! grep -q 'id lock' "$T/o" && ! grep -q ERRTRAP "$T/o" && pass "3. control: takeover on a free id gets past the lock (rc=$rc)" || fail "3. takeover control rc=$rc $(cat "$T/o")"
free

held c-001
act do_spl_orch_rotate DRY_RUN=1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 4 ]] && grep -q 'GATE SKIP id lock: the id lock of c-001 is held by X ' "$T/o" &&
  pass "3. orch rotation of a held orchestrator: exit 4" || fail "3. orch rc=$rc $(cat "$T/o")"
free
act do_spl_orch_rotate DRY_RUN=1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'id lock' "$T/o" && grep -q 'GATE SKIP' "$T/o" &&
  pass "3. control: the orch rotation with its id free gets past the lock" || fail "3. orch control rc=$rc $(cat "$T/o")"

held c-003
act do_spl_dispatch_rotate ROTATE_CMD=heal DRY_RUN=1 ROTATE_HEAL_CONFIRM=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 4 ]] && grep -q 'HEAL SKIP id lock: the id lock of c-003 is held by X ' "$T/o" &&
  pass "3. dispatch heal with the failover held: exit 4" || fail "3. heal rc=$rc $(cat "$T/o")"
free
act do_spl_dispatch_rotate ROTATE_CMD=heal DRY_RUN=1 ROTATE_HEAL_CONFIRM=0 >"$T/o" 2>&1; rc=$?
! grep -q 'id lock' "$T/o" && ! grep -q ERRTRAP "$T/o" &&
  pass "3. control: the dispatch heal with both ids free gets past the lock (rc=$rc)" || fail "3. heal control rc=$rc $(cat "$T/o")"

# --- 4. spl_wd_rotating sees a lane restart ----------------------------------------------
reset
cat >"$T/bin/rot" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
for f in "$PROJ_PATH"/src/bash/run/spl-{rotate-lib,dispatch-lease,watchdog,lane-restart}.func.sh; do source "$f"; done
spl_rotate_conf >/dev/null || { echo "conf failed"; exit 1; }
LANE_RESTART_LOG="$LEASE_DIR/lane-restart.log"
case "$1" in
  log) DRY_RUN=0 spl_lane_restart_log "$2" "$3" "$4" "${5:-}" >/dev/null ;;
  ask) spl_wd_rotating "$2" "$(date +%s)" ;;
esac
EOF
chmod +x "$T/bin/rot"
rid="$(date -u +%Y%m%dT%H%M%SZ)-c-900"
"$T/bin/rot" log "$rid" GATE OK "c-900 pid 1001"; "$T/bin/rot" log "$rid" SPAWN OK "self-restart: detached"
out="$("$T/bin/rot" ask c-900)"
[[ "$out" == "$rid SPAWN OK" ]] && grep -q " $rid SPAWN OK " "$D/lane-restart.log" &&
  pass "4. a lane restart in flight is in rotate.log: spl_wd_rotating sees it" || fail "4. rotating: '$out' $(cat "$D/rotate.log")"
held c-900; act do_spl_wd_takeover ID=c-900 REASON=S3 DRY_RUN=1 >/dev/null 2>&1; free
out="$("$T/bin/rot" ask c-900)"
grep -q 'IDLOCK REFUSED c-900' "$D/rotate.log" && [[ "$out" == "$rid SPAWN OK" ]] &&
  pass "4. another actor's IDLOCK REFUSED line does not end it" || fail "4. after refusal: '$out' $(cat "$D/rotate.log")"
out="$("$T/bin/rot" ask c-905)"
[[ -z "$out" ]] && pass "4. control: no lane restart of c-905 is seen" || fail "4. control: '$out'"
"$T/bin/rot" log "$rid" DONE OK "c-900 restarted"
out="$("$T/bin/rot" ask c-900)"
[[ -z "$out" ]] && pass "4. its DONE line ends it" || fail "4. done: '$out'"

# --- 5. the reaper ---------------------------------------------------------------------
R="$T/reap"; mkdir -p "$R/agents" "$R/dispatch/wd"
tmux -S "$T/tmux.sock" -f /dev/null new-session -d -s t -n home 'sleep 600'
rec() { python3 -c 'import json,sys; json.dump({"v":1,"id":sys.argv[1],"kind":"claude","alive":False,"pid":None,"updated_at":sys.argv[2]}, open(sys.argv[3],"w"), indent=1, sort_keys=True)' "$1" "$2" "$R/agents/$1.json"; }
for id in c-904 c-908 c-909; do mkdir -p "$R/$id/inbox"; printf '%s\tclaude\t%%9\t/x\t20261001T080000Z\n' "$id" >>"$R/registry.tsv"; rec "$id" 2026-10-02T04:00:00Z; done
date +%s >"$R/dispatch/wd/c-908.heldout"
reap() { env SPOOL_ROOT="$R" SPOOL_TMUX_SOCKET="$T/tmux.sock" SPOOL_NOW=2026-10-02T12:00:00Z RETIRE_LANE=0 SPOOL_ID_REAP_H=6 bash "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/agent-id-reap.sh" "$@" 2>&1; }
SPOOL_ROOT="$R" "$T/bin/actor" c-909 X 600 >/dev/null 2>&1 & hp=$!
holding "$R" c-909 X
out="$(reap)"
grep -q 'SKIP c-908: dead 8 h, but the watchdog holds it out' <<<"$out" && grep -q 'SKIP c-909: dead 8 h, but the id lock of c-909 is held by X ' <<<"$out" &&
  grep -q 'PLAN c-904: dead 8 h' <<<"$out" &&
  pass "5. dry run: held out and locked ids skipped; control c-904 planned" || fail "5. dry: $out"
out="$(reap --apply)"
[[ -d "$R/c-908/inbox" && -d "$R/c-909/inbox" && ! -e "$R/c-904" ]] && grep -q 'REAP c-904: dead 8 h' <<<"$out" &&
  grep -qE '[0-9]{8}T[0-9]{6}Z-reap-c-904 DONE OK retired by the reaper' "$R/dispatch/rotate.log" &&
  pass "5. apply: c-908 and c-909 kept; control c-904 retired and logged to rotate.log" || fail "5. apply: $out $(cat "$R/dispatch/rotate.log" 2>/dev/null)"
kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null

# --- 6. the dispatch rotation locks one id at a time --------------------------------
reset
mkproc() {  # PID ID
  local d="$T/proc/$1"; mkdir -p "$d"; echo claude >"$d/comm"
  printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$d/environ"
  echo "$1 (claude) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 100" >"$d/stat"
  printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" >"$d/status"
}
mkproc 3002 c-002; mkproc 3003 c-003
mkdir -p "$D/briefs"; echo "brief of c-002" >"$D/briefs/brief-dispatcher-c-002.md"
echo "c-002 $(date +%s)" >"$D/lease"
# tmux: c-002 in %72, c-003 in %73, both idle at an empty input box
cat >"$T/bin/tmux6" <<'EOF'
#!/usr/bin/env bash
cmd="$1"; shift; tgt=""
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; *) shift ;; esac; done
case "$cmd" in
  list-panes) printf '3002 %%72\n3003 %%73\n' ;;
  display-message) echo "${tgt}" ;;
  capture-pane) printf 'done\n────────\n❯ \n────────\n' ;;
  *) exit 0 ;;
esac
EOF
# the spawn of the new c-002 hangs until $T/go, then prints no pane (FAIL SPAWN)
cat >"$T/bin/spawn6" <<'EOF'
#!/usr/bin/env bash
touch "$T/spawning"
for _ in $(seq 200); do [ -e "$T/go" ] && break; sleep 0.1; done
echo "spawn-window: no pane"; exit 4
EOF
chmod +x "$T/bin/tmux6" "$T/bin/spawn6"
act do_spl_dispatch_rotate DRY_RUN=0 ROTATE_FORCE=1 ROTATE_TMUX="$T/bin/tmux6" ROTATE_SPAWN="$T/bin/spawn6" ROTATE_POLL=1 ROTATE_IDLE_SEC=0 \
  ROTATE_PROMOTE_WAIT=5 ROTATE_HANDOFF_DIR="$T/handoff" ROTATE_HOLD_DIR="$T/hold" ROTATE_SRC_TIMEOUT=5 >"$T/o6" 2>&1 & rp=$!
for _ in $(seq 200); do [ -e "$T/spawning" ] && break; sleep 0.1; done
"$T/bin/actor" c-003 do_spl_agent_restart 0 >"$T/oF" 2>&1; rf=$?
"$T/bin/actor" c-002 do_spl_agent_restart 0 >"$T/oM" 2>&1; rm_=$?
touch "$T/go"; wait "$rp"
[[ -e "$T/spawning" && "$rf" == 0 ]] && grep -q ' SPAWN FAIL \| FAIL FAIL SPAWN' "$T/o6" &&
  pass "6. during the master's swap a restart's lock call on c-003 runs" || fail "6. rf=$rf $(cat "$T/oF") $(tail -5 "$T/o6")"
[[ "$rm_" == 4 ]] && grep -q 'held by do_spl_dispatch_rotate [0-9TZ]*-master' "$T/oM" &&
  pass "6. control: the same call on c-002, mid-swap, is refused (exit 4)" || fail "6. control rm=$rm_ $(cat "$T/oM")"
"$T/bin/actor" c-002 do_spl_agent_restart 0 >"$T/oM" 2>&1; rm_=$?
[[ "$rm_" == 0 ]] && pass "6. the run over, c-002 is free again" || fail "6. after: rm=$rm_ $(cat "$T/oM")"

echo "agent-id-lock: $( ((fails)) && echo "$fails failure(s)" || echo "all passed")"
exit $(( fails > 0 ))
