#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dispatch_rotate (SPEC-spool-fleet-roles.md 4.4). Nothing
#          live is touched: a sandbox SPOOL_ROOT, a fake /proc
#          (LEASE_PROC_ROOT) holding the "claude" agents, a stub spawn that
#          starts a fake claude (and acks like a fresh session would), a stub
#          tmux, a stub spool-send that writes real mailbox files.
#   1. a dry run prints the plan and touches nothing
#   2. a full rotation: fresh M and F under the SAME ids, the old sessions
#      typed /exit-clean no-close and gone, old windows closed, lease.conf
#      unchanged, the lease back on M, F told ACTIVE while M was replaced
#   3. never two masters: while M is held, every M process is off the lease
#      (spl_lease_agent_able), the lease names F, and the release hands back
#   4. the handoff is assembled by script: unread inbox, outbox, terminal
#      lines (redacted), asks, lanes
#   5. no ack: the fresh M is killed, the OLD M keeps the role, an ask + an
#      owner DM are raised, no message is lost (the inbox is untouched)
#   6. no start: same, the old M keeps the role
#   7. a busy master is rotated anyway (owner decision 1)
#   8. heal: a dead failover is spawned, M is not touched
#   9. a recent rotation is skipped; a second concurrent run is skipped
#  10. a stale hold is ignored with one WARN
#  11. fleet mode: the lease does not move -> stop, M keeps the role
#  12. the cron installer writes one tagged line at :15 (dry run)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SPOOL_TEST=1

S="$T/spool" P="$T/proc" D="$T/spool/dispatch"
mkdir -p "$T/bin"

# stub spool-send: a real v:1 file in <to>/inbox and a copy in <from>/outbox
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
from="" to="" kind="" task="" body="" ask=""
while [ $# -gt 0 ]; do case "$1" in
  --from) from="$2"; shift 2 ;; --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;;
  --task) task="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; --ask) ask="$2"; shift 2 ;; *) shift ;; esac; done
id="$(cat /proc/sys/kernel/random/uuid)"
j="$(jq -cn --arg i "$id" --arg f "$from" --arg t "$to" --arg k "$kind" --arg ta "$task" --arg b "$body" \
  '{v:1,msg_id:$i,task_id:$ta,ts:"2026-10-02T05:15:00Z",from:$f,to:$t,kind:$k,body:$b,files:[]}')"
mkdir -p "$SPOOL_ROOT/$to/inbox" "$SPOOL_ROOT/$from/outbox"
echo "$j" >"$SPOOL_ROOT/$to/inbox/$id.json"; echo "$j" >"$SPOOL_ROOT/$from/outbox/$id.json"
echo "$to|$kind|${ask:-}|lease=$(cut -d' ' -f1 "$SPOOL_ROOT/dispatch/lease" 2>/dev/null)|hold=$(cut -d' ' -f1 "$SPOOL_ROOT/dispatch/rotate.hold" 2>/dev/null)|$body" >>"$SENT"
echo "{\"delivery\":\"local\",\"msg_id\":\"$id\",\"task_id\":\"$task\"}"
EOF
# stub spawn <id> <role> <brief>: a fake claude in a new pane; acks unless told not to
cat >"$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
id="$1" brief="$3"
echo "$id $2 $brief" >>"$T/spawned"
[ -f "$T/nostart" ] && exit 0
pid=$(( $(cat "$T/nextpid") + 1 )); echo "$pid" >"$T/nextpid"
pane="%$pid"
mkdir -p "$P/$pid"; echo claude >"$P/$pid/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$id" >"$P/$pid/environ"
printf '%s\tclaude\t%s\t/x\t20261002T051500Z\n' "$id" "$pane" >>"$SPOOL_ROOT/registry.tsv"
echo "$pane $id $pid" >>"$T/panes"
[ -f "$T/noack" ] && exit 0
task="$(grep -o 'dispatch-rotate-[A-Za-z0-9-]*' "$brief" | head -1)"
mkdir -p "$SPOOL_ROOT/$id/outbox"
printf '{"v":1,"msg_id":"ack-%s","task_id":"%s","from":"%s","to":"O-1","kind":"note","body":"up"}\n' "$pid" "$task" "$id" >"$SPOOL_ROOT/$id/outbox/ack-$pid.json"
EOF
# stub tmux: window names and pids from $T/panes ("<pane> <id> <pid>")
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/tmux.log"
t=""; a=("$@"); for ((i=0; i<${#a[@]}; i++)); do [ "${a[$i]}" = -t ] && t="${a[$((i+1))]}"; done
row="$(awk -v p="$t" '$1 == p' "$T/panes" | tail -1)"
case "$1" in
  display-message) [ -n "$row" ] && echo "$(cut -d' ' -f2 <<<"$row") dispatcher" ;;
  capture-pane) if [ -f "$T/busy" ]; then printf 'working\n(12s · esc to interrupt)\n'; else printf 'routed t1 post to CLE-77\npassword=hunter2secret\n❯ \n'; fi ;;
  send-keys) [ "$4" = '/exit-clean no-close' ] && [ ! -f "$T/stubborn" ] && rm -rf "${P:?}/$(cut -d' ' -f3 <<<"$row")" ;;
  kill-window) echo "$t" >>"$T/closed" ;;
