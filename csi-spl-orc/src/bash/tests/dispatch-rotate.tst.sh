#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the hourly dispatcher rotation (spec 060 section 4.3, CLE-77940):
#          do_spl_dispatch_rotate on spl-rotate-lib.func.sh, the hold in
#          spl_lease_agent_able, and do_spl_dispatch_rotate_install_cron, in a
#          sandbox. Nothing real is touched: processes live in a fake /proc
#          (LEASE_PROC_ROOT), tmux is a stub keeping panes in a file, the spawn
#          starts a fake claude that runs ONLY its seed's ACK-COMMAND line
#          (T-NO-MODEL), ./run, spool-send, kill and the identity map are
#          stubs. The action runs under ./run's `set -E` + ERR trap.
#   1. dry run: PLAN lines, nothing written, held, renamed or spawned
#   2. gates: disabled (env, rotate.conf), standby (FR-044), young, stalled
#      (FR-022), duplicate, locked, orch rotation in flight (FR-051)
#   3. T-DISP-HAPPY: HOLD (the lease names F while every M process is held,
#      T-DISP-ONE-HOLDER), the fresh M seeded + an inbox task (FR-026), ack =
#      outbox result (FR-041), /exit-clean, RELEASE (the lease back on M),
#      then REFRESH F the same way, DONE; lease.conf untouched (I8); no
#      message lost (T-MSG-IN-FLIGHT)
#   4. T-DISP-ACK-FAIL: the fresh M closed, the OLD M keeps the role and the
#      lease, the hold removed, ALERT = ask + owner DM
#   5. a failed F refresh keeps the old F, M stays fresh
#   6. T-DISP-HEAL: a missing dispatcher -> do_spl_dispatch_setup, nothing else
#   7. T-DISP-ACK-SOURCE: an ack from the old pid / a wrong rid -> exit 3
#   8. T-DISP-HOLD-STALE: the hold gate, and a hold older than
#      ROTATE_HOLD_MAX ignored with one WARN (FR-023, FR-024)
#   9. resume (FR-003) and abort (FR-091)
#  10. T-CRON: :15, idempotent, check, CRON_REMOVE=1; the heal line every 3 min
#      off the rotation's minute, the cron script's --heal
#  11. ROTATE_CMD=heal: dead -> healed (rotate.log, no rotation), alive or on
#      a usage-limit pane -> untouched, back within the confirm window ->
#      untouched, two at once -> one heal, gates (in flight, ROTATE_HEAL=0)
#  12. RELEASE with the fleet lease on another machine -> SKIP standby, DONE,
#      no alert, no resume; on this machine a wrong holder still FAILs and
#      the alert names the new pid (20261006T1315Z-master on sat)
#  13. the fresh M dies during the F refresh -> DONE FAIL, the orchestrator
#      told NOT healthy, never "holds the dispatch lease" (20261007T0915Z)
#  14. the fresh M parked on a "Settings Warning" dialog -> FAIL SPAWN at
#      once naming it (not after the ack wait), the old M keeps the role,
#      ALERT; nothing typed into the dialog (20261007T1715Z-failover).
#      Control: the same rotation on a plain screen is not failed at SPAWN
#  15. a seat with an open FAIL alert (lifetime/alerts.open) whose rotation
#      acks: the ask closed + one "recovered at <ts> by rotation <rid>, now
#      pid <pid>" line on the ask's thread, the file gone. Control: no open
#      alert -> no ask close, no line
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D/briefs" "$T/hold" "$T/mem"
TCK="$(getconf CLK_TCK)"; UP=100000
echo "$UP.00 0.00" >"$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" >"$S/box.env"
CONF=$'LEASE_MASTER=c-902\nLEASE_FAILOVER=c-903\nLEASE_ORCH=c-900\nLEASE_ENV=prd\nLEASE_TENANT=t1\nASKS_OWNER=HUM-10'
for id in c-902 c-903; do echo "brief of $id: read your inbox" >"$D/briefs/brief-dispatcher-$id.md"; done

# --- stubs --------------------------------------------------------------------
# proc <pid> <id> <age-s>: a fake claude carrying SPOOL_AGENT_ID=<id>
cat >"$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo claude >"$d/comm"
printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$d/environ"
echo "$1 (claude) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (UP - $3) * TCK ))" >"$d/stat"
printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" >"$d/status"
EOF
# tmux: panes in $T/tmux/panes as "<pane>\t<pid>\t<session>\t<name>". A
# capture with -e also draws the CLI input box (typed.<pane>; C-c empties it),
# which the RETIRE reads back before Enter (CLE-77951, orch-rotate case 11).
cat >"$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
P="$T/tmux/panes"; L="$T/tmux/log"
cmd="$1"; shift
tgt="" lit=0 esc=0 args=()
while [ $# -gt 0 ]; do case "$1" in -t) tgt="$2"; shift 2 ;; -l) lit=1; shift ;; -a|-p|-J) shift ;; -e) esc=1; shift ;; -F|-S) shift 2 ;; *) args+=("$1"); shift ;; esac; done
field() { awk -F'\t' -v p="$tgt" -v f="$1" '$1 == p {print $f}' "$P"; }
case "$cmd" in
  list-panes) awk -F'\t' '{print $2" "$1}' "$P" ;;
  display-message) grep -q "^$tgt	" "$P" || exit 1
    case "${args[0]}" in *window_name*) field 4 ;; *session_id*) field 3 ;; *pane_id*) echo "$tgt" ;; esac ;;
  capture-pane) grep -q "^$tgt	" "$P" || exit 1
    if [ -f "$T/tmux/screen.$tgt" ]; then cat "$T/tmux/screen.$tgt"; else printf 'routed the t1 post\n❯ \n'; fi
    if [ "$esc" = 1 ]; then printf '────────\n❯ %s\n────────\n' "$(cat "$T/tmux/typed.$tgt" 2>/dev/null)"; fi ;;
  rename-window) awk -F'\t' -v OFS='\t' -v p="$tgt" -v n="${args[0]}" '$1 == p {$4 = n} {print}' "$P" >"$P.new" && mv "$P.new" "$P"
    echo "rename $tgt ${args[0]}" >>"$L" ;;
  send-keys) k="${args[0]}"; echo "keys $tgt $k" >>"$L"
    if [ "$lit" = 1 ]; then printf '%s' "$k" >>"$T/tmux/typed.$tgt"
    elif [ "$k" = C-u ] || [ "$k" = C-c ]; then : >"$T/tmux/typed.$tgt"
    elif [ "$k" = Enter ]; then
      if grep -q '^/exit' "$T/tmux/typed.$tgt" 2>/dev/null && [ ! -f "$T/tmux/stubborn.$tgt" ]; then rm -rf "$T/proc/$(field 2)"; fi
      : >"$T/tmux/typed.$tgt"
    fi ;;
  kill-window) awk -F'\t' -v p="$tgt" '$1 != p' "$P" >"$P.new" && mv "$P.new" "$P"; echo "kill $tgt" >>"$L" ;;
  *) echo "tmux stub: $cmd" >&2; exit 1 ;;
