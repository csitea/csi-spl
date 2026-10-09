#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the one restart path of spec 102 section 4.1 (T008):
#          do_spl_agent_restart in a sandbox, through the ROTATE seams
#          (ROTATE_SPAWN, ROTATE_TMUX, ROTATE_KILL, ROTATE_AI, ROTATE_RUN),
#          WD_PS_CMD, WD_SEND and LEASE_PROC_ROOT. Processes are a ps stub +
#          a fake /proc, tmux a stub keeping panes in a file, spawn-window.sh,
#          ./run, spool-send.sh, kill and the identity map stubs that log, the
#          clock LEASE_NOW; a lane's worktree is a real clone of a bare
#          remote (the wip ref is real). It runs under ./run's set -E + ERR trap.
#   1. a lane rebirth: one process, same id and worktree, the wip ref pushed
#      before the spawn, the rebirth marker consumed, session.json #2, RS-*
#      phases ending DONE OK, ONE REBORN line to the orchestrator, no blocker
#   2. control: a crash right after a rebirth is S3, not rebirth (a blocker,
#      no REBORN); CAUSE=rebirth then finds no rebirth hit (exit 3)
#   3. a lane with a live process (S4): stop first, TERM before the spawn
#   4. a seat: the new session acks before the old one retires; control: no
#      ack -> the old session keeps the seat, the new one is gone, exit 1
#   5. 4 lanes restart at once on 4 slots; control: a 5th at the same time
#      finds no free slot (exit 4)
#   6. limits: the 4th restart in an hour -> held out, ONE admin alert, still
#      held 2 h later; control: the 3rd in an hour runs
#   7. a failed lane spawn leaves no process, keeps the rebirth marker, clears
#      the watchdog's episode flag, is counted; the next try runs
#   8. a refusal by a guard (rotate.hold, the id lock) is not a restart done:
#      exit 4, the episode flag cleared, nothing counted; control: the guard
#      gone, it runs (c-101's report, 2026-10-06 and 10-07)
#   9. done and retired ids are never restarted (exit 3); control: a reused
#      id with a live registry row runs; a handoff that cannot be written
#      fails the restart (RS-HANDOFF FAIL, never OK) and spawns nothing
#  10. a hard end: a live session past HARD_END is restarted even with a
#      human client active (R3); control: a younger session -> exit 3
#  11. a dry run touches nothing
#  12. the human guard keys on the agent's window (c-491): a rebirth with the
#      owner active in another window of the same session runs; control: in
#      THAT window it is refused, nothing spawned, the marker kept; the hard
#      end with the owner in that window still runs (R3)
#  13. the new session parked on a "Settings Warning" dialog: RS-SPAWN FAIL
#      at once naming it, the new process signalled (nothing typed into the
#      dialog), ALERT = ask + owner DM, the alert recorded for recovery.
#      Control: case 1, the same rebirth on a plain screen, runs to DONE OK
#  14. an id with an open FAIL alert restarted to DONE OK: its ask closed and
#      ONE "recovered at <ts> by do_spl_agent_restart <rid> (<cause>), now pid
#      <pid>" line to the owner on that ask's thread. Control: no open alert,
#      no ask close and no line
#  15. RS-REPORT with the relay down (sat reboot drill 2026-10-08, n=3: the
#      orch lease on another box, no desk sidecar yet, spool-send exit 13):
#      the REBORN line is journaled (RS-REPORT QUEUED), the resend loop
#      delivers it once the relay is back (RS-REPORT OK, queue empty); a
#      crash blocker journaled with the loop off is sent, oldest first, by
#      the next restart's report. Control: ARS_REPORT_QUEUE=0 (the old code)
#      -> "RS-REPORT FAIL the REBORN line was not delivered", nothing kept
#  16. an m- (mistral / vibe) lane idle on its open plan after a Stop
#      (c-001@sat 2026-10-09, m-617 / m-618, n=2): the m- id passes, S1 hits,
#      the old pid stops first, a mistral session spawns. Controls: the plan
#      complete (exit 3), an x- id (FATAL)
#  17. a lane restored in flight continues its brief (owner rule A, t1
#      3192c200; c-539@sat 2026-10-09 read its handoff and stopped idle):
#      its seed carries "4. Then CONTINUE the brief", a brief.md nested four
#      seeds deep is cut back to the real brief (one seed header, the brief
#      path in section A). Controls: an unanswered blocker -> "4. Then WAIT",
#      a final result -> "4. Then FINISH", neither tells it to continue; an
#      answered blocker -> CONTINUE again; a message newer than the result
#      (m-682 2026-10-09: a reject 27 s after it) -> "4. Then ACT" naming
#      it, no FINISH; a restart ACK newer than the result still FINISHes
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T0=1800000000   # 2027-01-15T08:00:00Z
iso() { date -u -d "@$1" +%FT%TZ; }
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$T/hold" "$T/mem"
echo "100000.00 0.00" > "$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"

# --- stubs --------------------------------------------------------------------
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
# tmux: panes "$T/tmux/panes" as "<pane>\t<pane_pid>\t<session>\t<window>\t<fg>", under a lock (parallel runs)
cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exec 9>>"$T/tmux/lock"; flock 9
P="$T/tmux/panes"; L="$T/tmux/log"; cmd="$1"; shift; tgt="" fmt="" a=""
esc=0
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -F) fmt="$2"; shift 2 ;; -e) esc=1; shift ;; -a|-p|-J|-l) shift ;; -S) shift 2 ;; *) a="$1"; shift ;; esac; done
field() { awk -F'\t' -v p="$tgt" -v f="$1" '$1 == p {print $f}' "$P"; }
case "$cmd" in
  list-panes) if [ "$fmt" = '#{pane_pid} #{pane_id}' ]; then awk -F'\t' '{print $2" "$1}' "$P"; else cat "$P"; fi ;;
  list-clients) cat "$T/tmux/clients" 2>/dev/null ;;
  display-message) grep -q "^$tgt	" "$P" || exit 1
    case "$a" in *window_name*) field 4 ;; *session_id*) field 3 ;; *) echo "$tgt" ;; esac ;;
  capture-pane) grep -q "^$tgt	" "$P" || exit 1
    if [ -f "$T/tmux/screen.$tgt" ]; then cat "$T/tmux/screen.$tgt"; else printf 'working on the brief\n'; fi
    if [ "$esc" = 1 ] && [ ! -f "$T/tmux/screen.$tgt" ]; then printf '────────\n❯ \n────────\n'; fi ;;
  rename-window) awk -F'\t' -v OFS='\t' -v p="$tgt" -v n="$a" '$1 == p {$4 = n} {print}' "$P" > "$P.new.$$" && mv "$P.new.$$" "$P"
    echo "rename $tgt $a" >> "$L" ;;
  send-keys) echo "keys $tgt $a" >> "$L" ;;
  kill-window) awk -F'\t' -v p="$tgt" '$1 != p' "$P" > "$P.new.$$" && mv "$P.new.$$" "$P"; echo "kill $tgt" >> "$L" ;;