esac
exit 0
EOF
cat >"$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "$1 $2" >>"$T/killed"; rm -rf "${P:?}/$2"
EOF
cat >"$T/bin/owner" <<'EOF'
#!/usr/bin/env bash
echo "owner: $(cat)" >>"$T/owner"
EOF
chmod +x "$T/bin/"*

# agent <pid> <id> <pane>: a live fake claude, started 2 h ago
agent() {
  mkdir -p "$P/$1"; echo claude >"$P/$1/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$2" >"$P/$1/environ"
  touch -d '2 hours ago' "$P/$1"
  printf '%s\tclaude\t%s\t/x\t20261001T054800Z\n' "$2" "$3" >>"$S/registry.tsv"
  echo "$3 $2 $1" >>"$T/panes"
}
# fresh sandbox: M-1 pid 100 pane %10 holds the lease, F-1 pid 200 pane %20
reset() {
  rm -rf "$S" "$P" "$T"/{panes,spawned,tmux.log,closed,killed,owner,sent,noack,nostart,busy,stubborn}
  mkdir -p "$D/briefs" "$P" "$S/M-1/inbox" "$S/M-1/outbox"
  echo 900 >"$T/nextpid"
  printf 'LEASE_MASTER=M-1\nLEASE_FAILOVER=F-1\nLEASE_ORCH=O-1\nASKS_OWNER=HUM-10\n' >"$D/lease.conf"
  echo "brief of M-1" >"$D/briefs/brief-dispatcher-M-1.md"; echo "brief of F-1" >"$D/briefs/brief-dispatcher-F-1.md"
  echo "M-1 $(date +%s)" >"$D/lease"
  agent 100 M-1 %10; agent 200 F-1 %20
  printf '{"v":1,"msg_id":"unread-1","task_id":"t-owner","ts":"2026-10-02T05:10:00Z","from":"HUM-10","to":"M-1","kind":"msg","body":"owner asks for X"}\n' >"$S/M-1/inbox/unread-1.json"
  printf '{"v":1,"msg_id":"out-1","task_id":"t-route","ts":"2026-10-02T05:00:00Z","from":"M-1","to":"CLE-9","kind":"task","body":"routed the X post"}\n' >"$S/M-1/outbox/out-1.json"
}