esac
EOF
# spawn-window.sh <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>"; the fake
# claude runs ONLY the seed's ACK-COMMAND line (no model: T-NO-MODEL)
cat >"$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
id="$2"; n="${id##*-}"; pid=$(( 2000 + 10#$n )); pane="%2$n"
echo "spawn $* SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-}" >>"$T/spawn.log"
mode="$(cat "$T/spawn.mode.$id" 2>/dev/null || echo ok)"
[ "$mode" = nopane ] && { echo "spawn-window: no pane"; exit 4; }
printf '%s\t%s\t$0\t%s@box\n' "$pane" "$pid" "$id" >>"$T/tmux/panes"
[ "$mode" = nostart ] || "$T/bin/proc" "$pid" "$id" 0
# spawn.kills.<id> "<pid> <lease>": that pid dies and the lease moves as this
# spawn runs (20261007T0915Z: the fresh master's window closed mid-refresh)
if [ -f "$T/spawn.kills.$id" ]; then read -r kp kl <"$T/spawn.kills.$id"; rm -rf "$T/proc/$kp"; echo "$kl $(date +%s)" >"$SPOOL_ROOT/dispatch/lease"; fi
echo '{"v":1,"msg_id":"m9","ts":"2026-10-02T05:16:00Z","from":"HUM-10","to":"c-902","kind":"msg","task_id":"y","body":"mid-rotation"}' >"$SPOOL_ROOT/c-902/inbox/m9.json"
if [ "$(cat "$T/ack.mode.$id" 2>/dev/null || echo yes)" = yes ]; then
  rid="$(grep '^ACK-COMMAND:' "$4" | grep -oE 'ROTATE_ID=[0-9A-Za-z-]+' | cut -d= -f2)"
  ( sleep 1; ROTATE_CMD=ack ROTATE_ID="$rid" ROTATE_CALLER_PID="$pid" "$T/bin/act" >>"$T/ack.out" 2>&1 ) >/dev/null 2>&1 &
fi
echo "$id $pane"
EOF
# ./run: the ask book, the lane map, the alert legs, the heal setup
cat >"$T/bin/run" <<'EOF'
#!/usr/bin/env bash
a="$2"
echo "$a ASK_KIND=${ASK_KIND:-} ASK_FROM=${ASK_FROM:-} ASK_TOPIC=${ASK_TOPIC:-} DESK_TO=${DESK_TO:-} DISPATCH_MASTER=${DISPATCH_MASTER:-} ASK_SUMMARY=${ASK_SUMMARY:-}" >>"$T/run.log"
echo "$a ASK_ID=${ASK_ID:-} ASK_STATE=${ASK_STATE:-} DESK_TASK=${DESK_TASK:-} DESK_KIND=${DESK_KIND:-} BODY=${ASK_REASON:-}${DESK_BODY:-}" >>"$T/run2.log"
case "$a" in
  do_spl_asks_open) echo '{"asks":[]}' ;;
  do_spl_lane_map) echo '{"lanes":[]}' ;;
  do_spl_dispatch_setup) sleep "${SETUP_SLEEP:-0}"; [ -d "$T/proc/203" ] || "$T/bin/proc" 203 c-903 0 ;;
  do_spl_ask_put|do_spl_desk_reply|do_spl_ask_close) exit 0 ;;
  *) exit 1 ;;
esac
EOF
# spool-send.sh: the v:1 object into <to>/inbox and <from>/outbox; logs the lease and hold at that instant
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
from="" to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --from) from="$2"; shift 2 ;; --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;;
  --task) task="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
id="$(cat /proc/sys/kernel/random/uuid)"
j="$(jq -n -c --arg i "$id" --arg f "$from" --arg t "$to" --arg k "$kind" --arg ta "$task" --arg b "$body" \
  '{v:1, msg_id:$i, ts:"2026-10-02T05:15:00Z", from:$f, to:$t, kind:$k, task_id:$ta, body:$b}')"
mkdir -p "$SPOOL_ROOT/$to/inbox" "$SPOOL_ROOT/$from/outbox"
echo "$j" >"$SPOOL_ROOT/$to/inbox/$id.json"; echo "$j" >"$SPOOL_ROOT/$from/outbox/$id.json"
echo "send $from -> $to $kind $task [lease=$(cut -d' ' -f1 "$SPOOL_ROOT/dispatch/lease" 2>/dev/null) hold=$(cut -d' ' -f1 "$SPOOL_ROOT/dispatch/rotate.hold" 2>/dev/null)]: $body" >>"$T/send.log"
EOF
cat >"$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >>"$T/kill.log"
case "$1" in -TERM) [ -f "$T/proc/$2/noterm" ] && exit 0 ;; -KILL) [ -f "$T/proc/$2/nokill" ] && exit 0 ;; esac
rm -rf "$T/proc/$2"
EOF
cat >"$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  adopt) echo "adopt $2 $3" >>"$T/ai.log"; echo "$3" >"$T/ai.$2" ;;
  pane-of) p="$(cat "$T/ai.$2" 2>/dev/null)"; [ -n "$p" ] && [ -d "$T/proc/$p" ] || exit 1
    awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "$T/tmux/panes" ;;
esac
EOF
# the pane footer the lease's stall gate reads
cat >"$T/bin/footer" <<'EOF'
#!/usr/bin/env bash
printf '❯ \n'
EOF
# the action, as ./run runs it: set -E and an ERR trap that ends the run
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
do_require_bin() { return 0; }
source "$PROJ_PATH/src/bash/run/spl-dispatch-rotate.func.sh"
do_spl_dispatch_rotate || exit $?
EOF
chmod +x "$T/bin/"*

export T UP TCK PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" LEASE_PANE_CMD="$T/bin/footer" ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" \
  ROTATE_KILL="$T/bin/kill" ROTATE_SEND="$T/bin/send" ROTATE_AI="$T/bin/ai" ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" \
  ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_IDLE_SEC=0 ROTATE_IDLE_GRACE=2 ROTATE_ESC_WAIT=1 ROTATE_START_WAIT=4 \
  ROTATE_ACK_TIMEOUT=6 ROTATE_EXIT_WAIT=2 ROTATE_TERM_WAIT=2 ROTATE_NEW_EXIT_WAIT=2 ROTATE_PROMOTE_WAIT=3 ROTATE_SETTLE=0 ROTATE_SEQ_WAIT=2