esac
EOF
# spawn-window.sh <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>"; a seat
# acks on task restart-<rid> (the rid is in the seed's first line) unless noack
cat > "$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
id="$2"; n="${id##*-}"; pid=$(( 3000 + 10#$n )); pane="%3$n"
br="$(git -C "$3" symbolic-ref -q --short HEAD 2>/dev/null)"
wip="$( [ -n "$br" ] && git -C "$3" ls-remote origin "refs/heads/wip/$br" 2>/dev/null | cut -c1-12)"
echo "spawn $1 $2 wd=$3 SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-} seed=$4 wip=${wip:-none}" >> "$T/spawn.log"
echo "spawn $2" >> "$T/order.log"
sleep "${SPAWN_SLEEP:-0}"
[ -n "${SPAWN_GATE:-}" ] && for _ in $(seq 1200); do [ -e "$SPAWN_GATE" ] && break; sleep 0.1; done
mode="$(cat "$T/spawn.mode.$id" 2>/dev/null || echo ok)"
( exec 9>>"$T/tmux/lock"; flock 9; printf '%s\t%s\t$1\t%s@box1\tclaude\n' "$pane" "$pid" "$id" >> "$T/tmux/panes" )
if [ "$mode" != nostart ]; then mkdir -p "$T/proc/$pid"; echo "$1" > "$T/proc/$pid/comm"
  printf 'SPOOL_AGENT_ID=%s\0' "$id" > "$T/proc/$pid/environ"; printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" > "$T/proc/$pid/status"; fi
if [ "$mode" = ok ] && grep -q 'acknowledge the restart' "$4"; then
  rid="$(sed -n '1s/.*(\(.*\))$/\1/p' "$4")"
  jq -n --arg id "$id" --arg t "restart-$rid" '{v: 1, kind: "result", from: $id, task_id: $t, msg_id: "m1"}' > "$S/$id/outbox/ack.json"
  echo "ack $id" >> "$T/order.log"
fi
echo "$id $pane"
EOF
cat > "$T/bin/run" <<'EOF'
#!/usr/bin/env bash
echo "$2 PEER_SEAT=${PEER_SEAT:-} ASK_KIND=${ASK_KIND:-} DESK_TO=${DESK_TO:-}" >> "$T/run.log"
echo "$2 ASK_ID=${ASK_ID:-} DESK_TASK=${DESK_TASK:-} DESK_KIND=${DESK_KIND:-} BODY=${ASK_REASON:-}${DESK_BODY:-}" >> "$T/run2.log"
case "$2" in
  do_spl_asks_open) echo '{"asks":[]}' ;;
  do_spl_ask_put|do_spl_desk_reply|do_spl_peer_poll|do_spl_ask_close) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >> "$T/kill.log"; echo "kill $2" >> "$T/order.log"; rm -rf "$T/proc/$2"
EOF
cat > "$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  adopt) echo "$3" > "$T/ai.$2" ;;
  pane-of) p="$(cat "$T/ai.$2" 2>/dev/null)"; [ -n "$p" ] && [ -d "$T/proc/$p" ] || exit 1
    awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "$T/tmux/panes" ;;
esac
EOF
# send: the relay is down while $T/relay.down exists (spool-send exit 13, nothing sent)
printf '#!/usr/bin/env bash\n[ -e "%s/relay.down" ] && exit 13\necho "send $*" >> "%s/sent"\n' "$T" "$T" > "$T/bin/send"
printf '#!/usr/bin/env bash\ncat "%s/tr.$1" 2>/dev/null\n' "$T" > "$T/bin/tr"
cat > "$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-agent-restart.func.sh"
do_spl_agent_restart || exit $?
EOF
chmod +x "$T/bin/"*

export T S PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc" \
  WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" LEASE_TRANSCRIPT_CMD="$T/bin/tr" \
  ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" ROTATE_KILL="$T/bin/kill" ROTATE_AI="$T/bin/ai" PEER_RUN="$T/bin/run" \
  ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_TERM_WAIT=2 \
  ROTATE_NEW_EXIT_WAIT=1 ROTATE_ACK_TIMEOUT=3 WD_START_WAIT=3 LEASE_NOW="$T0" ROTATE_TRANSCRIPT="$T/old.jsonl" \
  HANDOFF_CAPTURE_CMD="echo working on the brief" WIP_GIT_NAME="FirstName LastName" WIP_GIT_EMAIL="dev@example.com" \
  GIT_CONFIG_GLOBAL=/dev/null
unset SPOOL_AGENT_ID REQ_FROM WD_EVIDENCE CLAUDE_BIN DRY_RUN