rot() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" T="$T" P="$P" LEASE_PROC_ROOT="$P" SENT="$T/sent" \
    ROTATE_SEND="$T/bin/send" ROTATE_SPAWN="$T/bin/spawn" ROTATE_TMUX="$T/bin/tmux" ROTATE_KILL="$T/bin/kill" \
    ROTATE_OWNER_CMD="$T/bin/owner" ROTATE_ASKS_CMD="echo ask-1 open" ROTATE_LANES_CMD="echo CLE-9 live" \
    SPOOL_DESK_BOX=boxa ROTATE_IDLE_POLL=0 ROTATE_IDLE_WAIT=2 ROTATE_SPAWN_POLL=0 ROTATE_SPAWN_WAIT=3 ROTATE_ACK_POLL=0 \
    ROTATE_ACK_WAIT=3 ROTATE_EXIT_POLL=0 ROTATE_EXIT_WAIT=3 ROTATE_KILL_GRACE=0 ROTATE_SETTLE=0 ROTATE_LEASE_POLL=0 \
    ROTATE_LEASE_WAIT=2 ROTATE_FORCE="${FORCE-1}" DRY_RUN="${DRY-0}" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-rotate.func.sh"
    do_spl_dispatch_rotate'
}
live() { [[ -d "$P/$1" ]]; }
pids_of() { grep -lzx "SPOOL_AGENT_ID=$1" "$P"/*/environ 2>/dev/null | wc -l; }
holder() { cut -d' ' -f1 "$D/lease"; }

# --- 1. dry run ------------------------------------------------------------------
reset
out="$(DRY=1 rot 2>&1)"
[[ "$out" == *"PLAN"*"rotate.hold"* && "$out" == *"STEP replace PLAN spawn a fresh M-1"* && "$out" == *"STEP replace PLAN spawn a fresh F-1"* &&
   ! -e "$D/rotate.hold" && ! -e "$D/rotate.log" && ! -e "$T/spawned" && ! -e "$T/sent" ]] && live 100 && live 200 &&
  pass "1. a dry run prints the plan and touches nothing" || fail "1. dry run: $out"

# --- 2/3/4. full rotation ------------------------------------------------------------
reset
cp "$D/lease.conf" "$T/conf.before"
out="$(rot 2>&1)"; rc=$?
if [[ $rc == 0 ]] && ! live 100 && ! live 200 && [[ "$(pids_of M-1)" == 1 && "$(pids_of F-1)" == 1 ]]; then
  pass "2. fresh M-1 and F-1 under the same ids, the old sessions are gone"
else fail "2. rc=$rc M-1 x$(pids_of M-1) F-1 x$(pids_of F-1): $out"; fi
[[ "$(grep -c "send-keys -t %10 -l /exit-clean no-close" "$T/tmux.log")" == 1 && "$(grep -c "send-keys -t %20 -l /exit-clean no-close" "$T/tmux.log")" == 1 &&
   "$(sort "$T/closed" | tr '\n' ' ')" == "%10 %20 " ]] &&
  pass "2. each old session got /exit-clean no-close in ITS pane; only the old windows were closed" || fail "2. tmux: $(cat "$T/tmux.log") closed: $(cat "$T/closed" 2>&1)"
cmp -s "$D/lease.conf" "$T/conf.before" && [[ "$(holder)" == M-1 && ! -e "$D/rotate.hold" && -s "$D/rotate.dispatch.last" ]] &&
  pass "2. lease.conf unchanged (ids keep their roles), the lease back on M-1, no hold left" || fail "2. conf/lease: $(cat "$D/lease.conf") lease=$(cat "$D/lease")"
grep -q '^F-1|note||lease=F-1|hold=M-1|DISPATCH LEASE: you are now ACTIVE' "$T/sent" &&
  grep -q '^M-1|note||lease=F-1|hold=M-1|DISPATCH LEASE: STANDBY' "$T/sent" &&
  pass "3. F-1 is told ACTIVE and M-1 STANDBY while the lease names F-1 and M-1 is held" || fail "3. sent: $(cat "$T/sent")"
[[ "$(grep -c '' "$D/rotate.log")" -ge 10 && "$(grep -c 'retire' "$D/rotate.log")" -ge 2 ]] &&
  pass "2. one log line per step in rotate.log" || fail "2. log: $(cat "$D/rotate.log")"
h="$(ls "$D"/handoff/*-M-1.md 2>/dev/null | head -1)"
if [[ -n "$h" ]] && grep -q 'unread-1.*owner asks for X' "$h" && grep -q 'out-1.*routed the X post' "$h" &&
   grep -q 'routed t1 post to CLE-77' "$h" && ! grep -q hunter2secret "$h" && grep -q 'ask-1 open' "$h" && grep -q 'CLE-9 live' "$h"; then
  pass "4. the handoff lists the unread inbox, the outbox, redacted terminal lines, asks and lanes"
else fail "4. handoff $h: $(cat "$h" 2>&1)"; fi
b="$(awk '$1 == "M-1" {print $3}' "$T/spawned")"
grep -q 'brief of M-1' "$b" && grep -q "Read the handoff $h" "$b" && grep -q -- '--from M-1 --to O-1 --kind note --task dispatch-rotate-' "$b" &&
  pass "4. the fresh M-1 is seeded with its role brief, the handoff and the ack command" || fail "4. brief: $(cat "$b" 2>&1)"
[[ -f "$S/M-1/inbox/unread-1.json" ]] && pass "3. no message lost: M-1's inbox is untouched" || fail "3. the unread message is gone"

# --- 3. the hold gate ---------------------------------------------------------------
reset
gate() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" LEASE_PROC_ROOT="$P" LEASE_PANE_CMD=true bash -c '
    do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init
    echo "able=[$(spl_lease_agent_able M-1)] why=[$(cat "$LEASE_DIR/able.M-1")]"'
}
echo "M-1 $(date +%s)" >"$D/rotate.hold"
out="$(gate)"
[[ "$out" == "able=[] why=[held: rotation since "* ]] && pass "3. a held master is not able to act (renew, watch and the fleet candidate skip it)" || fail "3. gate: $out"
echo "F-1 $(date +%s)" >"$D/rotate.hold"
[[ "$(gate)" == "able=[100] why=[able]" ]] && pass "3. a hold on another id leaves the master able" || fail "3. other id: $(gate)"

# --- 10. stale hold ------------------------------------------------------------------
echo "M-1 $(( $(date +%s) - 4000 ))" >"$D/rotate.hold"
gate >/dev/null; out="$(gate)"
[[ "$out" == "able=[100] why=[able]" && "$(grep -c 'rotate.hold on M-1 is .* ignored' "$D/lease.log")" == 1 ]] &&
  pass "10. a hold older than ROTATE_HOLD_MAX is ignored, logged once" || fail "10. stale: $out log: $(cat "$D/lease.log" 2>&1)"

# --- 5. no ack ---------------------------------------------------------------------
reset; touch "$T/noack"
out="$(rot 2>&1)"; rc=$?
if [[ $rc == 1 ]] && live 100 && live 200 && [[ "$(pids_of M-1)" == 1 && "$(holder)" == M-1 && ! -e "$D/rotate.hold" ]] &&
   grep -q '^901' <(cut -d' ' -f2 "$T/killed") && ! grep -q '/exit-clean' "$T/tmux.log"; then
  pass "5. no ack: the fresh M-1 is killed, the OLD M-1 keeps the role and the lease"
else fail "5. rc=$rc M-1 x$(pids_of M-1) lease=$(cat "$D/lease") killed=$(cat "$T/killed" 2>&1): $out"; fi
grep -q '^O-1|blocker|blocker|.*BLOCKER (dispatch rotation)' "$T/sent" && grep -q 'owner: .*FAILED' "$T/owner" &&
  grep -q '^M-1|note|.*you are ACTIVE again' "$T/sent" &&
  pass "5. an ask (blocker in the ask book) and an owner DM raise it; the old M-1 is told ACTIVE again" || fail "5. alert: $(cat "$T/sent") owner: $(cat "$T/owner" 2>&1)"
[[ -f "$S/M-1/inbox/unread-1.json" && ! -e "$D/rotate.dispatch.last" ]] && pass "5. no message lost and the next run retries (no rotate.dispatch.last)" || fail "5. inbox/last"

# --- 6. no start -------------------------------------------------------------------
reset; touch "$T/nostart"
out="$(rot 2>&1)"; rc=$?
[[ $rc == 1 ]] && live 100 && [[ "$(holder)" == M-1 && ! -e "$D/rotate.hold" ]] && grep -q 'did not start' "$D/rotate.log" &&
  grep -q '^O-1|blocker|blocker' "$T/sent" && pass "6. no start: the old M-1 keeps the role, alerted" || fail "6. rc=$rc: $out"

# --- 7. busy -----------------------------------------------------------------------
reset; touch "$T/busy"
out="$(rot 2>&1)"; rc=$?
[[ $rc == 0 ]] && ! live 100 && [[ "$(pids_of M-1)" == 1 ]] && grep -q 'busy after .* rotating anyway' "$D/rotate.log" &&
  pass "7. a busy master is rotated anyway" || fail "7. rc=$rc: $out"

# --- 8. heal -----------------------------------------------------------------------
reset; rm -rf "${P:?}/200"
out="$(rot 2>&1)"; rc=$?
[[ $rc == 0 ]] && live 100 && [[ "$(pids_of F-1)" == 1 && "$(awk '{print $1}' "$T/spawned")" == F-1 && ! -e "$D/rotate.hold" ]] &&
  ! grep -q '/exit-clean' "$T/tmux.log" && pass "8. a dead failover is spawned fresh; M-1 is not touched" || fail "8. rc=$rc: $out"

# --- 9. skips ------------------------------------------------------------------------
reset; date +%s >"$D/rotate.dispatch.last"
out="$(FORCE=0 rot 2>&1)"
[[ "$out" == *"SKIP last rotation 0 min ago"* && ! -e "$T/spawned" ]] && pass "9. a rotation less than an hour old is skipped" || fail "9. recent: $out"
reset
out="$( (exec 7>"$D/rotate.dispatch.lock"; flock 7; rot) 2>&1)"
[[ "$out" == *"SKIP another rotation runs"* && ! -e "$T/spawned" ]] && pass "9. a second concurrent run is skipped" || fail "9. lock: $out"

reset; echo ROTATE=0 >"$D/rotate.conf"
out="$(rot 2>&1)"
[[ "$out" == *"SKIP switched off"* && ! -e "$T/spawned" ]] && pass "9. ROTATE=0 in rotate.conf stops the rotation at its first gate (FR-090)" || fail "9. switch: $out"

# --- 11. fleet ---------------------------------------------------------------------
reset
printf 'LEASE_FLEET=main\nLEASE_PRIORITY=boxa,boxb\n' >>"$D/lease.conf"
echo "M-1@boxa $(date +%s)" >"$D/lease"
out="$(rot 2>&1)"; rc=$?
[[ $rc == 1 ]] && live 100 && [[ ! -e "$D/rotate.hold" && ! -e "$T/spawned" ]] && grep -q 'did not move to F-1@boxa' "$D/rotate.log" &&
  pass "11. fleet: the lease did not move to F-1 -> stopped, hold released, M-1 keeps the role" || fail "11. rc=$rc: $out"
reset
printf 'LEASE_FLEET=main\nLEASE_PRIORITY=boxa,boxb\n' >>"$D/lease.conf"
echo "CLE-002@boxb $(date +%s)" >"$D/lease"
out="$(rot 2>&1)"; rc=$?
[[ $rc == 0 && "$(pids_of M-1)" == 1 ]] && ! live 100 && grep -q 'fleet dispatch lease is CLE-002@boxb' "$D/rotate.log" &&
  pass "11. fleet, held by another machine: nothing to move, the sessions are still refreshed" || fail "11. remote: rc=$rc $out"

# --- 12. cron installer -------------------------------------------------------------
mkdir -p "$T/src"
out="$(env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" DESK_CRON_SRC="$T/src" DESK_CRON_SELF_UPDATE=0 DRY_RUN=1 bash -c '
  do_log() { echo "$*"; }; do_require_bin() { :; }; crontab() { [ "$1" = -l ] && echo "0 * * * * x # other"; }
  source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-dispatch-rotate-install-cron.func.sh"
  do_spl_dispatch_rotate_install_cron' 2>&1)"
[[ "$out" == *"+15 * * * * "*"dispatch-rotate-cron.sh"*"# csi-spl:dispatch-rotate"* ]] &&
  pass "12. the installer plans ONE tagged line at minute 15" || fail "12. cron: $out"

echo
(( fails == 0 )) && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