# the world: c-902 (pid 102, pane %2) holds the lease, c-903 (pid 103, pane %3) stands by, both 2 h old
world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/"*.log "$T/ack.out" "$T/spawn.mode."* "$T/spawn.kills."* "$T/ack.mode."* "$T/ai."* \
    "$D"/rotate.* "$D/handoff" "$D/lease"* "$S"/c-90*
  echo "$CONF" >"$D/lease.conf"
  mkdir -p "$S/c-902/inbox" "$S/c-902/outbox" "$S/c-903/inbox" "$S/c-903/outbox"
  "$T/bin/proc" 102 c-902 7200; "$T/bin/proc" 103 c-903 7200
  printf '%%2\t102\t$0\tc-902@box > dispatcher\n%%3\t103\t$0\tc-903@box > dispatcher\n' >"$T/tmux/panes"
  echo "c-902 $(date +%s)" >"$D/lease"
  echo '{"v":1,"msg_id":"m1","ts":"2026-10-02T05:10:00Z","from":"HUM-10","to":"c-902","kind":"msg","task_id":"t-owner","body":"owner asks for X"}' >"$S/c-902/inbox/m1.json"
}
act() { env "$@" "$T/bin/act"; }
ctx() { sed -n "s/^$1=//p" "$D/rotate.dispatch.ctx" 2>/dev/null; }
holder() { cut -d' ' -f1 "$D/lease"; }

# --- 1. dry run --------------------------------------------------------------------------
world
act >"$T/o" 2>&1; rc=$?
n=0; for p in GATE HOLD QUIESCE HANDOFF SPAWN ACK RETIRE RELEASE REFRESH DONE; do grep -q " $p PLAN " "$T/o" && n=$((n + 1)); done
[[ $rc -eq 0 && $n == 10 ]] && grep -q ' GATE PLAN pass: c-902 pid 102, 7200s old, pane %2; c-903 pid 103' "$T/o" &&
  pass "1. dry run: one PLAN line per step" || fail "1. dry: rc=$rc n=$n $(cat "$T/o")"
[[ ! -e "$D/rotate.log" && ! -e "$D/rotate.hold" && ! -e "$D/rotate.dispatch.ctx" && ! -e "$T/spawn.log" && ! -e "$T/tmux/log" ]] &&
  pass "1. dry run: nothing written, held, renamed or spawned" || fail "1. the dry run touched something"

# --- 2. gates ---------------------------------------------------------------------------
gate() {  # <want> <label> [env...]
  local want="$1" label="$2"; shift 2
  act DRY_RUN=0 "$@" >"$T/o" 2>&1
  grep -q -- " GATE SKIP $want" "$T/o" && [[ ! -e "$T/spawn.log" && ! -e "$D/rotate.hold" ]] && pass "2. $label" || fail "2. $label: $(cat "$T/o")"
}
world; gate "disabled" "ROTATE=0: SKIP disabled" ROTATE=0
echo 'ROTATE_DISPATCH=0' >"$D/rotate.conf"; gate "disabled" "rotate.conf ROTATE_DISPATCH=0: SKIP disabled (FR-090)"; rm -f "$D/rotate.conf"
world; echo 'LEASE_FLEET=main' >>"$D/lease.conf"; echo "c-902@sat $(date +%s)" >"$D/lease"
gate "standby (dispatch lease: c-902@sat)" "another machine holds the dispatch lease: SKIP standby (FR-044)"
world; rm -rf "$T/proc/102"; "$T/bin/proc" 102 c-902 600; gate "young: c-902 pid 102 is 600s old" "a young master: SKIP young (FR-008)"
world; date +%s >"$D/rotate.dispatch.last"; gate "young: the last rotation" "a rotation less than ROTATE_MIN_AGE ago: SKIP young"
world; printf 'idle\n❯ \nUsage limit reached · resets 7:20am\n' >"$T/tmux/screen.%2"; gate "stalled Usage limit reached" "a stalled master: SKIP stalled (FR-022)"
grep -q 'send c-900 -> c-900 note dispatch-rotate .*ROTATION SKIP stalled' "$T/send.log" && pass "2. ... the orchestrator gets one note" || fail "2. stall note: $(cat "$T/send.log" 2>&1)"
world; "$T/bin/proc" 112 c-902 7200; gate "duplicate: c-902 pids 102 112" "two processes on one id: SKIP duplicate"
world; ( flock 9; sleep 3 ) 9>>"$D/rotate.dispatch.lock" & sleep 0.5; gate "locked" "the lock held: SKIP locked"; wait
# spec 061 L6: c-002 / c-003 pass the id gate (they read "no master + failover pair" before)
world; act DRY_RUN=0 LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 >"$T/o" 2>&1
! grep -q 'no master + failover pair' "$T/o" && pass "2. LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 pass the id gate" || fail "2. c-002/c-003: $(cat "$T/o")"
world; gate "no master + failover pair" "LEASE_MASTER=bogus: SKIP no pair" LEASE_MASTER=bogus
world; echo "20261002T0505Z-orch ACK $(date +%s)" >"$D/rotate.orch.state"; gate "orch-busy (orch rotation at ACK)" "an orch rotation in flight: wait, then SKIP orch-busy (FR-051)"
# a FAILED orch rotation ends at ALERT (the ask + the owner DM): over, not in flight
world; echo "20261002T1505Z-orch ALERT $(date +%s)" >"$D/rotate.orch.state"
act >"$T/o" 2>&1
! grep -q 'orch-busy' "$T/o" && grep -q ' GATE PLAN pass' "$T/o" &&
  pass "2. an orch rotation that ended at ALERT does not hold the dispatchers off" || fail "2. ALERT: $(cat "$T/o")"

# --- 3. T-DISP-HAPPY ------------------------------------------------------------------------
world; cp "$D/lease.conf" "$T/conf.before"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
rid="$(awk '$3 == "GATE" && $4 == "OK" {print $2}' "$D/rotate.log" | sed -n 1p)"; frid="${rid%-master}-failover"
[[ $rc -eq 0 && "$rid" =~ ^[0-9]{8}T[0-9]{4}Z-master$ ]] && grep -q " $rid DONE OK fresh c-902" "$T/o" &&
  pass "3. rotated M and F to DONE ($rid)" || fail "3. rc=$rc $(cat "$T/o") $(cat "$T/ack.out" 2>/dev/null)"
[[ -d "$T/proc/2902" && -d "$T/proc/2903" && ! -d "$T/proc/102" && ! -d "$T/proc/103" ]] &&
  pass "3. fresh c-902 and c-903 under the same ids; the old sessions are gone" || fail "3. procs: $(ls "$T/proc")"
cmp -s "$D/lease.conf" "$T/conf.before" && [[ "$(holder)" == c-902 && ! -e "$D/rotate.hold" ]] &&
  pass "3. lease.conf untouched (I8), the lease back on c-902, no hold left" || fail "3. lease=$(cat "$D/lease") conf: $(cat "$D/lease.conf")"
grep -q 'send c-900 -> c-903 note dispatch-lease \[lease=c-903 hold=c-902\]: DISPATCH LEASE: you are now ACTIVE' "$T/send.log" &&
  grep -q 'send c-900 -> c-902 note dispatch-lease \[lease=c-903 hold=c-902\]: DISPATCH LEASE: STANDBY' "$T/send.log" &&
  pass "3. T-DISP-ONE-HOLDER: F told ACTIVE and M STANDBY while the lease names F and M is held" || fail "3. holder: $(cat "$T/send.log")"