git init -q --bare "$T/remote.git"
world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/"*.log "$T/sent" "$T/relay.down" "$T/spawn.mode."* "$T/ai."* "$D" "$S/peer" "$S"/[cgm]-[0-9]* "$S/registry"*
  mkdir -p "$D" "$S/peer"
  printf 'LEASE_ENV=prd\nLEASE_TENANT=t1\nASKS_OWNER=HUM-10\n' > "$D/lease.conf"
  : > "$T/ps"; : > "$T/tmux/panes"; : > "$T/tmux/clients"
  printf '%s\n' '{"type":"user","timestamp":"2027-01-15T06:00:00Z","message":{"content":"Read your full task brief at /briefs/T999.md and implement it."}}' > "$T/old.jsonl"
}
# lane <id> <pane> <pid|-> [comm]: a lane with a real worktree (dirty), its window and maybe its process
lane() {
  local id="$1" pane="$2" pid="$3" comm="${4:-claude}" wt="$T/wt-$1" shellpid
  shellpid=$(( ${pane#%} + 5000 ))
  rm -rf "$wt"; git clone -q "$T/remote.git" "$wt" 2>/dev/null
  git -C "$wt" checkout -q -b "lane-$id"; echo base > "$wt/f.txt"
  git -C "$wt" add f.txt; git -C "$wt" -c user.name=x -c user.email=x@example.com commit -q -m base; echo dirty >> "$wt/f.txt"
  mkdir -p "$S/$id/inbox" "$S/$id/outbox" "$S/$id/lifetime"
  printf '%s\t%s\t%s\t%s\t20270115T0600Z\n' "$id" "$comm" "$pane" "$wt" >> "$S/registry.tsv"
  win "$id" "$pane" "$pid" "$comm"
}
win() {  # win <id> <pane> <pid|-> [comm]
  local id="$1" pane="$2" pid="$3" comm="${4:-claude}" shellpid
  shellpid=$(( ${pane#%} + 5000 ))
  if [[ "$pid" == - ]]; then
    printf '%s\t%s\t$1\t%s@box1\tbash\n' "$pane" "$shellpid" "$id" >> "$T/tmux/panes"
    echo "$shellpid 1 3600 bash" >> "$T/ps"
  else
    printf '%s\t%s\t$1\t%s@box1\t%s\n' "$pane" "$pid" "$id" "$comm" >> "$T/tmux/panes"
    echo "$pid 1 ${AGE:-3600} $comm" >> "$T/ps"
    mkdir -p "$T/proc/$pid"; echo "$comm" > "$T/proc/$pid/comm"
    printf 'SPOOL_AGENT_ID=%s\0' "$id" > "$T/proc/$pid/environ"
    printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" > "$T/proc/$pid/status"
  fi
}
hb() {  # hb <id> <state> <progress age> [jq extra]
  jq -n --arg st "$2" --arg p "$(iso $((T0 - $3)))" \
    "{v: 1, id: \"$1\", state: \$st, event: \"Stop\", ts: \$p, progress_ts: \$p, tool: null, tool_since: null, api_error: null, calls: []} ${4:-}" \
    > "$S/$1/heartbeat.json"
}
reborn() { touch "$S/$1/lifetime/rebirth"; }   # /exit-clean --rebirth ran
crash() {  # crash <id>: the new session (spawned by the stub) died, its pane on a shell
  local n="${1##*-}"; rm -rf "$T/proc/$(( 3000 + 10#$n ))"
  awk -F'\t' -v OFS='\t' -v p="%3$n" '$1 == p {$5 = "bash"} {print}' "$T/tmux/panes" > "$T/tmux/p.new" && mv "$T/tmux/p.new" "$T/tmux/panes"
}
go() { env "$@" "$T/bin/act" > "$T/o" 2>&1; echo $?; }
alive() { [[ -d "$T/proc/$1" ]]; }
nproc() { grep -lx "SPOOL_AGENT_ID=$1" "$T/proc"/[0-9]*/environ 2>/dev/null | wc -l; }
rlog() { grep -c " [0-9]*T[0-9]*Z-rs-$1 $2 " "$D/rotate.log" 2>/dev/null || true; }

# --- 1. a lane rebirth ----------------------------------------------------------
world; lane c-931 %31 -; reborn c-931
rc="$(go ID=c-931 CAUSE=rebirth DRY_RUN=0)"
bad=""
[[ "$rc" == 0 ]] || bad+=" rc=$rc"
[[ "$(nproc c-931)" == 1 ]] && alive 3931 || bad+=" processes=$(nproc c-931)"
grep -q "^spawn claude c-931 wd=$T/wt-c-931 SPAWN_REUSE_ID=1 " "$T/spawn.log" || bad+=" spawn:$(cat "$T/spawn.log" 2>/dev/null)"
grep -q ' wip=[0-9a-f]\{12\}$' "$T/spawn.log" || bad+=" wip-not-pushed-before-spawn"
[[ ! -e "$S/c-931/lifetime/rebirth" && -e "$S/c-931/lifetime/last-rebirth" ]] || bad+=" marker-not-consumed"
[[ "$(jq -r '"\(.n) \(.rebirths) \(.restarts) \(.cause)"' "$S/c-931/lifetime/session.json" 2>/dev/null)" == "1 1 1 rebirth" ]] || bad+=" session.json=$(cat "$S/c-931/lifetime/session.json" 2>/dev/null)"
for p in RS-GATE RS-RETIRE RS-CLEANUP RS-WIP RS-HANDOFF RS-SEED RS-SPAWN RS-REPORT DONE; do [[ "$(rlog c-931 $p)" -ge 1 ]] || bad+=" no-$p"; done
[[ "$(tail -1 "$D/rotate.log" | cut -d' ' -f3,4)" == "DONE OK" ]] || bad+=" last=$(tail -1 "$D/rotate.log")"
[[ "$(grep -c -- '--to orchestrator --kind note --task restart-c-931 --no-ask --body REBORN c-931@box1 #1 cause=rebirth handoff=' "$T/sent")" == 1 ]] || bad+=" reborn:$(cat "$T/sent" 2>/dev/null)"
grep -q -- '--kind blocker' "$T/sent" && bad+=" blocker-sent"
grep -q '^## 1. header' "$S/c-931/handoff/"*-rs-c-931.md && grep -q 'brief at /briefs/T999.md' "$S/c-931/handoff/"*-rs-c-931.seed.md || bad+=" handoff/seed"
grep -q ERRTRAP "$T/o" && bad+=" errtrap"
[[ -z "$bad" ]] && pass "1. a lane rebirth: one process, same id + worktree, wip pushed before the spawn, marker consumed, RS-* to DONE OK, ONE REBORN line" ||
  fail "1. rebirth:$bad -- $(tail -5 "$T/o")"

# --- 2. a crash right after a rebirth is S3 ---------------------------------------------
crash c-931; rm -f "$T/sent"
rc="$(go ID=c-931 CAUSE=rebirth DRY_RUN=0 LEASE_NOW=$((T0 + 600)))"
[[ "$rc" == 3 ]] && grep -q 'no rebirth hit' "$T/o" && pass "2. control: after a rebirth no rebirth hit is left (CAUSE=rebirth -> exit 3)" || fail "2. rebirth again rc=$rc: $(cat "$T/o")"
rc="$(go ID=c-931 CAUSE=S3 DRY_RUN=0 LEASE_NOW=$((T0 + 600)))"
[[ "$rc" == 0 ]] && grep -q -- '--kind blocker --task wd-c-931-' "$T/sent" && ! grep -q 'REBORN' "$T/sent" &&
  [[ "$(jq -r .cause "$S/c-931/lifetime/session.json")" == S3 ]] &&
  pass "2. a crash right after a rebirth is reported as S3 (a blocker), not rebirth" || fail "2. crash rc=$rc: $(cat "$T/sent" 2>/dev/null) $(tail -3 "$T/o")"

# --- 3. a live lane (S4): stop first -------------------------------------------------------
world; lane c-932 %32 4932; hb c-932 in-tool 1000 '| .tool = "Bash" | .tool_since = .progress_ts'
rc="$(go ID=c-932 CAUSE=S4 DRY_RUN=0 WD_EVIDENCE="tool=Bash")"
[[ "$rc" == 0 ]] && ! alive 4932 && alive 3932 && [[ "$(head -2 "$T/order.log" | tr '\n' ' ')" == "kill 4932 spawn c-932 " ]] &&
  pass "3. a live lane: TERM the old pid first, then the spawn" || fail "3. stop first rc=$rc: $(cat "$T/order.log" 2>/dev/null) $(tail -3 "$T/o")"

# --- 4. a seat: start first, ack before retire ---------------------------------------------
world; echo "c-004 claude" > "$S/peer/seats"; lane c-004 %4 4004; hb c-004 in-tool 1000 '| .tool = "Bash" | .tool_since = .progress_ts'
rc="$(go ID=c-004 CAUSE=S4 DRY_RUN=0 WD_EVIDENCE="tool=Bash")"
[[ "$rc" == 0 ]] && ! alive 4004 && alive 3004 && [[ "$(tr '\n' ' ' < "$T/order.log")" == "spawn c-004 ack c-004 kill 4004 " ]] && [[ "$(rlog c-004 RS-ACK)" == 1 ]] &&
  pass "4. a seat: the new session acks before the old one retires" || fail "4. seat rc=$rc: $(cat "$T/order.log" 2>/dev/null) $(tail -4 "$T/o")"
world; echo "c-004 claude" > "$S/peer/seats"; lane c-004 %4 4004; hb c-004 in-tool 1000 '| .tool = "Bash" | .tool_since = .progress_ts'; echo noack > "$T/spawn.mode.c-004"
rc="$(go ID=c-004 CAUSE=S4 DRY_RUN=0 WD_EVIDENCE="tool=Bash")"
[[ "$rc" == 1 ]] && alive 4004 && ! alive 3004 && grep -q 'RS-ACK FAIL' "$D/rotate.log" && ! grep -q '^kill 4004' "$T/order.log" &&
  pass "4. control: no ack -> the old session keeps the seat, the new one is gone (exit 1)" || fail "4. noack rc=$rc: $(cat "$T/order.log") $(tail -4 "$T/o")"

# --- 5. 4 lanes at once on 4 slots ------------------------------------------------------------
world; for n in 41 42 43 44 45; do lane "c-9$n" "%$n" -; reborn "c-9$n"; done
# spawning() <n>: wait (up to 60 s) until <n> of the four reached their spawn.
# The spawns hold their slots on SPAWN_GATE, not for a fixed time: on a starved
# runner (gate 10 run 37793965167, c-551) a 3 s spawn ended before the 5th
# restart began. Each restart writes its own output file (a shared $T/o got
# the 4th restart's lines in o.45)
spawning() { local _; for _ in $(seq 600); do [ "$(grep -c '^spawn c-94[1-4]$' "$T/order.log" 2>/dev/null)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
go1() { local n="$1"; shift; env "$@" "$T/bin/act" > "$T/o.$n" 2>&1; echo $? > "$T/rc.$n"; }
rm -f "$T/gate"
for n in 41 42 43 44; do go1 "$n" ID="c-9$n" CAUSE=rebirth DRY_RUN=0 SPAWN_GATE="$T/gate" & done
spawning 4; touch "$T/gate"; wait
ok=0; for n in 41 42 43 44; do [[ "$(cat "$T/rc.$n")" == 0 ]] && ok=$((ok + 1)); done
slots="$(grep -o 'RS-GATE OK .*; slot [0-9]' "$D/rotate.log" | grep -o 'slot [0-9]' | sort -u | tr '\n' ' ')"
[[ "$ok" == 4 && "$slots" == "slot 1 slot 2 slot 3 slot 4 " ]] && pass "5. 4 lanes restart at once on 4 slots" || fail "5. ok=$ok slots='$slots' $(cat "$T/o.4"*)"
world; for n in 41 42 43 44 45; do lane "c-9$n" "%$n" -; reborn "c-9$n"; done
rm -f "$T/gate"
for n in 41 42 43 44; do go1 "$n" ID="c-9$n" CAUSE=rebirth DRY_RUN=0 RESTART_SLOTS=4 SPAWN_GATE="$T/gate" & done
spawning 4; go1 45 ID=c-945 CAUSE=rebirth DRY_RUN=0 RESTART_SLOTS=4; touch "$T/gate"; wait
r="$(cat "$T"/rc.4[1-5] | sort | tr '\n' ' ')"
[[ "$r" == "0 0 0 0 4 " ]] && grep -q 'no free restart slot' "$T/o.45" && pass "5. control: a 5th at the same time finds no free slot (exit 4)" || fail "5. 5th: $r $(cat "$T/o.45")"

# --- 6. limits ------------------------------------------------------------------------------------
world; lane c-933 %33 -; reborn c-933; printf '%s S3\n' $((T0 - 1200)) $((T0 - 600)) > "$S/c-933/lifetime/restarts"
rc="$(go ID=c-933 CAUSE=rebirth DRY_RUN=0)"
[[ "$rc" == 0 && "$(grep -c . "$S/c-933/lifetime/restarts")" == 3 ]] && pass "6. control: the 3rd restart in an hour runs (counted: 3)" || fail "6. third rc=$rc: $(tail -3 "$T/o")"
world; lane c-934 %34 -; reborn c-934; printf '%s S3\n' $((T0 - 1800)) $((T0 - 1200)) $((T0 - 600)) > "$S/c-934/lifetime/restarts"
rc="$(go ID=c-934 CAUSE=rebirth DRY_RUN=0)"
[[ "$rc" == 4 && ! -e "$T/spawn.log" && -s "$S/c-934/lifetime/heldout" ]] && grep -q 'held out: 3 restarts in the last hour' "$T/o" &&
  [[ "$(grep -c '^do_spl_desk_reply .*DESK_TO=HUM-10' "$T/run.log")" == 1 ]] &&
  pass "6. the 4th restart in an hour: held out, ONE admin alert, nothing spawned" || fail "6. fourth rc=$rc: $(cat "$T/o")"
rc="$(go ID=c-934 CAUSE=rebirth DRY_RUN=0 LEASE_NOW=$((T0 + 7200)))"
[[ "$rc" == 4 && ! -e "$T/spawn.log" ]] && grep -q 'held out until the admin clears it' "$T/o" && [[ "$(grep -c '^do_spl_desk_reply' "$T/run.log")" == 1 ]] &&
  pass "6. still held 2 h later (no expiry), no second alert" || fail "6. 2 h later rc=$rc: $(cat "$T/o")"

# --- 7. a failed lane spawn ---------------------------------------------------------------------------
world; lane c-935 %35 -; reborn c-935; echo nostart > "$T/spawn.mode.c-935"; mkdir -p "$D/wd"; echo "$T0" > "$D/wd/c-935.ep.S3.takeover"
rc="$(go ID=c-935 CAUSE=rebirth DRY_RUN=0 WD_EVIDENCE="rebirth: x")"
[[ "$rc" == 1 && "$(nproc c-935)" == 0 ]] && [[ "$(awk -F'\t' '$1 == "%35" {print $4}' "$T/tmux/panes")" == c-935@box1 && -z "$(awk -F'\t' '$1 == "%3935"' "$T/tmux/panes")" ]] &&
  [[ -e "$S/c-935/lifetime/rebirth" && ! -e "$D/wd/c-935.ep.S3.takeover" && "$(grep -c . "$S/c-935/lifetime/restarts")" == 1 ]] && grep -q 'RS-SPAWN FAIL' "$D/rotate.log" &&
  pass "7. a failed spawn: no process, the old window kept, the marker kept, the episode flag cleared, counted" || fail "7. failed rc=$rc: $(tail -4 "$T/o")"
rm -f "$T/spawn.mode.c-935"
rc="$(go ID=c-935 CAUSE=rebirth DRY_RUN=0 LEASE_NOW=$((T0 + 60)))"
[[ "$rc" == 0 && "$(nproc c-935)" == 1 ]] && pass "7. the next try runs" || fail "7. retry rc=$rc: $(tail -4 "$T/o")"

# --- 8. a guard refusal is not a restart done ----------------------------------------------------------
world; lane c-936 %36 -; reborn c-936; echo "c-002 $T0 r1" > "$D/rotate.hold"; mkdir -p "$D/wd"; echo "$T0" > "$D/wd/c-936.ep.S3.takeover"
rc="$(go ID=c-936 CAUSE=rebirth DRY_RUN=0 WD_EVIDENCE="rebirth: x")"
[[ "$rc" == 4 && ! -e "$D/wd/c-936.ep.S3.takeover" && ! -e "$S/c-936/lifetime/restarts" && ! -e "$T/spawn.log" ]] && grep -q 'rotate.hold names c-002' "$T/o" &&
  pass "8. refused by rotate.hold: exit 4, the episode flag cleared (the next tick retries), nothing counted" || fail "8. hold rc=$rc: $(cat "$T/o")"
# X holds c-936 until killed (the sleep keeps the pid its lock follows)
SPOOL_ROOT="$S" bash -c 'source "$PROJ_PATH/src/bash/run/spl-rotate-lib.func.sh"; spl_agent_id_lock c-936 X r 0 && exec sleep 600' & hp=$!
for _ in $(seq 300); do grep -q '^X ' "$S/c-936/lifetime/restart.holder" 2>/dev/null && break; sleep 0.1; done
rm -f "$D/rotate.hold"; echo "$T0" > "$D/wd/c-936.ep.S3.takeover"
rc="$(go ID=c-936 CAUSE=rebirth DRY_RUN=0 WD_EVIDENCE="rebirth: x")"; kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
[[ "$rc" == 4 && ! -e "$D/wd/c-936.ep.S3.takeover" && ! -e "$S/c-936/lifetime/restarts" ]] && grep -q 'id lock' "$T/o" &&
  pass "8. refused by the id lock: the same" || fail "8. idlock rc=$rc: $(cat "$T/o")"
rc="$(go ID=c-936 CAUSE=rebirth DRY_RUN=0 WD_EVIDENCE="rebirth: x")"
[[ "$rc" == 0 && "$(nproc c-936)" == 1 ]] && pass "8. control: the guards gone, the retry runs" || fail "8. retry rc=$rc: $(tail -3 "$T/o")"

# --- 9. done, retired, an unwritable handoff ----------------------------------------------------------------
world; lane c-937 %37 -; echo '{"started":"2027-01-15T07:00:00Z"}' > "$S/c-937/lifetime/session.json"; touch -d "@$((T0 - 60))" "$S/c-937/lifetime/done"
rc="$(go ID=c-937 CAUSE=S3 DRY_RUN=0)"
[[ "$rc" == 3 && ! -e "$T/spawn.log" ]] && grep -q 'done' "$T/o" && pass "9. done (lifetime/done newer than the session): exit 3" || fail "9. done rc=$rc: $(cat "$T/o")"
world; lane c-938 %38 -; cp "$S/registry.tsv" "$S/registry.retired.tsv"; : > "$S/registry.tsv"
rc="$(go ID=c-938 CAUSE=S3 DRY_RUN=0)"
[[ "$rc" == 3 && ! -e "$T/spawn.log" ]] && grep -q 'retired' "$T/o" && pass "9. retired (registry.retired.tsv, no live row): exit 3" || fail "9. retired rc=$rc: $(cat "$T/o")"
cp "$S/registry.retired.tsv" "$S/registry.tsv"
rc="$(go ID=c-938 CAUSE=S3 DRY_RUN=0)"
[[ "$rc" == 0 ]] && pass "9. control: a reused id with a live registry row runs" || fail "9. reused rc=$rc: $(tail -3 "$T/o")"
world; lane c-939 %39 -; rm -rf "$S/c-939/handoff"; echo x > "$S/c-939/handoff"
rc="$(go ID=c-939 CAUSE=S3 DRY_RUN=0)"
[[ "$rc" == 1 && ! -e "$T/spawn.log" ]] && grep -q 'RS-HANDOFF FAIL' "$D/rotate.log" && ! grep -q 'RS-HANDOFF OK' "$D/rotate.log" &&
  pass "9. a handoff that cannot be written: RS-HANDOFF FAIL (never OK), nothing spawned" || fail "9. handoff rc=$rc: $(cat "$D/rotate.log" 2>/dev/null)"

# --- 10. the hard end ----------------------------------------------------------------------------------------
world; AGE=7300 lane c-940 %40 4940; hb c-940 working 10; echo "\$1 $((T0 - 20))" > "$T/tmux/clients"
rc="$(go ID=c-940 CAUSE=hard-end DRY_RUN=0)"
[[ "$rc" == 0 ]] && ! alive 4940 && alive 3940 && grep -q 'hard_killed: true' "$S/c-940/handoff.md" &&
  pass "10. a session past HARD_END: restarted with a human client active (R3), hard_killed in the handoff" || fail "10. hard end rc=$rc: $(tail -4 "$T/o")"
world; AGE=3600 lane c-940 %40 4940; hb c-940 working 10
rc="$(go ID=c-940 CAUSE=hard-end DRY_RUN=0)"
[[ "$rc" == 3 ]] && alive 4940 && pass "10. control: a session 1 h old -> exit 3" || fail "10. young rc=$rc: $(cat "$T/o")"

# --- 11. a dry run ----------------------------------------------------------------------------------------
world; lane c-941 %41 -; reborn c-941
rc="$(go ID=c-941 CAUSE=rebirth)"
[[ "$rc" == 0 && ! -e "$T/spawn.log" && ! -e "$D/rotate.log" && ! -e "$T/sent" && -e "$S/c-941/lifetime/rebirth" && ! -e "$S/c-941/lifetime/restarts" ]] &&
  grep -q 'RS-SPAWN PLAN' "$T/o" && pass "11. a dry run: PLAN lines, nothing touched" || fail "11. dry rc=$rc: $(cat "$T/o")"

# --- 12. the human guard keys on the agent's window ----------------------------------------------
# wid <pane> <window id>: the window column tmux prints after the fg command
wid() { awk -F'\t' -v OFS='\t' -v p="$1" -v w="$2" '$1 == p {$6 = w} {print}' "$T/tmux/panes" > "$T/tmux/p.new" && mv "$T/tmux/p.new" "$T/tmux/panes"; }
world; lane c-941 %41 -; wid %41 @41; reborn c-941; echo "\$1 $((T0 - 20)) @7" > "$T/tmux/clients"
rc="$(go ID=c-941 CAUSE=rebirth DRY_RUN=0)"
[[ "$rc" == 0 ]] && alive 3941 && pass "12. a rebirth, the owner active in another window of its session: restarted" || fail "12. other window rc=$rc: $(tail -4 "$T/o")"
world; lane c-941 %41 -; wid %41 @41; reborn c-941; echo "\$1 $((T0 - 20)) @41" > "$T/tmux/clients"
rc="$(go ID=c-941 CAUSE=rebirth DRY_RUN=0)"
[[ "$rc" == 4 && ! -e "$T/spawn.log" && -e "$S/c-941/lifetime/rebirth" ]] && grep -q 'REFUSED c-941: a human client was active 20s ago' "$T/o" &&
  pass "12. control: the owner active in THAT window: refused (exit 4), nothing spawned, the marker kept" || fail "12. that window rc=$rc: $(tail -4 "$T/o")"
world; AGE=7300 lane c-942 %42 4942; wid %42 @42; hb c-942 working 10; echo "\$1 $((T0 - 20)) @42" > "$T/tmux/clients"
rc="$(go ID=c-942 CAUSE=hard-end DRY_RUN=0)"
[[ "$rc" == 0 ]] && ! alive 4942 && pass "12. control: the hard end with the owner in THAT window still restarts (R3)" || fail "12. hard end rc=$rc: $(tail -4 "$T/o")"

# --- 13. a dialog on the new session fails the start at once ------------------------------------
world; lane c-943 %43 -; reborn c-943
printf '  Settings Warning\n  ❯ 1. Continue\n    2. Fix with Claude\n    3. Exit and fix manually\n' > "$T/tmux/screen.%3943"
# "at once" = well inside the check's wait: a whole restart under it took
# 17 s on a loaded runner (gate 10 run 37976556608) against the old 15 of 20
t0=$SECONDS; rc="$(go ID=c-943 CAUSE=rebirth DRY_RUN=0 ROTATE_START_CHECK_WAIT=120)"; took=$((SECONDS - t0))
[[ "$rc" == 1 && "$took" -lt 60 && "$(nproc c-943)" == 0 ]] &&
  grep -q "RS-SPAWN FAIL the new session in %3943 is stopped on a 'Settings Warning' dialog" "$D/rotate.log" &&
  grep -q '^kill -TERM 3943$' "$T/kill.log" && ! grep -q '^keys %3943 ' "$T/tmux/log" 2>/dev/null &&
  pass "13. Settings Warning on the new session: RS-SPAWN FAIL at once (${took}s), named, signalled, nothing typed" ||
  fail "13. rc=$rc took=${took}s $(tail -5 "$T/o") keys: $(grep %3943 "$T/tmux/log" 2>/dev/null)"
grep -q '^do_spl_ask_put .*ASK_KIND=blocker' "$T/run.log" && grep -q '^do_spl_desk_reply .*DESK_TO=HUM-10' "$T/run.log" &&
  grep -qE '^[0-9a-f-]{36} [0-9]{8}T[0-9]{4}Z-rs-c-943 RS-SPAWN$' "$S/c-943/lifetime/alerts.open" &&
  pass "13. ... ALERT = ask + owner DM, recorded in lifetime/alerts.open" || fail "13. alert: $(cat "$T/run.log") $(cat "$S/c-943/lifetime/alerts.open" 2>&1)"
! grep -q ERRTRAP "$T/o" && pass "13. no stray failing command under the ERR trap" || fail "13. ERRTRAP: $(grep ERRTRAP "$T/o")"

# --- 14. recovered ------------------------------------------------------------------------------
world; lane c-944 %44 -; reborn c-944
echo "1a2b3c4d-1111-4222-8333-944455556666 20270115T0700Z-rs-c-944 RS-SPAWN" > "$S/c-944/lifetime/alerts.open"
rc="$(go ID=c-944 CAUSE=rebirth DRY_RUN=0)"
line="c-944@box1 recovered at [0-9T:-]*Z by do_spl_agent_restart [0-9]*T[0-9]*Z-rs-c-944 (rebirth), now pid 3944"
[[ "$rc" == 0 && ! -e "$S/c-944/lifetime/alerts.open" ]] &&
  grep -q "^do_spl_ask_close ASK_ID=1a2b3c4d-1111-4222-8333-944455556666 .*BODY=$line\$" "$T/run2.log" &&
  grep -q "^do_spl_desk_reply ASK_ID= DESK_TASK=1a2b3c4d-1111-4222-8333-944455556666 DESK_KIND=note BODY=$line\$" "$T/run2.log" &&
  [[ "$(grep -c 'recovered at' "$T/run2.log")" == 2 ]] &&
  pass "14. an open alert + DONE OK: the ask closed, one recovered line on its thread, the file gone" || fail "14. rc=$rc $(cat "$T/run2.log" 2>&1) $(tail -3 "$T/o")"
world; rm -f "$T/run2.log"; lane c-945 %45 -; reborn c-945
rc="$(go ID=c-945 CAUSE=rebirth DRY_RUN=0)"
[[ "$rc" == 0 ]] && ! grep -q 'do_spl_ask_close\|recovered at' "$T/run2.log" 2>/dev/null &&
  pass "14. control: no open alert, no ask close and no line" || fail "14. control rc=$rc $(cat "$T/run2.log" 2>&1)"

# --- 15. RS-REPORT with the relay down ------------------------------------------------------
Q="$D/wd/report.queue"
world; lane c-946 %46 -; reborn c-946; touch "$T/relay.down"
rc="$(go ID=c-946 CAUSE=rebirth DRY_RUN=0 ARS_REPORT_RETRY=1)"
[[ "$rc" == 0 && ! -e "$T/sent" && -n "$(compgen -G "$Q/*-rs-c-946.json")" ]] &&
  grep -q 'RS-REPORT QUEUED the REBORN line was not delivered (spool-send exit 13): journaled in ' "$D/rotate.log" &&
  ! grep -q 'RS-REPORT FAIL' "$D/rotate.log" &&
  pass "15. relay down: the REBORN line journaled (RS-REPORT QUEUED), not lost" || fail "15. queued rc=$rc: $(grep RS-REPORT "$D/rotate.log") $(ls "$Q" 2>&1)"
rm -f "$T/relay.down"
for _ in $(seq 100); do [[ -z "$(ls "$Q" 2>/dev/null)" ]] && grep -q REBORN "$T/sent" 2>/dev/null && break; sleep 0.1; done
[[ -z "$(ls -A "$Q")" && "$(grep -c -- '--to orchestrator --kind note --task restart-c-946 --no-ask --body REBORN c-946@box1 #1 cause=rebirth' "$T/sent" 2>/dev/null)" == 1 ]] &&
  grep -q 'rs-c-946 RS-REPORT OK REBORN c-946@box1 #1 cause=rebirth handoff=.* (journaled [0-9]*s)$' "$D/rotate.log" &&
  pass "15. relay back: the resend loop delivers it once (RS-REPORT OK), the queue empty" || fail "15. resend: $(cat "$T/sent" 2>&1) $(grep RS-REPORT "$D/rotate.log") $(ls -A "$Q")"
world; lane c-947 %47 -; lane c-948 %48 -; reborn c-948; touch "$T/relay.down"
rc="$(go ID=c-947 CAUSE=S3 DRY_RUN=0 ARS_REPORT_RETRY=0)"
[[ "$rc" == 0 ]] && grep -q 'rs-c-947 RS-REPORT QUEUED the blocker was not delivered' "$D/rotate.log" && [[ -n "$(ls "$Q")" ]] ||
  fail "15. blocker queued rc=$rc: $(grep RS-REPORT "$D/rotate.log")"
rm -f "$T/relay.down"
rc="$(go ID=c-948 CAUSE=rebirth DRY_RUN=0 ARS_REPORT_RETRY=0 LEASE_NOW=$((T0 + 60)))"
[[ "$rc" == 0 && -z "$(ls -A "$Q")" ]] && [[ "$(grep -o -- '--kind [a-z]* --task [a-z]*-c-94[78]' "$T/sent" | tr '\n' ' ')" == "--kind blocker --task wd-c-947 --kind note --task restart-c-948 " ]] &&
  grep -q 'rs-c-947 RS-REPORT OK blocker on task wd-c-947-[0-9TZ]* to the peers (journaled 60s)$' "$D/rotate.log" &&
  pass "15. a journaled crash blocker is sent by the next restart's report, oldest first" || fail "15. next report rc=$rc: $(cat "$T/sent" 2>&1) $(grep RS-REPORT "$D/rotate.log")"
world; lane c-949 %49 -; reborn c-949; touch "$T/relay.down"
rc="$(go ID=c-949 CAUSE=rebirth DRY_RUN=0 ARS_REPORT_QUEUE=0)"
[[ "$rc" == 0 && ! -e "$Q" ]] && grep -q 'rs-c-949 RS-REPORT FAIL the REBORN line was not delivered' "$D/rotate.log" &&
  pass "15. control: ARS_REPORT_QUEUE=0 (the old code) -> RS-REPORT FAIL as in the drill log, nothing kept" || fail "15. control rc=$rc: $(grep RS-REPORT "$D/rotate.log") $(ls -A "$Q" 2>&1)"

# --- 16. an m- (mistral / vibe) lane: S1 on its open plan ------------------------------------
# c-001@sat 2026-10-09 (n=2): m-617 / m-618 idle mid-plan after a Stop, inbox
# empty; `ID=m-618 CAUSE=S1 do_spl_agent_restart` was "FATAL ID must be an
# agent id". The m- id passes the gate, the S1 re-run hits on the plan, the
# old Vibe CLI pid is stopped first and a mistral session spawns in the same
# worktree. Controls: the plan complete -> no S1 hit (exit 3); an id of no
# agent kind (x-) -> FATAL
VFX="$PROJ_ROOT/src/bash/tests/fixtures/wd-situations"
vlane() {  # vlane <id> <pane> <pid> <pane fixture>: an m- lane whose harness is "Vibe CLI", idle after a Stop
  lane "$1" "$2" "$3" mistral
  sed -i "s/^$3 1 \([0-9]*\) mistral\$/$3 1 \1 Vibe CLI/" "$T/ps"; echo "Vibe CLI" > "$T/proc/$3/comm"
  cp "$4" "$T/tmux/screen.$2"
  hb "$1" idle 600 "| .harness = \"vibe\" | .pid = $3"
}
world; vlane m-950 %50 4950 "$VFX/vibe-idle-plan.pane"
rc="$(go ID=m-950 CAUSE=S1 DRY_RUN=0)"
[[ "$rc" == 0 ]] && ! alive 4950 && alive 3950 && [[ "$(head -2 "$T/order.log" | tr '\n' ' ')" == "kill 4950 spawn m-950 " ]] &&
  grep -q "^spawn mistral m-950 wd=$T/wt-m-950 SPAWN_REUSE_ID=1 " "$T/spawn.log" &&
  grep -q 'rs-m-950 RS-GATE OK m-950 (mistral) cause=S1 S1 age=600 plan .* 1/7 ' "$D/rotate.log" &&
  pass "16. an m- lane idle on its open plan: S1 restarts it (old pid first, a mistral spawn, same worktree)" ||
  fail "16. m- S1 rc=$rc: $(cat "$T/order.log" "$T/spawn.log" 2>/dev/null) $(grep RS-GATE "$D/rotate.log" 2>/dev/null) $(tail -3 "$T/o")"
world; vlane m-951 %51 4951 "$VFX/vibe-idle-done.pane"
rc="$(go ID=m-951 CAUSE=S1 DRY_RUN=0)"
[[ "$rc" == 3 ]] && alive 4951 && [[ ! -s "$T/spawn.log" ]] && grep -q 'REFUSED m-951: no S1 hit' "$T/o" &&
  pass "16. control: the same lane with its list complete: no S1 hit, exit 3, nothing spawned" || fail "16. done control rc=$rc: $(tail -3 "$T/o")"
world
rc="$(go ID=x-952 CAUSE=S1 DRY_RUN=0)"
[[ "$rc" == 1 ]] && grep -q "FATAL ID must be an agent id (c-NNN), got: 'x-952'" "$T/o" &&
  pass "16. control: an id of no agent kind (x-952) is FATAL" || fail "16. x- control rc=$rc: $(tail -2 "$T/o")"

# --- 17. a lane restored in flight continues its brief ---------------------------------------
seed17() { cat "$S/$1/handoff/"*-rs-"$1".seed.md 2>/dev/null; }
msg17() {  # msg17 <id> <dir> <kind> <age s>: one spool message of that kind, <age> seconds old
  local f
  f="$S/$1/$2/$(date -u +%Y%m%dT%H%M%SZ)-$3-$RANDOM.json"
  mkdir -p "$S/$1/$2"
  jq -n --arg k "$3" '{v: 1, ts: "2027-01-15T07:00:00Z", from: "c-970", to: "c-002", kind: $k, task_id: "dispatch-3192c200", body: "the \($k) text"}' > "$f"
  touch -d "@$(( $(date +%s) - $4 ))" "$f"
}
world; lane c-970 %70 -; reborn c-970
{ for n in 4 3 2 1; do
    printf '# Brief: you are c-970@box1, restarted by the watchdog (2027011%sT0600Z-rs-c-970)\n\n1. Section A is your brief: continue it.\n\n## A. Your brief (%s)\n\n' "$n" "$S/c-970/lifetime/brief.md"
  done
  printf 'Read your full task brief at /briefs/T970.md and implement it.\n\n## B. The handoff\n\n# handoff c-970\n'
} > "$S/c-970/lifetime/brief.md"
rc="$(go ID=c-970 CAUSE=rebirth DRY_RUN=0)"
sd="$(seed17 c-970)"
bad=""
[[ "$rc" == 0 ]] || bad+=" rc=$rc"
grep -q '^4\. Then CONTINUE the brief now' <<<"$sd" || bad+=" no-continue"
grep -q 'Do not stop at an empty prompt after reading the handoff' <<<"$sd" || bad+=" no-do-not-stop"
[[ "$(grep -c '^# Brief: you are c-970@' <<<"$sd")" == 1 ]] || bad+=" nested-seeds=$(grep -c '^# Brief: you are c-970@' <<<"$sd")"
grep -q 'brief at /briefs/T970.md' <<<"$sd" || bad+=" no-brief-path"
[[ "$(head -1 "$S/c-970/lifetime/brief.md")" == "Read your full task brief at /briefs/T970.md and implement it." ]] || bad+=" brief.md=$(head -1 "$S/c-970/lifetime/brief.md")"
[[ -z "$bad" ]] && pass "17. a lane in flight: its seed says CONTINUE the brief; a brief nested 4 seeds deep is cut back to the real one" ||
  fail "17. in flight:$bad -- $(head -c 1500 <<<"$sd")"
world; lane c-971 %71 -; reborn c-971; msg17 c-971 archive task 600; msg17 c-971 outbox blocker 300
rc="$(go ID=c-971 CAUSE=rebirth DRY_RUN=0)"; sd="$(seed17 c-971)"
[[ "$rc" == 0 ]] && grep -q '^4\. Then WAIT: your brief is blocked' <<<"$sd" && grep -q 'the blocker text' <<<"$sd" && ! grep -q 'CONTINUE' <<<"$sd" &&
  pass "17. control: an unanswered blocker -> the seed says WAIT, not CONTINUE" || fail "17. blocked rc=$rc: $(grep -A3 '^4\.' <<<"$sd")"
world; lane c-972 %72 -; reborn c-972; msg17 c-972 outbox result 300
rc="$(go ID=c-972 CAUSE=rebirth DRY_RUN=0)"; sd="$(seed17 c-972)"
[[ "$rc" == 0 ]] && grep -q '^4\. Then FINISH: your brief is done' <<<"$sd" && ! grep -q 'CONTINUE' <<<"$sd" &&
  pass "17. control: a final result sent -> the seed says FINISH, not CONTINUE" || fail "17. done rc=$rc: $(grep -A3 '^4\.' <<<"$sd")"
world; lane c-973 %73 -; reborn c-973; msg17 c-973 outbox blocker 600; msg17 c-973 archive note 300
rc="$(go ID=c-973 CAUSE=rebirth DRY_RUN=0)"; sd="$(seed17 c-973)"
[[ "$rc" == 0 ]] && grep -q '^4\. Then CONTINUE the brief now' <<<"$sd" &&
  pass "17. control: a blocker answered since -> CONTINUE again" || fail "17. answered rc=$rc: $(grep -A3 '^4\.' <<<"$sd")"

world; lane c-974 %74 -; reborn c-974; msg17 c-974 outbox result 300; msg17 c-974 archive reject 100
rc="$(go ID=c-974 CAUSE=rebirth DRY_RUN=0)"; sd="$(seed17 c-974)"
[[ "$rc" == 0 ]] && ! grep -q 'FINISH' <<<"$sd" && grep -q '^4\. Then ACT on the newer message' <<<"$sd" &&
  grep -q '<- c-970 \[dispatch-319\] the reject text' <<<"$sd" &&
  pass "17. a message newer than the result (m-682) -> the seed says ACT on it, names it, no FINISH" ||
  fail "17. reopened rc=$rc: $(grep -A3 '^4\.' <<<"$sd")"
world; lane c-975 %75 -; reborn c-975; msg17 c-975 outbox result 300
jq -n '{v: 1, ts: "2027-01-15T07:00:00Z", from: "c-975", to: "c-975", kind: "result", task_id: "restart-x", body: "ACK"}' > "$S/c-975/inbox/ack.json"
touch -d "@$(( $(date +%s) - 100 ))" "$S/c-975/inbox/ack.json"
rc="$(go ID=c-975 CAUSE=rebirth DRY_RUN=0)"; sd="$(seed17 c-975)"
[[ "$rc" == 0 ]] && grep -q '^4\. Then FINISH: your brief is done' <<<"$sd" &&
  pass "17. control: only a restart ACK newer than the result -> still FINISH" || fail "17. ack rc=$rc: $(grep -A3 '^4\.' <<<"$sd")"

echo "agent-restart: $fails failure(s)"
exit $(( fails > 0 ))