grep -q "send c-900 -> c-902 task dispatch-rotate-$rid .*ROTATION $rid: you are the fresh c-902@box-desk. Read $D/handoff/$rid-c-902.md" "$T/send.log" &&
  grep -q 'brief of c-902: read your inbox' "$D/handoff/$rid-c-902.seed.md" && grep -q "^ACK-COMMAND: .*ROTATE_CMD=ack ROTATE_ID=$rid ./run -a do_spl_dispatch_rotate" "$D/handoff/$rid-c-902.seed.md" &&
  pass "3. the fresh M: seeded with its brief + the ack line, the handoff as an inbox task (FR-026)" || fail "3. seed/task: $(cat "$D/handoff/$rid-c-902.seed.md" 2>&1)"
grep -q "send c-902 -> c-902 result dispatch-rotate-$rid .*ACK rotation $rid: c-902 pid 2902" "$T/send.log" &&
  grep -q "send c-903 -> c-903 result dispatch-rotate-$frid .*ACK rotation $frid: c-903 pid 2903" "$T/send.log" &&
  pass "3. each ack = a result in its own outbox on dispatch-rotate-<rid> (FR-041)" || fail "3. ack: $(cat "$T/send.log") $(cat "$T/ack.out")"
grep -qx "rename %2 c-902-${rid:9:4}Z-retiring" "$T/tmux/log" && grep -q '^keys %2 /exit-clean no-close$' "$T/tmux/log" && grep -qx 'kill %2' "$T/tmux/log" &&
  grep -q '^keys %3 /exit-clean no-close$' "$T/tmux/log" && grep -qx 'kill %3' "$T/tmux/log" &&
  pass "3. old windows renamed retiring, /exit-clean no-close, closed by pane id" || fail "3. tmux: $(cat "$T/tmux/log")"
grep -qx 'adopt c-902 2902' "$T/ai.log" && grep -qx 'adopt c-903 2903' "$T/ai.log" && pass "3. the map adopts each new pid (pokes reach the new pane)" || fail "3. adopt: $(cat "$T/ai.log")"
grep -q "brief of c-903" "$D/handoff/$frid-c-903.seed.md" && grep -q " $frid REFRESH OK c-903 pid 103" "$T/o" &&
  pass "3. REFRESH F after M holds the lease (FR-029)" || fail "3. refresh: $(grep REFRESH "$T/o")"
phases="$(awk -v r="$rid" '$2 == r && !seen[$3]++ {printf "%s ", $3}' "$D/rotate.log")"
[[ "$phases" == "GATE HOLD QUIESCE HANDOFF SPAWN ACK RETIRE CLOSE RELEASE DONE " ]] &&
  pass "3. one log line per phase in rotate.log" || fail "3. phases: $phases"
[[ -f "$S/c-902/inbox/m1.json" && -f "$S/c-902/inbox/m9.json" ]] && grep -q 'owner asks for X' "$D/handoff/$rid-c-902.md" &&
  pass "3. T-MSG-IN-FLIGHT: the inbox kept both messages, the handoff lists the unread one" || fail "3. inbox: $(ls "$S/c-902/inbox")"
[[ -s "$D/rotate.dispatch.last" ]] && grep -q "send c-900 -> c-900 result dispatch-rotate-$rid .*ROTATION DONE" "$T/send.log" &&
  pass "3. DONE: rotate.dispatch.last + a result note to the orchestrator (FR-030)" || fail "3. done"
! grep -q ERRTRAP "$T/o" "$T/ack.out" && pass "3. no stray failing command under the ERR trap" || fail "3. ERRTRAP: $(grep ERRTRAP "$T/o" "$T/ack.out")"
# 2026-10-02: DONE went to the log only, the ctx kept the failover's CLOSE,
# and every later run resumed that instead of rotating
[[ "$(ctx ROTATE_PHASE)" == DONE ]] && pass "3. the ctx ends at DONE" || fail "3. ctx phase: $(ctx ROTATE_PHASE)"
act DRY_RUN=0 >"$T/o" 2>&1
grep -q ' GATE SKIP young' "$T/o" && ! grep -q RESUME "$T/o" &&
  pass "3. the next run gates afresh, no RESUME" || fail "3. next run: $(cat "$T/o")"

# --- 4. T-DISP-ACK-FAIL ----------------------------------------------------------------------
world; echo no >"$T/ack.mode.c-902"
act DRY_RUN=0 ROTATE_ACK_TIMEOUT=2 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q ' FAIL FAIL ACK: no ack within 2s' "$T/o" && [[ -d "$T/proc/102" && ! -d "$T/proc/2902" ]] &&
  pass "4. no ack: the fresh M closed, the old M (pid 102) kept" || fail "4. rc=$rc $(cat "$T/o")"
[[ "$(holder)" == c-902 && ! -e "$D/rotate.hold" ]] && grep -q $'^%2\t102\t$0\tc-902@box > dispatcher$' "$T/tmux/panes" &&
  [[ "$(tail -1 "$T/ai.log")" == "adopt c-902 102" ]] && pass "4. the hold removed, the lease, the window name and the map back on the old M" ||
  fail "4. lease=$(cat "$D/lease") $(cat "$T/tmux/panes")"
grep -q "^do_spl_ask_put ASK_KIND=blocker ASK_FROM=c-902 ASK_TOPIC=dispatch-rotate-" "$T/run.log" && grep -q '^do_spl_desk_reply .*DESK_TO=HUM-10' "$T/run.log" &&
  pass "4. ALERT: one ask + one owner DM (FR-075)" || fail "4. alert: $(cat "$T/run.log")"
[[ ! -e "$T/proc/2903" && -d "$T/proc/103" ]] && ! grep -q REFRESH "$D/rotate.log" && pass "4. no refresh after a failed master" || fail "4. refreshed anyway"

# --- 5. a failed F refresh ------------------------------------------------------------------
world; echo no >"$T/ack.mode.c-903"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && -d "$T/proc/2902" && -d "$T/proc/103" && ! -d "$T/proc/2903" && "$(holder)" == c-902 ]] &&
  grep -q 'DONE WAIT fresh c-902; the c-903 refresh failed' "$T/o" && grep -q "ASK_FROM=c-903 ASK_TOPIC=dispatch-rotate-.*-failover" "$T/run.log" &&
  pass "5. F refresh fails: the old F kept and alerted, M stays fresh" || fail "5. rc=$rc $(cat "$T/o")"

# --- 6. T-DISP-HEAL ----------------------------------------------------------------------------
world; rm -rf "$T/proc/103"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && -d "$T/proc/203" && -d "$T/proc/102" ]] && grep -q 'HEAL OK running again: c-903' "$T/o" &&
  grep -q 'do_spl_dispatch_setup .*DISPATCH_MASTER=c-902' "$T/run.log" && [[ ! -e "$T/spawn.log" && ! -e "$D/rotate.hold" ]] &&
  pass "6. a missing failover: do_spl_dispatch_setup spawns it, nothing else this run (FR-021)" || fail "6. rc=$rc $(cat "$T/o")"

# --- 7. T-DISP-ACK-SOURCE ----------------------------------------------------------------------
world; echo no >"$T/ack.mode.c-902"
( act DRY_RUN=0 ROTATE_ACK_TIMEOUT=5 >"$T/o" 2>&1 ) & sleep 3
rid="$(ctx ROTATE_RID)"
act ROTATE_CMD=ack ROTATE_ID="$rid" ROTATE_CALLER_PID=102 >"$T/a" 2>&1; rc=$?
[[ $rc -eq 3 ]] && grep -q "caller pid '102' is not the new session 2902" "$T/a" && pass "7. an ack from the old pid: exit 3" || fail "7. pid rc=$rc $(cat "$T/a")"
act ROTATE_CMD=ack ROTATE_ID=20000101T0000Z-master ROTATE_CALLER_PID=2902 >"$T/a" 2>&1; rc=$?
[[ $rc -eq 3 ]] && pass "7. an unknown rid: exit 3" || fail "7. rid rc=$rc $(cat "$T/a")"
wait
! grep -q "result dispatch-rotate-$rid" "$T/send.log" && [[ -d "$T/proc/102" ]] && pass "7. ... nothing was sent, the old M kept" || fail "7. a forged ack counted"

# --- 8. T-DISP-HOLD-STALE ------------------------------------------------------------------------
world
able() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" LEASE_PROC_ROOT="$T/proc" LEASE_PANE_CMD="$T/bin/footer" bash -c '
    do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init
    echo "able=[$(spl_lease_agent_able c-902)] why=[$(cat "$LEASE_DIR/able.c-902")]"'
}
echo "c-902 $(date +%s) 20261002T0515Z-master" >"$D/rotate.hold"
[[ "$(able)" == "able=[] why=[held: rotation since "* ]] && pass "8. a held master is not able (renew, watch, fleet candidate skip it)" || fail "8. gate: $(able)"
echo "c-903 $(date +%s)" >"$D/rotate.hold"
[[ "$(able)" == "able=[102] why=[able]" ]] && pass "8. a hold on another id leaves the master able" || fail "8. other: $(able)"
echo "c-902 $(( $(date +%s) - 4000 )) x" >"$D/rotate.hold"; able >/dev/null
[[ "$(able)" == "able=[102] why=[able]" && "$(grep -c 'rotate.hold on c-902 is .* ignored' "$D/lease.log")" == 1 ]] &&
  pass "8. a hold older than ROTATE_HOLD_MAX is ignored, logged once (FR-024)" || fail "8. stale: $(able) $(cat "$D/lease.log" 2>&1)"

# --- 9. resume + abort -----------------------------------------------------------------------------
# a run killed at ACK: rebuild that state by hand (old 102 + new 2902, hold, ctx ACK)
at_ack() {
  world; echo no >"$T/ack.mode.c-902"
  act DRY_RUN=0 ROTATE_ACK_TIMEOUT=1 >/dev/null 2>&1
  rid="$(ctx ROTATE_RID)"
  "$T/bin/proc" 2902 c-902 0; printf '%%2902\t2902\t$0\tc-902@box\n' >>"$T/tmux/panes"; echo 2902 >"$T/ai.c-902"
  echo "c-902 $(date +%s) $rid" >"$D/rotate.hold"; echo "c-903 $(date +%s)" >"$D/lease"
  sed -i 's/^ROTATE_PHASE=.*/ROTATE_PHASE=ACK/; s/^ROTATE_NEW_PID=.*/ROTATE_NEW_PID=2902/; s/^ROTATE_NEW_PANE=.*/ROTATE_NEW_PANE=%2902/' "$D/rotate.dispatch.ctx"
}
at_ack
act ROTATE_CMD=abort DRY_RUN=0 >"$T/o" 2>&1
grep -q ' ABORT ABORT at ACK by hand' "$T/o" && [[ ! -d "$T/proc/2902" && -d "$T/proc/102" && ! -e "$D/rotate.hold" && "$(holder)" == c-902 ]] &&
  pass "9. abort (FR-091): the new one closed, the hold removed, the old M keeps the lease" || fail "9. abort: $(cat "$T/o") lease=$(cat "$D/lease")"
at_ack
"$T/bin/send" --from c-902 --to c-902 --kind result --task "dispatch-rotate-$rid" --body ack
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q " RESUME OK from ACK (old alive=1, new alive=1)" "$T/o" && [[ ! -d "$T/proc/102" && "$(holder)" == c-902 && ! -e "$D/rotate.hold" ]] &&
  grep -q " $rid DONE OK" "$T/o" && pass "9. resumed at ACK with its ack on disk: retired, released, refreshed, DONE (FR-003)" || fail "9. resume rc=$rc $(cat "$T/o")"
# the live shape of 2026-10-02 13:15Z: a ctx left at the failover's CLOSE
# (old gone, new alive) is closed once, ends at DONE, and is not resumed again
world; "$T/bin/proc" 2903 c-903 0; printf '%%2903\t2903\t$0\tc-903@box\n' >>"$T/tmux/panes"; echo 2903 >"$T/ai.c-903"
rm -rf "$T/proc/103"; date +%s >"$D/rotate.dispatch.last"
printf 'ROTATE_RID=20261002T1100Z-failover\nROTATE_PHASE=CLOSE\nROTATE_OLD_PID=103\nROTATE_OLD_PANE=%%3\nROTATE_NEW_PID=2903\nROTATE_NEW_PANE=%%2903\n' >"$D/rotate.dispatch.ctx"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(ctx ROTATE_PHASE)" == DONE ]] && grep -q ' RESUME OK from CLOSE (old alive=0, new alive=1)' "$T/o" &&
  pass "9. a failover left at CLOSE: resumed once, the ctx ends at DONE" || fail "9. CLOSE resume rc=$rc phase=$(ctx ROTATE_PHASE) $(cat "$T/o")"
act DRY_RUN=0 >"$T/o" 2>&1
! grep -q RESUME "$T/o" && grep -q ' GATE ' "$T/o" &&
  pass "9. ... and the next run gates afresh" || fail "9. resumed again: $(cat "$T/o")"

# --- 10. T-CRON ---------------------------------------------------------------------------------
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/dispatch-rotate-cron.sh" "$SRC/csi-spl-orc/src/bash/scripts/"
printf '5 * * * * x # csi-spl:orch-rotate\n' >"$T/crontab"
cron() {
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" ROTATE_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-rotate-install-cron.func.sh"
    do_spl_dispatch_rotate_install_cron'
}
before="$(md5sum <"$T/crontab")"
cron >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q '^    +15 \* \* \* \* .*dispatch-rotate-cron.sh >> .*/cron.out 2>&1 # csi-spl:dispatch-rotate$' "$T/o" &&
  pass "10. dry run: the diff, nothing written" || fail "10. dry: rc=$rc $(cat "$T/o")"
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
want="15 * * * * $SRC/csi-spl-orc/src/bash/scripts/dispatch-rotate-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:dispatch-rotate"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'orch-rotate' "$T/crontab" &&
  pass "10. DRY_RUN=0: one exact line at :15, the orch line kept" || fail "10. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cron DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -c '# csi-spl:dispatch-rotate$' "$T/crontab")" == 1 ]] && pass "10. idempotent" || fail "10. lines: $(cat "$T/crontab")"
cron ROTATE_CRON_ACTION=check >"$T/o" 2>&1 && pass "10. check passes once installed" || fail "10. check: $(cat "$T/o")"
cron CRON_REMOVE=1 DRY_RUN=0 >/dev/null 2>&1
! grep -q 'dispatch-rotate' "$T/crontab" && grep -q 'orch-rotate' "$T/crontab" && pass "10. CRON_REMOVE=1 takes only its line (FR-092)" || fail "10. remove: $(cat "$T/crontab")"
cron DRY_RUN=0 >/dev/null 2>&1
hwant="1-59/3 * * * * $SRC/csi-spl-orc/src/bash/scripts/dispatch-rotate-cron.sh --heal >> $T/log/heal.out 2>&1 # csi-spl:dispatch-heal"
grep -qxF "$hwant" "$T/crontab" && [[ "$(grep -c '# csi-spl:dispatch-heal$' "$T/crontab")" == 1 ]] &&
  pass "10. the heal line: every 3 min, never at :15 (one lock), idempotent" || fail "10. heal line: $(cat "$T/crontab")"
cron DRY_RUN=0 ROTATE_CRON_MINUTE=0 ROTATE_HEAL_CRON_EVERY=5 >/dev/null 2>&1
grep -q '^1-59/5 .* --heal >> .* # csi-spl:dispatch-heal$' "$T/crontab" && [[ "$(grep -c '# csi-spl:dispatch-heal$' "$T/crontab")" == 1 ]] &&
  pass "10. ROTATE_HEAL_CRON_EVERY=5 at :00 -> 1-59/5, replaced in place" || fail "10. every 5: $(cat "$T/crontab")"
cron DRY_RUN=0 ROTATE_HEAL_CRON_EVERY=0 >/dev/null 2>&1
! grep -q 'dispatch-heal' "$T/crontab" && grep -q '# csi-spl:dispatch-rotate$' "$T/crontab" &&
  pass "10. ROTATE_HEAL_CRON_EVERY=0 drops only the heal line" || fail "10. every 0: $(cat "$T/crontab")"
cron DRY_RUN=0 ROTATE_HEAL_CRON_EVERY=1 >"$T/o" 2>&1 && fail "10. ROTATE_HEAL_CRON_EVERY=1 accepted" || pass "10. ROTATE_HEAL_CRON_EVERY=1 refused"
cron DRY_RUN=0 >/dev/null 2>&1; cron CRON_REMOVE=1 DRY_RUN=0 >/dev/null 2>&1
! grep -q 'dispatch-' "$T/crontab" && grep -q 'orch-rotate' "$T/crontab" && pass "10. CRON_REMOVE=1 takes the heal line too" || fail "10. remove heal: $(cat "$T/crontab")"
printf '#!/usr/bin/env bash\necho "run $* ROTATE_CMD=$ROTATE_CMD DRY_RUN=$DRY_RUN"\n' >"$SRC/csi-spl-orc/run"; chmod +x "$SRC/csi-spl-orc/run"
bash "$SRC/csi-spl-orc/src/bash/scripts/dispatch-rotate-cron.sh" --heal >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'run -a do_spl_dispatch_rotate ROTATE_CMD=heal DRY_RUN=0' "$T/o" && grep -q 'START dispatcher heal' "$T/o" &&
  pass "10. the cron script --heal runs ROTATE_CMD=heal DRY_RUN=0" || fail "10. --heal: rc=$rc $(cat "$T/o")"
bash "$SRC/csi-spl-orc/src/bash/scripts/dispatch-rotate-cron.sh" >"$T/o" 2>&1
grep -q 'ROTATE_CMD=auto DRY_RUN=0' "$T/o" && pass "10. ... and without it the rotation (ROTATE_CMD=auto)" || fail "10. auto: $(cat "$T/o")"
ROTATE_CRON_TOOLS=no-such-tool-x bash "$SRC/csi-spl-orc/src/bash/scripts/dispatch-rotate-cron.sh" --check-tools >"$T/o" 2>&1
[[ $? -eq 3 ]] && grep -q 'no-such-tool-x' "$T/o" && pass "10. the cron script names a missing tool (exit 3)" || fail "10. tools: $(cat "$T/o")"

# --- 11. ROTATE_CMD=heal ------------------------------------------------------------------------
heal() { act DRY_RUN=0 ROTATE_CMD=heal ROTATE_HEAL_CONFIRM=0 "$@"; }
nsetup() { local n; n="$(grep -c '^do_spl_dispatch_setup ' "$T/run.log" 2>/dev/null)"; echo "${n:-0}"; }
world; rm -rf "$T/proc/103"
heal >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && -d "$T/proc/203" && -d "$T/proc/102" && "$(nsetup)" == 1 ]] &&
  grep -qE '^[0-9T:-]+Z [0-9]{8}T[0-9]{4}Z-master HEAL WAIT no live process: c-903 ' "$D/rotate.log" &&
  grep -qE '^[0-9T:-]+Z [0-9]{8}T[0-9]{4}Z-master HEAL OK running again: c-903$' "$D/rotate.log" &&
  pass "11. dead failover: healed, HEAL WAIT + OK in rotate.log (the rotation's format)" || fail "11. dead: rc=$rc $(cat "$T/o") $(cat "$D/rotate.log" 2>&1)"
[[ ! -e "$T/spawn.log" && ! -e "$D/rotate.hold" && ! -e "$D/rotate.dispatch.last" && "$(holder)" == c-902 && ! -e "$T/tmux/log" ]] &&
  pass "11. ... and nothing rotated: no spawn, hold, rename or .last, the lease kept" || fail "11. rotated: $(ls "$D")"
world; rm -rf "$T/proc/102"
heal >"$T/o" 2>&1
grep -q 'HEAL WAIT no live process: c-902 ' "$D/rotate.log" && grep -q 'DISPATCH_MASTER=c-902' "$T/run.log" &&
  pass "11. dead master: do_spl_dispatch_setup runs for it" || fail "11. master: $(cat "$T/o")"
world
heal >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(nsetup)" == 0 && ! -e "$D/rotate.log" ]] && grep -q ' HEAL SKIP both alive' "$T/o" &&
  pass "11. both alive: untouched, nothing in rotate.log" || fail "11. alive: rc=$rc $(cat "$T/o")"
world; printf 'idle\n❯ \nUsage limit reached · resets 7:20am\n' >"$T/tmux/screen.%2"
heal LEASE_PANE_CMD="$T/bin/footer" >"$T/o" 2>&1
[[ "$(nsetup)" == 0 && -d "$T/proc/102" && ! -e "$T/proc/202" ]] && grep -q ' HEAL SKIP both alive' "$T/o" &&
  pass "11. a live master on a usage-limit pane: untouched (no second process on its id)" || fail "11. stalled: $(cat "$T/o")"
world; rm -rf "$T/proc/103"
( sleep 1; "$T/bin/proc" 103 c-903 7200 ) &
heal ROTATE_HEAL_CONFIRM=3 >"$T/o" 2>&1; wait
[[ "$(nsetup)" == 0 && ! -d "$T/proc/203" ]] && grep -q ' HEAL SKIP back within 3s' "$T/o" &&
  pass "11. dead at one look, back within ROTATE_HEAL_CONFIRM: untouched" || fail "11. confirm: $(cat "$T/o")"
world; rm -rf "$T/proc/103"
heal SETUP_SLEEP=3 >"$T/o1" 2>&1 & sleep 0.5
heal SETUP_SLEEP=3 >"$T/o2" 2>&1; wait
[[ "$(nsetup)" == 1 && "$(grep -c 'HEAL OK' "$D/rotate.log")" == 1 ]] && grep -q ' HEAL SKIP locked' "$T/o2" &&
  pass "11. two heals at once: one heals, the other SKIP locked" || fail "11. concurrent: $(nsetup) $(cat "$T/o1" "$T/o2")"
world; rm -rf "$T/proc/103"; ( flock 9; sleep 3 ) 9>>"$D/rotate.dispatch.lock" & sleep 0.5
heal >"$T/o" 2>&1; wait
[[ "$(nsetup)" == 0 ]] && grep -q ' HEAL SKIP locked' "$T/o" && pass "11. a rotation holding the lock: no heal" || fail "11. rotation lock: $(cat "$T/o")"
world; rm -rf "$T/proc/103"; printf 'ROTATE_RID=20261002T1100Z-master\nROTATE_PHASE=ACK\n' >"$D/rotate.dispatch.ctx"
heal >"$T/o" 2>&1
[[ "$(nsetup)" == 0 ]] && grep -q ' HEAL SKIP rotation 20261002T1100Z-master in flight at ACK' "$T/o" &&
  pass "11. a rotation in flight (ctx): no heal" || fail "11. in flight: $(cat "$T/o")"
world; rm -rf "$T/proc/103"; echo 'ROTATE_HEAL=0' >"$D/rotate.conf"
heal >"$T/o" 2>&1; rm -f "$D/rotate.conf"
[[ "$(nsetup)" == 0 ]] && grep -q ' HEAL SKIP disabled' "$T/o" && pass "11. rotate.conf ROTATE_HEAL=0: off" || fail "11. off: $(cat "$T/o")"
world; rm -rf "$T/proc/103"
act ROTATE_CMD=heal ROTATE_HEAL_CONFIRM=0 >"$T/o" 2>&1
[[ "$(nsetup)" == 0 && ! -e "$D/rotate.log" ]] && grep -q ' HEAL PLAN do_spl_dispatch_setup spawns: c-903' "$T/o" &&
  pass "11. dry run: HEAL PLAN, nothing spawned or logged" || fail "11. dry: $(cat "$T/o")"
! grep -q ERRTRAP "$T/o" "$T/o1" "$T/o2" && pass "11. no stray failing command under the ERR trap" || fail "11. ERRTRAP"

# --- 12. RELEASE on a standby box (20261006T1315Z-master on sat) ---------------------------------
# the live shape: RETIRE OK (old 102 gone, new 2902 alive), the ctx at RELEASE,
# the fleet lease moved to another machine mid-rotation
at_release() {  # <lease holder>
  world; echo 'LEASE_FLEET=main' >>"$D/lease.conf"; echo "$1 $(date +%s)" >"$D/lease"
  rm -rf "$T/proc/102"; "$T/bin/proc" 2902 c-902 0; printf '%%2902\t2902\t$0\tc-902@box\n' >>"$T/tmux/panes"; echo 2902 >"$T/ai.c-902"
  date +%s >"$D/rotate.dispatch.last"
  printf 'ROTATE_RID=20261006T1315Z-master\nROTATE_PHASE=RELEASE\nROTATE_OLD_PID=102\nROTATE_OLD_PANE=%%2\nROTATE_NEW_PID=2902\nROTATE_NEW_PANE=%%2902\n' >"$D/rotate.dispatch.ctx"
}
at_release c-903@box-main
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(ctx ROTATE_PHASE)" == DONE ]] && grep -q ' RELEASE SKIP standby (lease c-903@box-main)' "$T/o" &&
  grep -q ' DONE OK fresh c-902 pid 2902; standby (lease c-903@box-main)' "$T/o" &&
  pass "12. the fleet lease on another machine: RELEASE SKIP standby, the ctx ends DONE" || fail "12. standby rc=$rc phase=$(ctx ROTATE_PHASE) $(cat "$T/o")"
! grep -qE '^do_spl_(ask_put|desk_reply) ' "$T/run.log" 2>/dev/null && ! grep -q 'ALERT' "$T/o" && ! grep -q 'ROTATION DONE' "$T/send.log" 2>/dev/null &&
  ! grep -q REFRESH "$T/o" && pass "12. ... no ask, no owner DM, no refresh, no DONE note" || fail "12. alerted: $(cat "$T/run.log" "$T/o" 2>&1)"
act DRY_RUN=0 >"$T/o" 2>&1
! grep -q RESUME "$T/o" && ! grep -q ALERT "$T/o" && pass "12. ... and the next run does not RESUME or alert again" || fail "12. resumed: $(cat "$T/o")"
# control: the lease on THIS machine with the wrong holder still FAILs, and
# the alert names the new pid, never "old session kept" for a retired one
at_release c-903@box-desk
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q ' RELEASE FAIL the lease is still c-903@box-desk' "$T/o" && ! grep -q 'RELEASE SKIP' "$T/o" &&
  grep -q '^do_spl_ask_put .*ASK_SUMMARY=ROTATION FAILED master RELEASE .*old session retired (pid 102); new session: c-902@box-desk pid 2902' "$T/run.log" &&
  ! grep -q 'old session kept' "$T/run.log" &&
  pass "12. control: the lease here on the wrong holder FAILs, the alert names the new pid" || fail "12. control rc=$rc $(cat "$T/o") $(cat "$T/run.log" 2>&1)"
! grep -q ERRTRAP "$T/o" && pass "12. no stray failing command under the ERR trap" || fail "12. ERRTRAP: $(grep ERRTRAP "$T/o")"

# --- 13. the fresh M dies during the F refresh (20261007T0915Z-master) ---------------------
# live: the old c-002's /exit-clean deferred close resolved --agent c-002 to
# the NEW window and killed it at 09:22:21Z, mid-refresh; DONE still logged
# "DONE OK fresh c-002" and told the orchestrator it held the lease
world; echo "2902 c-903" >"$T/spawn.kills.c-903"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
rid="$(awk '$3 == "GATE" && $4 == "OK" {print $2}' "$D/rotate.log" | sed -n 1p)"
[[ $rc -ne 0 && ! -d "$T/proc/2902" && "$(ctx ROTATE_PHASE)" == DONE ]] &&
  grep -q " $rid DONE FAIL fresh c-902 pid 2902 gone before DONE (the lease is c-903)" "$T/o" && ! grep -q " $rid DONE OK" "$T/o" &&
  pass "13. the fresh M gone at DONE: DONE FAIL names the pid and the lease, the ctx ends DONE" || fail "13. rc=$rc phase=$(ctx ROTATE_PHASE) $(cat "$T/o")"
grep -q "send c-900 -> c-900 result dispatch-rotate-$rid .*ROTATION DONE $rid on box-desk, NOT healthy: the fresh c-902 pid 2902 gone" "$T/send.log" &&
  ! grep -q 'holds the dispatch lease' "$T/send.log" &&
  pass "13. ... the orchestrator is told NOT healthy, never 'holds the dispatch lease'" || fail "13. note: $(grep ROTATION "$T/send.log")"
act DRY_RUN=0 >"$T/o" 2>&1
! grep -q RESUME "$T/o" && pass "13. ... and the next run does not RESUME" || fail "13. resumed: $(cat "$T/o")"
# alive, but the lease left it during the refresh: DONE WAIT, not OK
world; echo "0 c-903" >"$T/spawn.kills.c-903"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && -d "$T/proc/2902" ]] && grep -q ' DONE WAIT fresh c-902 pid 2902 alive, but the lease is c-903' "$T/o" &&
  pass "13. the fresh M alive but off the lease: DONE WAIT, not OK" || fail "13. lease: rc=$rc $(cat "$T/o")"
! grep -q ERRTRAP "$T/o" && pass "13. no stray failing command under the ERR trap" || fail "13. ERRTRAP: $(grep ERRTRAP "$T/o")"

# --- 14. a dialog on the fresh M fails the start at once -------------------------------------
world; printf '  Settings Warning\n  ❯ 1. Continue\n    2. Fix with Claude\n' >"$T/tmux/screen.%2902"
t0=$SECONDS; act DRY_RUN=0 ROTATE_ACK_TIMEOUT=30 >"$T/o" 2>&1; rc=$?; took=$((SECONDS - t0))
[[ $rc -ne 0 && $took -lt 25 ]] && grep -q " FAIL FAIL SPAWN: the new session in %2902 is stopped on a 'Settings Warning' dialog" "$T/o" &&
  ! grep -q ' ACK WAIT ' "$T/o" && pass "14. Settings Warning on the fresh M: FAIL SPAWN at once (${took}s, ack window 30s), named" ||
  fail "14. rc=$rc took=${took}s $(cat "$T/o")"
[[ -d "$T/proc/102" && "$(holder)" == c-902 && ! -e "$D/rotate.hold" ]] && grep -qx 'kill %2902' "$T/tmux/log" &&
  grep -q "^do_spl_ask_put .*ASK_FROM=c-902 .*ASK_SUMMARY=ROTATION FAILED master SPAWN the new session in %2902 is stopped on a 'Settings Warning'" "$T/run.log" &&
  grep -q '^do_spl_desk_reply .*DESK_TO=HUM-10' "$T/run.log" &&
  pass "14. ... the old M keeps the role and the lease, the new window closed, ALERT = ask + owner DM" || fail "14. after: $(cat "$T/run.log") $(cat "$T/tmux/log")"
! grep -qE '^keys %2902 (Enter|1)$' "$T/tmux/log" && pass "14. ... nothing answered the dialog (no Enter, no 1)" || fail "14. keys: $(grep '%2902' "$T/tmux/log")"
world; act DRY_RUN=0 >"$T/o" 2>&1
! grep -q 'FAIL SPAWN' "$T/o" && grep -q ' ACK OK acked by pid 2902' "$T/o" &&
  pass "14. control: a plain screen on the fresh M is not failed at SPAWN" || fail "14. control: $(cat "$T/o")"

# --- 15. recovered -------------------------------------------------------------------------
world; rm -f "$T/run2.log"; mkdir -p "$S/c-902/lifetime"
echo "0e5a2c1b-1111-4222-8333-944455556666 20261007T1715Z-master ACK" >"$S/c-902/lifetime/alerts.open"
act DRY_RUN=0 >"$T/o" 2>&1
rid="$(awk '$3 == "GATE" && $4 == "OK" {print $2}' "$D/rotate.log" | sed -n 1p)"
grep -q "^do_spl_ask_close ASK_ID=0e5a2c1b-1111-4222-8333-944455556666 ASK_STATE=done .*BODY=c-902@box-desk recovered at [0-9T:-]*Z by rotation $rid, now pid 2902\$" "$T/run2.log" &&
  grep -q "^do_spl_desk_reply ASK_ID= ASK_STATE= DESK_TASK=0e5a2c1b-1111-4222-8333-944455556666 DESK_KIND=note BODY=c-902@box-desk recovered at [0-9T:-]*Z by rotation $rid, now pid 2902\$" "$T/run2.log" &&
  [[ "$(grep -c 'recovered at' "$T/run2.log")" == 2 && ! -e "$S/c-902/lifetime/alerts.open" ]] &&
  grep -q " $rid RECOVERED OK ask 0e5a2c1b of 20261007T1715Z-master closed" "$D/rotate.log" &&
  pass "15. an open alert + an ACK OK: the ask closed, one recovered line to the owner on its thread, the file gone" || fail "15. $(cat "$T/run2.log") $(grep RECOVERED "$D/rotate.log")"
world; rm -f "$T/run2.log"; act DRY_RUN=0 >"$T/o" 2>&1
! grep -q 'do_spl_ask_close\|recovered at' "$T/run2.log" && ! grep -q RECOVERED "$D/rotate.log" &&
  pass "15. control: no open alert, no ask close and no line" || fail "15. control: $(cat "$T/run2.log")"
# a failed rotation's alert is recorded for the next healthy start
world; echo no >"$T/ack.mode.c-902"; act DRY_RUN=0 ROTATE_ACK_TIMEOUT=2 >"$T/o" 2>&1
grep -qE '^[0-9a-f-]{36} [0-9]{8}T[0-9]{4}Z-master ACK$' "$S/c-902/lifetime/alerts.open" &&
  pass "15. a FAIL alert is recorded in <id>/lifetime/alerts.open" || fail "15. alerts.open: $(cat "$S/c-902/lifetime/alerts.open" 2>&1)"
! grep -q ERRTRAP "$T/o" && pass "15. no stray failing command under the ERR trap" || fail "15. ERRTRAP: $(grep ERRTRAP "$T/o")"

echo
(( fails == 0 )) && { echo "dispatch-rotate: all passed"; exit 0; }
echo "dispatch-rotate: $fails failure(s)"; exit 1
