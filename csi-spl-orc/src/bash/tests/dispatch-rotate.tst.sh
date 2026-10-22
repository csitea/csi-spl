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
#      ROTATE_HOLD_MAX ignored with one WARN (FR-023, FR-024); a hold whose
#      rotation is dead (written before the boot, its pid gone) removed at
#      once. Control: a live rotation's hold still holds
#   9. resume (FR-003) and abort (FR-091); SPL-1837: a GATE left by a gone
#      run = ABORT STALE, hold removed, no FAIL/alert, a new rotation;
#      control: its run alive = SKIP
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
#      alert -> no ask close, no line. SPL-1890: ask close exit 3 (closed
#      first by the orchestrator) = RECOVERED OK "already closed"; control:
#      any other exit = FAIL with its code
#  16. the seed's workspace list is the live pinned desks at write time, not
#      the stale list the brief was rendered with (dsk-b missed, 2026-10-10):
#      test and other-box desks left out; a desk pinned after a rotation is in
#      the next seed with no code change. Control: no pinned desk -> the
#      brief's own list stays
#  17. T-ROLE-VENDOR: ROTATE_ROLE_VENDOR=grok (env or rotate.conf) = grok in
#      the SPAWN plan of the master and the failover; empty = today's lines;
#      no grok CLI (lane-mix) or a lease that counts only claude = claude, the
#      reason named; grok M and F ack from their first prompt and hold the
#      seats; a grok M with no ack: the old claude M keeps the role and lease
#  18. T-ROLE-ID-FOLLOWS-VENDOR (SPL-1685): knob on, grok seats: c-002 ->
#      g-002 and c-003 -> g-003 through the real role-seat-switch.sh;
#      lease.conf names g-002 / g-003, the lease comes back to g-002, the old
#      ids link to the live dirs (a message sent to c-002 lands in g-002's
#      inbox), the seed reads the c-00N brief as g-00N; back to claude: g-002
#      -> c-002 reads c-002's brief; a grok M with no ack: lease.conf, the
#      hold and the dirs back to c-002, the old M keeps the lease
#  19. T-STANDBY-SWAP (SPL-1777): the dispatch lease on another machine and
#      g-002's vendor out (watchdog S2 kind=limit): g-002 -> c-002 by the
#      guard's vendor, g-003 (healthy) untouched, the lease file unchanged, no
#      hold, release, refresh or lease note; the same through the heal cron.
#      Controls: a dry run plans it and moves nothing; the guard picking the
#      dead vendor again = no replacement, the reason logged; a verdict older
#      than the seat's process, or a healthy seat = GATE SKIP standby
#      SPL-1869: claude seats under ROTATE_ROLE_VENDOR=claude, one on its
#      limit = the grok standby; control: ROTATE_GROK_STANDBY=0 = no swap
#  20. SPL-1837: a run inside the master or the failover pane re-runs itself
#      detached (setsid), both locks let go first, no hold; a detached run
#      still inside refuses (no loop); control: a run outside rotates
#  21. SPL-1890: a failover on a fresh watchdog HIT = GATE SKIP failover not
#      able, no hold, no spawn, no ask/DM, one orchestrator note (not twice);
#      the dry run shows it. Controls: an old HIT or an OK verdict rotates
#  22. SPL-2555: spl_rotate_grok_out judges the NEWEST grok verdict across
#      seats: g-178 on its limit 3 days ago, g-002 clean 1 h ago = grok not
#      out. Controls: the newest across seats a limit = out; one seat alone
#      on its limit = out; a tie (same second) with a limit = out
#  23. SPL-2899 (B): the fleet lease moves to another box during HOLD = HOLD
#      SKIP standby, no ask, no resume. Control: it stays here = FAIL HOLD
#  24. SPL-2899 (C): a fresh fleet.dispatch.hub-down = GATE SKIP hub-down, no
#      hold, no ask. Control: a marker older than LEASE_STALE rotates
#  25. SPL-2899 (F): a grok master, the lease kept on an able claude failover
#      = RELEASE SKIP vendor rank, DONE, no ask. Controls: the failover not
#      able, or no better vendor = RELEASE FAIL + ask
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
# proc <pid> <id> <age-s> [comm]: a fake claude (or comm) carrying SPOOL_AGENT_ID=<id>
cat >"$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo "${4:-claude}" >"$d/comm"
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
# the head of the first prompt (spawn-core SPAWN_PROMPT_HEAD_FILE), as passed
[ -n "${SPAWN_PROMPT_HEAD_FILE:-}" ] && cp "$SPAWN_PROMPT_HEAD_FILE" "$T/head.$id"
mode="$(cat "$T/spawn.mode.$id" 2>/dev/null || echo ok)"
[ "$mode" = nopane ] && { echo "spawn-window: no pane"; exit 4; }
printf '%s\t%s\t$0\t%s@box\n' "$pane" "$pid" "$id" >>"$T/tmux/panes"
[ "$mode" = nostart ] || "$T/bin/proc" "$pid" "$id" 0 "$1"
# spawn.kills.<id> "<pid> <lease>": that pid dies and the lease moves as this
# spawn runs (20261007T0915Z: the fresh master's window closed mid-refresh)
if [ -f "$T/spawn.kills.$id" ]; then read -r kp kl <"$T/spawn.kills.$id"; rm -rf "$T/proc/$kp"; echo "$kl $(date +%s)" >"$SPOOL_ROOT/dispatch/lease"; fi
echo '{"v":1,"msg_id":"m9","ts":"2026-10-02T05:16:00Z","from":"HUM-10","to":"c-902","kind":"msg","task_id":"y","body":"mid-rotation"}' >"$SPOOL_ROOT/c-902/inbox/m9.json"
if [ "$(cat "$T/ack.mode.$id" 2>/dev/null || echo yes)" = yes ]; then
  # a claude reads its seed; any other vendor ONLY its first prompt (the head)
  src="$4"; [ "$1" = claude ] || src="$T/head.$id"
  rid="$(grep '^ACK-COMMAND:' "$src" | grep -oE 'ROTATE_ID=[0-9A-Za-z-]+' | cut -d= -f2)"
  touch "$T/ack.pending.$id"
  ( sleep 0.05; ROTATE_CMD=ack ROTATE_ID="$rid" ROTATE_CALLER_PID="$pid" "$T/bin/act" >>"$T/ack.out" 2>&1; rm -f "$T/ack.pending.$id" ) >/dev/null 2>&1 &
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
  do_spl_ask_put|do_spl_desk_reply|do_spl_fleet_notice) exit 0 ;;
  do_spl_ask_close) exit "$(cat "$T/askclose.rc" 2>/dev/null || echo 0)" ;;
  do_spl_lane_mix) echo "LANE_MIX_KIND=${LANE_MIX_KIND:-} LANE_MIX_SPLIT_KIND=${LANE_MIX_SPLIT_KIND:-}" >>"$T/mix.log"; cat "$T/mix.out" 2>/dev/null ;;
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
# the action, as ./run runs it: set -E and an ERR trap that ends the run.
# The clock seam (test round 1 row 05, as row 01 in orch-rotate.tst.sh): every
# wait loop of the rotate libs reads $SECONDS and sleeps, so `sleep N` here
# adds N to $SECONDS and to the ledger $T/vclock (one line of ms per sleep,
# any subshell) and really sleeps only ROTATE_TEST_TICK s (the ack command,
# ROTATE_CMD=ack, 0.1 s): a 6 s ack timeout still trips after 6 s of this
# clock. While a fake session's ack is in flight ($T/ack.pending.<id>) the
# clock stands still (0.05 s real ticks), as for a session that answers at
# once; at most 500 such ticks per process. ROTATE_TEST_REAL=1: real
# seconds, for a case racing a real-time peer (7, 11 confirm).
cat >"$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
VCLOCK_MS=0 VCLOCK_HELD=0
sleep() {
  local n="${1:-1}" ms int frac tick="${ROTATE_TEST_TICK:-0.01}" p
  [[ "${ROTATE_TEST_REAL:-0}" == 1 ]] && { command sleep "$n"; return 0; }
  [[ "${ROTATE_CMD:-}" == ack ]] && tick=0.1
  if [[ "${ROTATE_CMD:-}" != ack ]] && (( VCLOCK_HELD < 500 )); then
    for p in "$T"/ack.pending.*; do
      [[ -e "$p" ]] && { VCLOCK_HELD=$((VCLOCK_HELD + 1)); command sleep 0.05; return 0; }
    done
  fi
  int="${n%%.*}" frac=000; [[ "$n" == *.* ]] && frac="${n#*.}000"
  ms=$(( 10#${int:-0} * 1000 + 10#${frac:0:3} ))
  echo "$ms" >>"$T/vclock"
  VCLOCK_MS=$((VCLOCK_MS + ms)); SECONDS=$((SECONDS + VCLOCK_MS / 1000)); VCLOCK_MS=$((VCLOCK_MS % 1000))
  command sleep "$tick"
}
do_log() { echo "$*"; }
do_require_bin() { return 0; }
source "$PROJ_PATH/src/bash/run/spl-dispatch-rotate.func.sh"
do_spl_dispatch_rotate || exit $?
EOF
chmod +x "$T/bin/"*

export T UP TCK PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPL_STATE_DIR="$T/state" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk \
  LEASE_PROC_ROOT="$T/proc" LEASE_PANE_CMD="$T/bin/footer" ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" \
  ROTATE_KILL="$T/bin/kill" ROTATE_SEND="$T/bin/send" ROTATE_AI="$T/bin/ai" ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" \
  ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_IDLE_SEC=0 ROTATE_IDLE_GRACE=2 ROTATE_ESC_WAIT=1 ROTATE_START_WAIT=4 \
  ROTATE_ACK_TIMEOUT=6 ROTATE_EXIT_WAIT=2 ROTATE_TERM_WAIT=2 ROTATE_NEW_EXIT_WAIT=2 ROTATE_PROMOTE_WAIT=3 ROTATE_SETTLE=0 ROTATE_SEQ_WAIT=2

# the world: c-902 (pid 102, pane %2) holds the lease, c-903 (pid 103, pane %3) stands by, both 2 h old
world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/"*.log "$T/ack.out" "$T/ack.pending."* "$T/vclock" "$T/spawn.mode."* "$T/spawn.kills."* "$T/ack.mode."* "$T/ai."* "$T/head."* "$T/mix.out" \
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
# T-DISP-ACK-HEAD: the ack line is in the first prompt, not only behind the
# seed pointer (the lane fix aa6604b37, for the role seats)
grep -q "^ACK-COMMAND: .*ROTATE_CMD=ack ROTATE_ID=$rid ./run -a do_spl_dispatch_rotate\$" "$T/head.c-902" 2>/dev/null &&
  grep -q "^ACK-COMMAND: .*ROTATE_CMD=ack ROTATE_ID=$frid ./run -a do_spl_dispatch_rotate\$" "$T/head.c-903" 2>/dev/null &&
  grep -q "^ROTATION $rid: you are the new c-902 session" "$T/head.c-902" &&
  pass "3. T-DISP-ACK-HEAD: the spawns of M and F get a head file holding their ACK-COMMAND" || fail "3. T-DISP-ACK-HEAD: $(cat "$T/head.c-902" "$T/head.c-903" 2>&1)"
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
grep -q "^do_spl_ask_put ASK_KIND=blocker ASK_FROM=c-902 ASK_TOPIC=dispatch-rotate-" "$T/run.log" && grep -q '^do_spl_fleet_notice .*DESK_TO=\( \|$\)' "$T/run.log" &&
  pass "4. ALERT: one ask + one ops channel notice (FR-075)" || fail "4. alert: $(cat "$T/run.log")"
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
( act DRY_RUN=0 ROTATE_ACK_TIMEOUT=5 ROTATE_TEST_REAL=1 >"$T/o" 2>&1 ) & sleep 3
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
# a hold whose rotation is provably dead goes at once (20261008T1815Z-master: reboot mid-rotation)
now=$(date +%s); rm -f "$D/lease.log"
echo "btime $(( now - 60 ))" >"$T/proc/stat"
echo "c-902 $(( now - 120 )) 20261008T1815Z-master" >"$D/rotate.hold"
[[ "$(able)" == "able=[102] why=[able]" && ! -e "$D/rotate.hold" ]] && grep -q 'rotate.hold on c-902 removed: the box booted after it' "$D/lease.log" &&
  pass "8. a 3-field hold written before the last boot: able at once, the hold removed" || fail "8. boot: $(able) $(cat "$D/lease.log" 2>&1)"
sleep 0 & gone=$!; wait "$gone"
echo "c-902 $now 20261008T1815Z-master $gone" >"$D/rotate.hold"
[[ "$(able)" == "able=[102] why=[able]" && ! -e "$D/rotate.hold" ]] && grep -q "rotate.hold on c-902 removed: its rotation pid $gone is gone" "$D/lease.log" &&
  pass "8. a hold whose rotation pid is gone: able at once, the hold removed" || fail "8. pid: $(able) $(cat "$D/lease.log" 2>&1)"
echo "c-902 $now 20261008T1815Z-master $$" >"$D/rotate.hold"
[[ "$(able)" == "able=[] why=[held: rotation since "* && -e "$D/rotate.hold" ]] &&
  pass "8. CONTROL: a live rotation's hold (pid alive, written after the boot) still holds" || fail "8. control: $(able)"
rm -f "$T/proc/stat"
echo "c-902 $now 20261008T1815Z-master" >"$D/rotate.hold"
[[ "$(able)" == "able=[] why=[held: rotation since "* ]] &&
  pass "8. CONTROL: a fresh 3-field hold, no btime readable: still held" || fail "8. control3: $(able)"

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

# a reboot mid-rotation (20261008T1815Z-master: GATE 18:15:07Z, the box rebooted
# 18:18:02Z): the resume ends it as "interrupted by boot", hold and ctx gone,
# NO FAIL blocker; the CONTROL, GATE on this boot, still FAILs as before
at_gate() {  # BTIME_AGO
  world; now=$(date +%s); rid="$(date -u -d "@$(( now - 3600 ))" +%Y%m%dT%H%MZ)-master"
  echo "btime $(( now - $1 ))" >"$T/proc/stat"
  echo "c-902 $(( now - 3600 )) $rid" >"$D/rotate.hold"
  printf 'ROTATE_RID=%s\nROTATE_PHASE=GATE\nROTATE_OLD_PID=102\nROTATE_OLD_PANE=%%2\n' "$rid" >"$D/rotate.dispatch.ctx"
}
at_gate 60
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$D/rotate.dispatch.ctx" && ! -e "$D/rotate.hold" && "$(holder)" == c-902 ]] &&
  grep -q " $rid ABORT BOOT interrupted by boot at GATE: the box booted after its GATE" "$T/o" && grep -q " $rid ABORT BOOT interrupted by boot" "$D/rotate.log" &&
  ! grep -q 'FAIL' "$T/o" && ! grep -q '^do_spl_ask_put' "$T/run.log" 2>/dev/null &&
  pass "9. GATE before the last boot: 'interrupted by boot', ctx + hold removed, no FAIL blocker" || fail "9. boot rc=$rc $(cat "$T/o") $(cat "$T/run.log" 2>&1)"
act DRY_RUN=0 >"$T/o" 2>&1
! grep -q RESUME "$T/o" && pass "9. ... and the next run does not RESUME" || fail "9. boot resumed again: $(cat "$T/o")"
# SPL-1837 (2): GATE on this boot, left by a run that is gone (a ctx with no
# run pid): ABORT STALE, the hold gone, no FAIL, no blocker, and the forced
# run rotates under a new rid to DONE
at_gate 7200
act DRY_RUN=0 ROTATE_FORCE=1 >"$T/o" 2>&1; rc=$?
nrid="$(ctx ROTATE_RID)"
[[ $rc -eq 0 && "$nrid" != "$rid" && "$(ctx ROTATE_PHASE)" == DONE && "$(holder)" == c-902 && ! -e "$D/rotate.hold" ]] &&
  grep -q " $rid ABORT STALE at GATE: run pid unknown is gone, nothing was spawned; ctx and hold removed" "$T/o" &&
  grep -q " ${nrid%-*}-master GATE OK c-902 pid 102" "$T/o" && ! grep -qE " (RESUME|FAIL) " "$T/o" && ! grep -q '^do_spl_ask_put' "$T/run.log" 2>/dev/null &&
  pass "9. SPL-1837: GATE left by a gone run: ABORT STALE, hold removed, no FAIL, no blocker, a new rotation to DONE" || fail "9. stale rc=$rc $(cat "$T/o") $(cat "$T/run.log" 2>&1)"
# CONTROL: the recorded run is alive (pid 3100, same start tick): no STALE, no resume
at_gate 7200; "$T/bin/proc" 3100 none 50 bash
printf 'ROTATE_RUN_PID=3100\nROTATE_RUN_START=%s\n' "$(( (UP - 50) * TCK ))" >>"$D/rotate.dispatch.ctx"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(ctx ROTATE_PHASE)" == GATE && -e "$D/rotate.hold" && ! -e "$T/spawn.log" ]] && grep -q " GATE SKIP rotation $rid is still run by pid 3100" "$T/o" &&
  ! grep -qE ' (STALE|FAIL) ' "$T/o" && pass "9. CONTROL: its run still alive: SKIP, ctx and hold kept, nothing alerted" || fail "9. alive rc=$rc $(cat "$T/o")"
rm -f "$T/proc/stat"

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
heal ROTATE_HEAL_CONFIRM=3 ROTATE_TEST_REAL=1 >"$T/o" 2>&1; wait
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
rm -f "$T/vclock"
t0=$SECONDS; act DRY_RUN=0 ROTATE_ACK_TIMEOUT=30 >"$T/o" 2>&1; rc=$?
took=$(( SECONDS - t0 + $(awk '{s += $1} END {print int(s / 1000)}' "$T/vclock" 2>/dev/null || echo 0) ))
[[ $rc -ne 0 && $took -lt 25 ]] && grep -q " FAIL FAIL SPAWN: the new session in %2902 is stopped on a 'Settings Warning' dialog" "$T/o" &&
  ! grep -q ' ACK WAIT ' "$T/o" && pass "14. Settings Warning on the fresh M: FAIL SPAWN at once (${took}s, ack window 30s), named" ||
  fail "14. rc=$rc took=${took}s $(cat "$T/o")"
[[ -d "$T/proc/102" && "$(holder)" == c-902 && ! -e "$D/rotate.hold" ]] && grep -qx 'kill %2902' "$T/tmux/log" &&
  grep -q "^do_spl_ask_put .*ASK_FROM=c-902 .*ASK_SUMMARY=ROTATION FAILED master SPAWN the new session in %2902 is stopped on a 'Settings Warning'" "$T/run.log" &&
  grep -q '^do_spl_fleet_notice .*DESK_TO=\( \|$\)' "$T/run.log" &&
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
  grep -q "^do_spl_fleet_notice ASK_ID= ASK_STATE= DESK_TASK= DESK_KIND=note BODY=c-902@box-desk recovered at [0-9T:-]*Z by rotation $rid, now pid 2902\$" "$T/run2.log" &&
  [[ "$(grep -c 'recovered at' "$T/run2.log")" == 2 && ! -e "$S/c-902/lifetime/alerts.open" ]] &&
  grep -q " $rid RECOVERED OK ask 0e5a2c1b of 20261007T1715Z-master closed" "$D/rotate.log" &&
  pass "15. an open alert + an ACK OK: the ask closed, one recovered line to the owner on its thread, the file gone" || fail "15. $(cat "$T/run2.log") $(grep RECOVERED "$D/rotate.log")"
# SPL-1890: exit 3 = the orchestrator closed the ask first (6 of 6 live
# "RECOVERED FAIL" lines, 10-11..10-14): OK "already closed", not FAIL;
# control: any other exit is still a FAIL, with its code
for want in "3:RECOVERED OK ask 0e5a2c1b of 20261007T1715Z-master was already closed: c-902@box-desk recovered" \
            "1:RECOVERED FAIL ask 0e5a2c1b of 20261007T1715Z-master: do_spl_ask_close failed, exit 1 (c-902@box-desk recovered"; do
  world; rm -f "$T/run2.log"; mkdir -p "$S/c-902/lifetime"; echo "${want%%:*}" >"$T/askclose.rc"
  echo "0e5a2c1b-1111-4222-8333-944455556666 20261007T1715Z-master ACK" >"$S/c-902/lifetime/alerts.open"
  act DRY_RUN=0 >"$T/o" 2>&1
  grep -q " RECOVERED ${want#*:RECOVERED }" "$D/rotate.log" && [[ "$(grep -c 'recovered at' "$T/run2.log")" == 2 ]] &&
    pass "15. ask close exit ${want%%:*}: '${want#*:}'" || fail "15. ask close exit ${want%%:*}: $(grep RECOVERED "$D/rotate.log")"
done
rm -f "$T/askclose.rc"
world; rm -f "$T/run2.log"; act DRY_RUN=0 >"$T/o" 2>&1
! grep -q 'do_spl_ask_close\|recovered at' "$T/run2.log" && ! grep -q RECOVERED "$D/rotate.log" &&
  pass "15. control: no open alert, no ask close and no line" || fail "15. control: $(cat "$T/run2.log")"
# a failed rotation's alert is recorded for the next healthy start
world; echo no >"$T/ack.mode.c-902"; act DRY_RUN=0 ROTATE_ACK_TIMEOUT=2 >"$T/o" 2>&1
grep -qE '^[0-9a-f-]{36} [0-9]{8}T[0-9]{4}Z-master ACK$' "$S/c-902/lifetime/alerts.open" &&
  pass "15. a FAIL alert is recorded in <id>/lifetime/alerts.open" || fail "15. alerts.open: $(cat "$S/c-902/lifetime/alerts.open" 2>&1)"
! grep -q ERRTRAP "$T/o" && pass "15. no stray failing command under the ERR trap" || fail "15. ERRTRAP: $(grep ERRTRAP "$T/o")"

# --- 16. the seed's workspace list is generated --------------------------------------------
seedws() { sed -n 's/.*in every workspace: \([^.]*\)\. Posts arrive.*/\1/p' "$D/handoff/$1-c-902.seed.md"; }
rid1() { awk '$3 == "GATE" && $4 == "OK" {print $2}' "$D/rotate.log" | sed -n 1p; }
pin() { mkdir -p "$T/state/desk/$1/$2"; echo pinned >"$T/state/desk/$1/$2/pinned"; }
cp "$D/briefs/brief-dispatcher-c-902.md" "$T/brief.keep"
echo "- **Web UI**: you have a desk (DESK_AGENT=c-902) in every workspace: csi-rel, t1. Posts arrive as spool messages." \
  >"$D/briefs/brief-dispatcher-c-902.md"
world; act DRY_RUN=0 >"$T/o" 2>&1; rid="$(rid1)"
[[ "$(seedws "$rid")" == "csi-rel, t1" ]] &&
  pass "16. control: no pinned desk under the state dir -> the brief's own list stays" || fail "16. control: '$(seedws "$rid")'"
for w in csi-rel dsk-b t1 e2e; do pin "$w" box-desk; done; pin other-box-only sat
world; act DRY_RUN=0 >"$T/o" 2>&1; rid="$(rid1)"
[[ "$(seedws "$rid")" == "csi-rel, dsk-b, t1" ]] &&
  pass "16. the seed lists every pinned desk of this box (dsk-b in), not the brief's stale list; e2e and other-box left out" ||
  fail "16. seed list: '$(seedws "$rid")'"
pin zeta-new box-desk
world; act DRY_RUN=0 >"$T/o" 2>&1; rid="$(rid1)"
[[ "$(seedws "$rid")" == "csi-rel, dsk-b, t1, zeta-new" ]] &&
  pass "16. a desk pinned after the last rotation is in the next seed, no code change" || fail "16. new desk: '$(seedws "$rid")'"
cp "$T/brief.keep" "$D/briefs/brief-dispatcher-c-902.md"; rm -rf "$T/state"

# --- 17. T-ROLE-VENDOR: ROTATE_ROLE_VENDOR names the seats' vendor ---------------------------
# owner HUM-10 (t1 ee1e58d5, msgs f93e7f2a, c43b98f1): Grok as orchestrator
# and dispatcher for a test, through the orch rotation's guards
GROK='pick=grok launcher=/grok-spawn kind=orchestration reason=grok is the main'
world; echo "$GROK" >"$T/mix.out"
act ROTATE_ROLE_VENDOR=grok ROTATE_LEASE_KINDS="claude grok" >"$T/o" 2>&1
grep -q " SPAWN PLAN rename %2 .*; $T/bin/spawn grok c-902 .*; vendor: ROTATE_ROLE_VENDOR=grok: grok" "$T/o" &&
  grep -q " REFRESH PLAN .*c-903 (pid 103, .*) the same way, no hold; $T/bin/spawn grok" "$T/o" &&
  grep -qx 'LANE_MIX_KIND=orchestration LANE_MIX_SPLIT_KIND=claude=0 grok=100 agy=0 qwen=0 mistral=0 backup=claude' "$T/mix.log" &&
  pass "17. ROTATE_ROLE_VENDOR=grok: the SPAWN plan names grok for the master and the failover" || fail "17. plan: $(grep -E 'SPAWN PLAN|REFRESH PLAN' "$T/o"; cat "$T/mix.log" 2>&1)"
world; echo "$GROK" >"$T/mix.out"; echo 'ROTATE_ROLE_VENDOR=grok' >"$D/rotate.conf"
act ROTATE_LEASE_KINDS="claude grok" >"$T/o" 2>&1
grep -q " SPAWN PLAN rename %2 .*; $T/bin/spawn grok c-902 .*vendor: ROTATE_ROLE_VENDOR=grok: grok" "$T/o" &&
  pass "17. ROTATE_ROLE_VENDOR=grok read from rotate.conf: grok" || fail "17. rotate.conf: $(grep 'SPAWN PLAN' "$T/o")"
world; act ROTATE_ROLE_VENDOR= >"$T/o" 2>&1
grep -q " SPAWN PLAN rename %2 -> c-902-[0-9]*Z-retiring; $T/bin/spawn claude c-902 <seed: brief + rotation line> (SPAWN_REUSE_ID=1), the ACK-COMMAND in its first prompt (<rid>-<id>.head.md); adopt; a task on dispatch-rotate-[0-9TZ]*-master in its inbox\$" "$T/o" &&
  grep -q " REFRESH PLAN .*c-903 (pid 103, [0-9]*s old) the same way, no hold\$" "$T/o" && [[ ! -e "$T/mix.log" ]] &&
  pass "17. ROTATE_ROLE_VENDOR empty: today's lines, lane-mix not asked" || fail "17. empty: $(grep -E 'SPAWN PLAN|REFRESH PLAN' "$T/o")"
world; printf 'grok      100%%        0%%     0%%     0 no   skip (no grok cli); share to claude\npick=claude launcher=/claude-spawn kind=orchestration reason=claude under\n' >"$T/mix.out"
act ROTATE_ROLE_VENDOR=grok ROTATE_LEASE_KINDS="claude grok" >"$T/o" 2>&1
grep -q " SPAWN PLAN .*; $T/bin/spawn claude c-902 .*vendor: ROTATE_ROLE_VENDOR=grok, but no grok cli: claude" "$T/o" &&
  pass "17. ROTATE_ROLE_VENDOR=grok with no grok CLI: claude, the reason named" || fail "17. no cli: $(grep 'SPAWN PLAN' "$T/o")"
world; echo "$GROK" >"$T/mix.out"
act ROTATE_ROLE_VENDOR=grok ROTATE_LEASE_KINDS="claude" >"$T/o" 2>&1
grep -q " SPAWN PLAN .*; $T/bin/spawn claude c-902 .*ROTATE_ROLE_VENDOR=grok, but the fleet lease does not count a grok process as the holder: claude" "$T/o" &&
  pass "17. ROTATE_ROLE_VENDOR=grok, a lease that counts only claude: claude" || fail "17. lease guard: $(grep 'SPAWN PLAN' "$T/o")"
world; echo "$GROK" >"$T/mix.out"
act DRY_RUN=0 ROTATE_ROLE_VENDOR=grok ROTATE_LEASE_KINDS="claude grok" >"$T/o" 2>&1; rc=$?
rid="$(awk '$3 == "GATE" && $4 == "OK" {print $2}' "$D/rotate.log" | sed -n 1p)"; frid="${rid%-master}-failover"
[[ $rc -eq 0 && "$(cat "$T/proc/2902/comm" 2>/dev/null)" == grok && "$(cat "$T/proc/2903/comm" 2>/dev/null)" == grok && ! -d "$T/proc/102" && ! -d "$T/proc/103" ]] &&
  grep -q "^spawn grok c-902 " "$T/spawn.log" && grep -q "^spawn grok c-903 " "$T/spawn.log" && grep -q " $rid DONE OK fresh c-902" "$T/o" &&
  grep -q "send c-902 -> c-902 result dispatch-rotate-$rid .*ACK rotation $rid: c-902 pid 2902" "$T/send.log" &&
  grep -q "send c-903 -> c-903 result dispatch-rotate-$frid .*ACK rotation $frid: c-903 pid 2903" "$T/send.log" && [[ "$(holder)" == c-902 ]] &&
  pass "17. ROTATE_ROLE_VENDOR=grok: grok M and F ack from their first prompt, M holds the lease ($rid)" || fail "17. happy rc=$rc $(cat "$T/o") $(cat "$T/ack.out" 2>/dev/null)"
world; echo "$GROK" >"$T/mix.out"; echo no >"$T/ack.mode.c-902"
act DRY_RUN=0 ROTATE_ROLE_VENDOR=grok ROTATE_LEASE_KINDS="claude grok" ROTATE_ACK_TIMEOUT=2 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && -d "$T/proc/102" && ! -d "$T/proc/2902" && "$(holder)" == c-902 && ! -e "$D/rotate.hold" ]] && grep -q "^spawn grok c-902 " "$T/spawn.log" &&
  grep -q ' FAIL FAIL ACK: no ack within 2s; the old session (pid 102) keeps the role' "$T/o" &&
  pass "17. ROTATE_ROLE_VENDOR=grok, no ack: the grok M closed, the old claude M keeps the role and the lease" || fail "17. no-ack rc=$rc $(grep -E 'FAIL|ACK' "$T/o"; ls "$T/proc")"
! grep -q ERRTRAP "$T/o" && pass "17. no stray failing command under the ERR trap" || fail "17. ERRTRAP: $(grep ERRTRAP "$T/o")"

# --- 18. T-ROLE-ID-FOLLOWS-VENDOR (SPL-1685): the seats take their vendor's letter ------------
# w18 <letter> <letter of the live dirs>: the seats as <l>-002 / <l>-003 (pids 102, 103)
w18() {
  world; rm -rf "$S/c-90"* "$S"/[acgmq]-00[23] "$D/briefs/brief-dispatcher-"[acgmq]-00*
  printf 'LEASE_MASTER=%s-002\nLEASE_FAILOVER=%s-003\nLEASE_ORCH=c-900\nLEASE_ENV=prd\nLEASE_TENANT=t1\nASKS_OWNER=HUM-10\n' "$1" "$1" >"$D/lease.conf"
  for n in 002 003; do mkdir -p "$S/$1-$n/inbox" "$S/$1-$n/outbox" "$S/$1-$n/archive"; echo "brief of c-$n: read your inbox" >"$D/briefs/brief-dispatcher-c-$n.md"; done
  rm -rf "$T/proc/"[0-9]*; "$T/bin/proc" 102 "$1-002" 7200; "$T/bin/proc" 103 "$1-003" 7200
  printf '%%2\t102\t$0\t%s-002@box > dispatcher\n%%3\t103\t$0\t%s-003@box > dispatcher\n' "$1" "$1" >"$T/tmux/panes"
  echo "$1-002 $(date +%s)" >"$D/lease"
  echo '{"v":1,"msg_id":"m1","ts":"2026-10-02T05:10:00Z","from":"HUM-10","to":"'"$1"'-002","kind":"msg","task_id":"t-owner","body":"owner asks for X"}' >"$S/$1-002/inbox/m1.json"
}
V18=(ROTATE_ROLE_ID_FOLLOWS_VENDOR=1 ROTATE_LEASE_KINDS="claude grok" ROTATE_SWITCH_DESK_ENVS=)
w18 c; echo 'pick=grok reason=grok is the main' >"$T/mix.out"
act "${V18[@]}" ROTATE_ROLE_VENDOR=grok >"$T/o" 2>&1
grep -q " SWITCH PLAN c-002 -> g-002: the grok successor takes its vendor's id" "$T/o" && [[ ! -e "$S/g-002" ]] &&
  pass "18. dry run: plans c-002 -> g-002, moves nothing" || fail "18. dry: $(grep PLAN "$T/o")"
act DRY_RUN=0 "${V18[@]}" ROTATE_ROLE_VENDOR=grok >"$T/o" 2>&1; rc=$?
rid="$(awk '$3 == "GATE" && $4 == "OK" {print $2}' "$D/rotate.log" | sed -n 1p)"
[[ $rc -eq 0 ]] && grep -q " $rid DONE OK fresh g-002" "$T/o" && grep -qx 'LEASE_MASTER=g-002' "$D/lease.conf" && grep -qx 'LEASE_FAILOVER=g-003' "$D/lease.conf" &&
  [[ "$(holder)" == g-002 && ! -e "$D/rotate.hold" && -d "$T/proc/2002" && -d "$T/proc/2003" ]] &&
  pass "18. c-002 -> g-002, c-003 -> g-003: lease.conf follows, the lease is back on g-002 ($rid)" || fail "18. rc=$rc $(cat "$T/o") $(cat "$T/ack.out" 2>/dev/null); conf: $(cat "$D/lease.conf"); lease $(cat "$D/lease")"
grep -q "^spawn grok g-002 " "$T/spawn.log" && grep -q "^spawn grok g-003 " "$T/spawn.log" && grep -q 'brief of g-002: read your inbox' "$D/handoff/$rid-c-002.seed.md" &&
  ! grep -q 'c-002' "$D/handoff/$rid-c-002.seed.md" &&
  pass "18. the successors start as g-002 / g-003; the seed names only g-002" || fail "18. spawn/seed: $(cat "$T/spawn.log"; cat "$D/handoff/$rid-c-002.seed.md")"
echo '{"v":1,"msg_id":"m7","from":"HUM-10","to":"c-002","kind":"msg","task_id":"y","body":"late"}' >"$S/c-002/inbox/m7.json"
[[ "$(readlink "$S/c-002")" == g-002 && "$(readlink "$S/c-003")" == g-003 && -f "$S/g-002/inbox/m1.json" && -f "$S/g-002/inbox/m7.json" ]] &&
  pass "18. c-002 links to g-002: m1 (before) and m7 (sent to c-002 after) are in the live inbox" || fail "18. dirs: $(ls -l "$S"; ls "$S/g-002/inbox")"
w18 g; rm -f "$T/mix.out"
act DRY_RUN=0 "${V18[@]}" ROTATE_ROLE_VENDOR=claude >"$T/o" 2>&1; rc=$?
rid="$(awk '$3 == "GATE" && $4 == "OK" {print $2}' "$D/rotate.log" | sed -n 1p)"
[[ $rc -eq 0 ]] && grep -qx 'LEASE_MASTER=c-002' "$D/lease.conf" && [[ "$(holder)" == c-002 && "$(readlink "$S/g-002")" == c-002 ]] &&
  grep -q 'brief of c-002: read your inbox' "$D/handoff/$rid-g-002.seed.md" &&
  pass "18. g-002 -> c-002: back to claude, g-002 (no brief of its own) seeded from c-002's brief" || fail "18. back rc=$rc $(cat "$T/o"); $(cat "$D/lease.conf")"
w18 c; echo 'pick=grok reason=grok is the main' >"$T/mix.out"; echo no >"$T/ack.mode.g-002"
act DRY_RUN=0 "${V18[@]}" ROTATE_ROLE_VENDOR=grok >"$T/o" 2>&1
grep -qx 'LEASE_MASTER=c-002' "$D/lease.conf" && [[ "$(holder)" == c-002 && ! -e "$D/rotate.hold" && -d "$S/c-002" && ! -L "$S/c-002" && -d "$T/proc/102" ]] &&
  grep -q 'lease.conf LEASE_MASTER back to c-002; seat switch back g-002 -> c-002' "$T/o" &&
  pass "18. a grok M with no ack: lease.conf, hold and dirs back to c-002, the old M keeps the lease" || fail "18. no-ack: $(grep -E 'FAIL|SWITCH' "$T/o"; cat "$D/lease.conf"; ls -l "$S")"
! grep -q ERRTRAP "$T/o" "$T/ack.out" && pass "18. no stray failing command under the ERR trap" || fail "18. ERRTRAP: $(grep ERRTRAP "$T/o" "$T/ack.out")"
rm -rf "$S"/[acgmq]-00[23] "$D/briefs/brief-dispatcher-"[acgmq]-00*

# --- 19. T-STANDBY-SWAP (SPL-1777): a standby box replaces a seat whose vendor is out ----------
# sb: grok seats g-002 / g-003, the dispatch lease on sat, g-002 on grok's limit
sb() {
  w18 g; rm -rf "$D/wd" "$T/mix.out"
  echo 'LEASE_FLEET=main' >>"$D/lease.conf"; echo "g-002@sat $(date +%s)" >"$D/lease"; cp "$D/lease" "$T/lease.before"
  mkdir -p "$D/wd/ctx.1/g-002" "$D/wd/ctx.1/g-003"
  echo 'HIT S2 kind=limit pane: You hit your weekly limit' >"$D/wd/ctx.1/g-002/out.s2"; : >"$D/wd/ctx.1/g-003/out.s2"
}
sb; act "${V18[@]}" ROTATE_ROLE_VENDOR= >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q -- '-master STANDBY PLAN g-002 (grok, pid 102) is out (S2 kind=limit [0-9]*s ago: pane: You hit your weekly limit): the master seat goes to c-002 (claude: dispatch seats: claude); the dispatch lease stays g-002@sat' "$T/o" &&
  ! grep -q 'failover STANDBY' "$T/o" && [[ ! -e "$T/spawn.log" && ! -e "$S/c-002" ]] && grep -qx 'LEASE_MASTER=g-002' "$D/lease.conf" &&
  pass "19. dry run: plans g-002 -> c-002, leaves g-003, moves nothing" || fail "19. dry rc=$rc: $(cat "$T/o")"
sb; act DRY_RUN=0 "${V18[@]}" ROTATE_ROLE_VENDOR= >"$T/o" 2>&1; rc=$?
rid="$(awk '$3 == "STANDBY" && $4 == "OK" {print $2}' "$D/rotate.log" | sed -n 1p)"
[[ $rc -eq 0 && "$rid" == *-master ]] && grep -q "^spawn claude c-002 " "$T/spawn.log" && ! grep -q ' g-003 ' "$T/spawn.log" &&
  [[ "$(cat "$T/proc/2002/comm" 2>/dev/null)" == claude && ! -d "$T/proc/102" && -d "$T/proc/103" ]] &&
  grep -qx 'LEASE_MASTER=c-002' "$D/lease.conf" && grep -qx 'LEASE_FAILOVER=g-003' "$D/lease.conf" && [[ "$(readlink "$S/g-002")" == c-002 ]] &&
  grep -q " $rid DONE OK standby master seat: c-002 (claude, pid 2002) replaces g-002; the dispatch lease stays g-002@sat" "$T/o" &&
  pass "19. lease remote + g-002 on its limit: replaced by c-002 (claude, the guard's vendor), g-003 untouched ($rid)" ||
  fail "19. swap rc=$rc: $(cat "$T/o") $(cat "$T/ack.out" 2>/dev/null); conf: $(cat "$D/lease.conf")"
cmp -s "$D/lease" "$T/lease.before" && [[ ! -e "$D/rotate.hold" ]] && ! grep -q 'dispatch-lease' "$T/send.log" &&
  ! grep -qE " $rid (HOLD|RELEASE OK|REFRESH)" "$D/rotate.log" &&
  pass "19. the lease file unchanged, no hold, no release, no refresh, no lease note" || fail "19. lease: $(cat "$D/lease") / $(cat "$T/lease.before"); $(grep -E 'dispatch-lease' "$T/send.log"; grep -E 'HOLD|RELEASE|REFRESH' "$D/rotate.log")"
grep -q "send c-900 -> c-900 result dispatch-rotate-$rid .*STANDBY SWAP $rid on box-desk: g-002 (grok) was out .*c-002 (claude) now holds the standby master seat. The dispatch lease stays g-002@sat. Seat its desks: do_spl_desk_up" "$T/send.log" &&
  pass "19. the orchestrator gets one STANDBY SWAP result naming do_spl_desk_up" || fail "19. note: $(cat "$T/send.log")"
! grep -q ERRTRAP "$T/o" "$T/ack.out" && pass "19. no stray failing command under the ERR trap" || fail "19. ERRTRAP: $(grep ERRTRAP "$T/o" "$T/ack.out")"
sb; act DRY_RUN=0 "${V18[@]}" ROTATE_CMD=heal ROTATE_HEAL_CONFIRM=0 ROTATE_ROLE_VENDOR= >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "^spawn claude c-002 " "$T/spawn.log" && grep -qx 'LEASE_MASTER=c-002' "$D/lease.conf" && cmp -s "$D/lease" "$T/lease.before" &&
  ! grep -q 'HEAL SKIP standby' "$T/o" &&
  pass "19. the heal cron (ROTATE_CMD=heal) replaces it the same way" || fail "19. heal rc=$rc: $(cat "$T/o")"
# SPL-1820: ROTATE_ROLE_VENDOR=grok with lane-mix still picking grok: the
# guard reads g-002's limit verdict itself (spl_rotate_grok_out) -> claude
sb; echo 'pick=grok reason=grok is the main' >"$T/mix.out"
act DRY_RUN=0 "${V18[@]}" ROTATE_ROLE_VENDOR=grok >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "^spawn claude c-002 " "$T/spawn.log" && grep -qx 'LEASE_MASTER=c-002' "$D/lease.conf" &&
  grep -q 'ROTATE_ROLE_VENDOR=grok, but grok is on its limit (g-002 S2 kind=limit' "$T/o" &&
  pass "19. ROTATE_ROLE_VENDOR=grok, lane-mix picks grok, g-002 on its limit: the guard gives claude, c-002 replaces it" || fail "19. grok guard rc=$rc: $(cat "$T/o")"
# control: a guard that picks the dead vendor again (blind to the verdict: ROTATE_GROK_LIMIT_FRESH=-1)
sb; echo 'pick=grok reason=grok is the main' >"$T/mix.out"
act DRY_RUN=0 "${V18[@]}" ROTATE_ROLE_VENDOR=grok ROTATE_GROK_LIMIT_FRESH=-1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$T/spawn.log" && -d "$T/proc/102" ]] && grep -qx 'LEASE_MASTER=g-002' "$D/lease.conf" && cmp -s "$D/lease" "$T/lease.before" &&
  grep -q -- '-master STANDBY SKIP g-002 (grok) is out (S2 kind=limit .*), but its successor would be grok too (ROTATE_ROLE_VENDOR=grok: grok): no replacement' "$D/rotate.log" &&
  pass "19. control: the guard picks grok again -> no replacement, the reason in rotate.log" || fail "19. same vendor rc=$rc: $(cat "$T/o")"
# control: a verdict older than the seat's process (pid 102 is 2 h old)
sb; touch -d '3 hours ago' "$D/wd/ctx.1/g-002/out.s2"
act DRY_RUN=0 "${V18[@]}" ROTATE_ROLE_VENDOR= >"$T/o" 2>&1
grep -q ' GATE SKIP standby (dispatch lease: g-002@sat)' "$T/o" && [[ ! -e "$T/spawn.log" ]] && grep -qx 'LEASE_MASTER=g-002' "$D/lease.conf" &&
  pass "19. control: a verdict older than the seat's process -> GATE SKIP standby" || fail "19. stale: $(cat "$T/o")"
# control: healthy seats on the standby box
sb; : >"$D/wd/ctx.1/g-002/out.s2"
act DRY_RUN=0 "${V18[@]}" ROTATE_ROLE_VENDOR= >"$T/o" 2>&1
grep -q ' GATE SKIP standby (dispatch lease: g-002@sat)' "$T/o" && [[ ! -e "$T/spawn.log" ]] && ! grep -q STANDBY "$T/o" &&
  pass "19. control: healthy standby seats -> GATE SKIP standby (FR-044)" || fail "19. healthy: $(cat "$T/o")"
# SPL-1869 (owner t1 e799211c, answer A): claude seats under
# ROTATE_ROLE_VENDOR=claude, c-002 on its limit, grok able: the grok standby
# replaces it; control: ROTATE_GROK_STANDBY=0 = claude again, no replacement
printf '#!/bin/sh\n' >"$T/bin/claude-cli"; chmod +x "$T/bin/claude-cli"
sbc() {
  w18 c; rm -rf "$D/wd" "$T/mix.out"
  echo 'LEASE_FLEET=main' >>"$D/lease.conf"; echo "c-002@sat $(date +%s)" >"$D/lease"
  mkdir -p "$D/wd/ctx.1/c-002" "$D/wd/ctx.1/c-003"
  echo "HIT S2 kind=limit pane: You've hit your session limit · resets 8:20pm" >"$D/wd/ctx.1/c-002/out.s2"; : >"$D/wd/ctx.1/c-003/out.s2"
  echo 'pick=grok reason=grok is the main' >"$T/mix.out"
}
sbc; act "${V18[@]}" ROTATE_ROLE_VENDOR=claude ROTATE_CLAUDE_BIN="$T/bin/claude-cli" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q -- "-master STANDBY PLAN c-002 (claude, pid 102) is out (S2 kind=limit [0-9]*s ago: pane: You've hit your session limit · resets 8:20pm): the master seat goes to g-002 (grok: ROTATE_ROLE_VENDOR=claude, claude cannot act (c-002 S2 kind=limit 0m ago: pane: You've hit your session limit · resets 8:20pm): the grok standby); the dispatch lease stays c-002@sat" "$T/o" &&
  ! grep -q 'failover STANDBY' "$T/o" && [[ ! -e "$T/spawn.log" ]] && grep -qx 'LEASE_MASTER=c-002' "$D/lease.conf" &&
  pass "19. SPL-1869 claude seat c-002 on its limit, ROTATE_ROLE_VENDOR=claude: the grok standby g-002 is planned" || fail "19. standby rc=$rc: $(cat "$T/o")"
sbc; act "${V18[@]}" ROTATE_ROLE_VENDOR=claude ROTATE_CLAUDE_BIN="$T/bin/claude-cli" ROTATE_GROK_STANDBY=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$T/spawn.log" ]] && grep -qx 'LEASE_MASTER=c-002' "$D/lease.conf" &&
  grep -q -- '-master STANDBY SKIP c-002 (claude) is out (S2 kind=limit .*), but its successor would be claude too (ROTATE_ROLE_VENDOR=claude, ROTATE_GROK_STANDBY=0: claude): no replacement' "$T/o" &&
  pass "19. SPL-1869 control: ROTATE_GROK_STANDBY=0 -> claude again, no replacement" || fail "19. standby off rc=$rc: $(cat "$T/o")"
rm -rf "$S"/[acgmq]-00[23] "$D/briefs/brief-dispatcher-"[acgmq]-00* "$D/wd"

# --- 20. SPL-1837 (1): a run started INSIDE a dispatcher pane re-runs itself detached ------------
cat >"$T/bin/setsid" <<'EOF'
#!/usr/bin/env bash
echo "setsid $* DRY_RUN=${DRY_RUN:-} ROTATE_FORCE=${ROTATE_FORCE:-}" >>"$T/setsid.log"
flock -n 9 9>>"$SPOOL_ROOT/dispatch/rotate.dispatch.lock" && echo "rotate lock free" >>"$T/setsid.log"
flock -n 8 8>>"$SPOOL_ROOT/c-902/lifetime/restart.lock" && echo "id lock free" >>"$T/setsid.log"
exit 0
EOF
chmod +x "$T/bin/setsid"
inside() {  # PPID: pid 3001, a bash whose parent is PPID
  world; rm -f "$T/setsid.log"; mkdir -p "$T/proc/3001"; echo bash >"$T/proc/3001/comm"
  echo "3001 (bash) S $1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $(( (UP - 5) * TCK ))" >"$T/proc/3001/stat"
}
for in_pid in 102 103; do
  inside "$in_pid"
  act DRY_RUN=0 ROTATE_FORCE=1 ROTATE_SELF_PID=3001 ROTATE_SETSID="$T/bin/setsid" >"$T/o" 2>&1; rc=$?
  pn="%${in_pid#10}"
  [[ $rc -eq 0 && ! -e "$T/spawn.log" && ! -e "$D/rotate.hold" && ! -e "$D/rotate.dispatch.ctx" ]] &&
    grep -q " GATE SKIP inside: this run is in $pn, which QUIESCE would interrupt; re-run detached (setsid), log $D/rotate.dispatch.detached.log" "$T/o" &&
    grep -q "^setsid env ROTATE_DETACHED=1 $T/bin/run -a do_spl_dispatch_rotate DRY_RUN=0 ROTATE_FORCE=1\$" "$T/setsid.log" &&
    grep -qx 'rotate lock free' "$T/setsid.log" && grep -qx 'id lock free' "$T/setsid.log" && ! grep -q 'Escape' "$T/tmux/log" 2>/dev/null &&
    pass "20. SPL-1837: run inside $pn: re-run detached, both locks free, no hold, no Escape" || fail "20. inside $pn rc=$rc $(cat "$T/o") $(cat "$T/setsid.log" 2>&1) | $(cat "$T/tmux/log" 2>&1) | $(ls "$T" "$D")"
done
inside 102
act DRY_RUN=0 ROTATE_FORCE=1 ROTATE_SELF_PID=3001 ROTATE_SETSID="$T/bin/setsid" ROTATE_DETACHED=1 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && ! -e "$T/setsid.log" && ! -e "$D/rotate.hold" ]] && grep -q " GATE SKIP inside: this detached run is still in %2" "$T/o" &&
  pass "20. a detached run still inside the pane: refused, no second re-run" || fail "20. loop rc=$rc $(cat "$T/o")"
# CONTROL: a run outside every pane rotates as before
inside 1
act DRY_RUN=0 ROTATE_FORCE=1 ROTATE_SELF_PID=3001 ROTATE_SETSID="$T/bin/setsid" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$T/setsid.log" && "$(ctx ROTATE_PHASE)" == DONE ]] &&
  pass "20. CONTROL: a run outside the panes rotates to DONE, no re-run" || fail "20. control rc=$rc $(cat "$T/o")"

# --- 21. SPL-1890: a failover that cannot take the lease = GATE SKIP, no HOLD, no owner page ------
# 20261014T0215Z-master on sat: c-003 on its weekly limit (wd S2 HIT every 30 s),
# HOLD waited 240 s for a lease move that never came, then FAIL + ask + DM.
world; rm -f "$D"/rotate.dispatch.told.*; echo "HIT S2 $(date +%s)" >"$D/wd.c-903"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$T/spawn.log" && ! -e "$D/rotate.hold" && "$(holder)" == c-902 && -d "$T/proc/102" ]] &&
  grep -q ' GATE SKIP failover not able: c-903 wd S2: HIT [0-9]*s ago' "$T/o" && ! grep -q ' FAIL ' "$T/o" &&
  pass "21. SPL-1890: failover on a fresh watchdog HIT: GATE SKIP, no hold, no spawn, the lease stays on c-902" ||
  fail "21. unable failover rc=$rc $(cat "$T/o")"
! grep -q '^do_spl_ask_put\|^do_spl_desk_reply\|^do_spl_fleet_notice' "$T/run.log" 2>/dev/null &&
  [[ "$(grep -c 'send c-900 -> c-900 note dispatch-rotate .*ROTATION SKIP failover not able: c-903' "$T/send.log" 2>/dev/null)" == 1 ]] &&
  pass "21. ... no ask, no owner DM; the orchestrator gets one note" || fail "21. alert legs: $(cat "$T/run.log" "$T/send.log" 2>&1)"
act DRY_RUN=0 >"$T/o" 2>&1
grep -q ' GATE SKIP failover not able' "$T/o" && [[ "$(grep -c 'ROTATION SKIP failover not able' "$T/send.log")" == 1 ]] &&
  pass "21. ... the next hour skips again without a second note" || fail "21. second run: $(cat "$T/o") $(cat "$T/send.log")"
world; echo "HIT S2 $(date +%s)" >"$D/wd.c-903"
act >"$T/o" 2>&1
grep -q ' GATE SKIP failover not able: c-903' "$T/o" && ! grep -q ' HOLD PLAN ' "$T/o" &&
  pass "21. ... a dry run shows the same SKIP, no HOLD PLAN" || fail "21. dry: $(cat "$T/o")"
# CONTROLS: a watchdog HIT older than WD_FRESH, or an OK verdict, rotates as before
for v in "HIT S2 $(( $(date +%s) - 600 ))" "OK $(date +%s)"; do
  world; rm -f "$D"/rotate.dispatch.told.*; echo "$v" >"$D/wd.c-903"
  act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
  [[ $rc -eq 0 && "$(ctx ROTATE_PHASE)" == DONE ]] && ! grep -q 'failover not able' "$T/o" &&
    pass "21. CONTROL: wd.c-903 '${v%% [0-9]*}' (old or OK) rotates to DONE" || fail "21. control '$v' rc=$rc $(cat "$T/o")"
done
rm -f "$D/wd.c-903"

# --- 22. SPL-2555: grok's limit is judged by the newest verdict across seats ---------------------
# go: the real lib, sourced in a subshell, on its own watchdog dir
go() { ( export SPOOL_ROOT="$S" LANE_MIX_WD_DIR="$T/wd22"; source "$PROJ_ROOT/src/bash/run/spl-rotate-lib.func.sh"; spl_rotate_grok_out ); }
v22() {  # ID AGE VERDICT: one out.s2 written AGE ago
  mkdir -p "$T/wd22/ctx.1/$1"; printf '%s\n' "$3" >"$T/wd22/ctx.1/$1/out.s2"; touch -d "$2" "$T/wd22/ctx.1/$1/out.s2"
}
rm -rf "$T/wd22"; v22 g-178 '3 days ago' 'HIT S2 kind=limit pane: You hit your weekly limit'; v22 g-002 '1 hour ago' ''
o="$(go)"; [[ -z "$o" ]] && pass "22. g-178 limit 3 days ago, g-002 clean 1 h ago: grok is not out" || fail "22. stale seat: '$o'"
rm -rf "$T/wd22"; v22 g-178 '1 hour ago' 'HIT S2 kind=limit pane: You hit your weekly limit'; v22 g-002 '3 hours ago' ''
o="$(go)"; [[ "$o" == 'g-178 S2 kind=limit 60m ago: pane: You hit your weekly limit' ]] &&
  pass "22. control: the newest verdict across seats is a limit: out ($o)" || fail "22. newest limit: '$o'"
rm -rf "$T/wd22"; v22 g-178 '2 days ago' 'HIT S2 kind=limit pane: weekly'
o="$(go)"; [[ "$o" == 'g-178 S2 kind=limit '*'m ago: pane: weekly' ]] && pass "22. control: one seat alone on its limit: out" || fail "22. alone: '$o'"
rm -rf "$T/wd22"; v22 g-002 '10 minutes ago' 'HIT S2 kind=limit pane: weekly'; v22 g-003 '10 minutes ago' ''
touch -r "$T/wd22/ctx.1/g-002/out.s2" "$T/wd22/ctx.1/g-003/out.s2"
o="$(go)"; [[ "$o" == 'g-002 S2 kind=limit 10m ago: pane: weekly' ]] && pass "22. control: a tie with a limit: out" || fail "22. tie: '$o'"
rm -rf "$T/wd22"; v22 g-178 '8 days ago' 'HIT S2 kind=limit pane: weekly'
o="$(go)"; [[ -z "$o" ]] && pass "22. control: a limit older than ROTATE_GROK_LIMIT_FRESH: not out" || fail "22. old: '$o'"

# --- 23. SPL-2899 (B): the lease moves to ANOTHER box during HOLD = HOLD SKIP standby, no alert ---
# rotation-failures-2026-10-22.md row 2a: box 2's HOLD waited for c-003@<box-2>
# while box 1 took the lease back as c-002@<box-1>: FAIL HOLD + ask, the role
# served the whole time. Fleet mode (the loop moves the lease, not the hold).
fleet_world() { world; rm -f "$D"/fleet.*; echo 'LEASE_FLEET=main' >>"$D/lease.conf"; echo "c-902@box-desk $(date +%s)" >"$D/lease"; }
fleet_world
( while [[ ! -e "$D/rotate.hold" ]]; do command sleep 0.05; done; echo "c-902@box-main $(date +%s)" >"$D/lease" ) & mover=$!
act DRY_RUN=0 ROTATE_TEST_REAL=1 >"$T/o" 2>&1; rc=$?
kill "$mover" 2>/dev/null; wait "$mover" 2>/dev/null
[[ $rc -eq 0 && ! -e "$D/rotate.hold" && ! -e "$T/spawn.log" && -d "$T/proc/102" ]] &&
  grep -q ' HOLD SKIP standby (lease c-902@box-main)' "$T/o" && ! grep -q ' FAIL ' "$T/o" &&
  pass "23. (B) the lease on another box during HOLD: HOLD SKIP standby, no hold left, nothing spawned" || fail "23. (B) rc=$rc $(cat "$T/o")"
! grep -q '^do_spl_ask_put\|^do_spl_fleet_notice' "$T/run.log" 2>/dev/null &&
  pass "23. (B) ... no ask, no ops notice" || fail "23. (B) alerted: $(cat "$T/run.log" 2>&1)"
act DRY_RUN=0 >"$T/o" 2>&1
! grep -qE ' (RESUME|FAIL) ' "$T/o" && grep -q ' GATE SKIP standby (dispatch lease: c-902@box-main)' "$T/o" &&
  pass "23. (B) ... the next run gates afresh (no RESUME of the skipped hold)" || fail "23. (B) next run: $(cat "$T/o")"
# CONTROL: the lease never moves (stays on this box) = FAIL HOLD + ask, as before
fleet_world
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q ' FAIL FAIL HOLD: the lease did not move to c-903' "$T/o" && ! grep -q 'HOLD SKIP' "$T/o" &&
  grep -q '^do_spl_ask_put .*ASK_SUMMARY=ROTATION FAILED master PROMOTE' "$T/run.log" &&
  pass "23. (B) CONTROL: the lease stays on this box: FAIL HOLD + ask" || fail "23. (B) control rc=$rc $(cat "$T/o") $(cat "$T/run.log" 2>&1)"

# --- 24. SPL-2899 (C): a fresh fleet.dispatch.hub-down = GATE SKIP hub-down, no hold -------------
# row 2b: HUB-UNREACHABLE at 17:14Z, GATE OK at 17:15Z, then FAIL HOLD + ask:
# with the hub down no lease can move. The marker is SPL-2865's, only read here.
fleet_world; echo "$(( $(date +%s) - 30 ))" >"$D/fleet.dispatch.hub-down"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$D/rotate.hold" && ! -e "$T/spawn.log" && "$(holder)" == c-902@box-desk ]] &&
  grep -q ' GATE SKIP hub-down (the hub was unreachable from here [0-9]*s ago' "$T/o" && ! grep -qE ' (GATE OK|FAIL) ' "$T/o" &&
  ! grep -q '^do_spl_ask_put' "$T/run.log" 2>/dev/null &&
  pass "24. (C) a fresh hub-down marker: GATE SKIP hub-down, no hold, no ask" || fail "24. (C) rc=$rc $(cat "$T/o") $(cat "$T/run.log" 2>&1)"
act >"$T/o" 2>&1
grep -q ' GATE SKIP hub-down' "$T/o" && ! grep -q ' HOLD PLAN ' "$T/o" &&
  pass "24. (C) ... a dry run shows the same SKIP" || fail "24. (C) dry: $(cat "$T/o")"
# CONTROL: a marker older than LEASE_STALE (180 s) gates as before (local mode: to DONE)
world; echo "$(( $(date +%s) - 600 ))" >"$D/fleet.dispatch.hub-down"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(ctx ROTATE_PHASE)" == DONE ]] && ! grep -q 'hub-down' "$T/o" &&
  pass "24. (C) CONTROL: a hub-down marker 600s old: rotates to DONE" || fail "24. (C) control rc=$rc $(cat "$T/o")"
rm -f "$D"/fleet.*

# --- 25. SPL-2899 (F): RELEASE with the lease kept on a better-vendor failover = RELEASE SKIP ----
# row 6: master g-002 (grok), failover c-003 (claude); the fleet's vendor rank
# keeps the lease on c-003 past RELEASE's wait: RELEASE FAIL + ask, while the
# lease came back by FALLBACK-WAIT 3 min later. The live shape at RELEASE.
at_rank() {  # <master> <failover wd verdict or ->
  world; rm -rf "$S/g-902" "$T/ai.g-902" "$D"/wd.*; mkdir -p "$S/g-902/inbox" "$S/g-902/outbox"
  sed -i "s/^LEASE_MASTER=.*/LEASE_MASTER=$1/" "$D/lease.conf"; echo 'LEASE_FLEET=main' >>"$D/lease.conf"
  echo "c-903@box-desk $(date +%s)" >"$D/lease"
  rm -rf "$T/proc/102"; "$T/bin/proc" 2902 "$1" 0; printf '%%2902\t2902\t$0\t%s@box\n' "$1" >>"$T/tmux/panes"; echo 2902 >"$T/ai.$1"
  [[ "$2" == - ]] || echo "$2" >"$D/wd.c-903"
  date +%s >"$D/rotate.dispatch.last"
  printf 'ROTATE_RID=20261019T1915Z-master\nROTATE_PHASE=RELEASE\nROTATE_OLD_PID=102\nROTATE_OLD_PANE=%%2\nROTATE_NEW_PID=2902\nROTATE_NEW_PANE=%%2902\n' >"$D/rotate.dispatch.ctx"
}
at_rank g-902 -
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(ctx ROTATE_PHASE)" == DONE ]] && grep -q ' RELEASE SKIP vendor rank: the lease stays on c-903@box-desk (claude) over g-902 (grok)' "$T/o" &&
  ! grep -qE ' (RELEASE FAIL|FAIL FAIL) ' "$T/o" && ! grep -q '^do_spl_ask_put' "$T/run.log" 2>/dev/null &&
  pass "25. (F) grok master, the lease kept on the claude failover: RELEASE SKIP vendor rank, DONE, no ask" || fail "25. (F) rc=$rc phase=$(ctx ROTATE_PHASE) $(cat "$T/o") $(cat "$T/run.log" 2>&1)"
! grep -q 'NOT healthy' "$T/send.log" 2>/dev/null && ! grep -q REFRESH "$T/o" &&
  pass "25. (F) ... no NOT-healthy note, no refresh of the acting failover" || fail "25. (F) note: $(cat "$T/o") $(cat "$T/send.log" 2>&1)"
# CONTROL: the claude failover cannot act (fresh watchdog HIT) = RELEASE FAIL + ask, as before
at_rank g-902 "HIT S2 $(date +%s)"
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q ' RELEASE FAIL the lease is still c-903@box-desk' "$T/o" && ! grep -q 'RELEASE SKIP' "$T/o" &&
  grep -q '^do_spl_ask_put .*ASK_SUMMARY=ROTATION FAILED master RELEASE' "$T/run.log" &&
  pass "25. (F) CONTROL: the failover not able: RELEASE FAIL + ask" || fail "25. (F) control-able rc=$rc $(cat "$T/o")"
rm -f "$D/wd.c-903"
# CONTROL: same vendor (claude master, claude failover) = RELEASE FAIL, as before
at_rank c-902 -
act DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q ' RELEASE FAIL the lease is still c-903@box-desk' "$T/o" && ! grep -q 'RELEASE SKIP' "$T/o" &&
  pass "25. (F) CONTROL: no better vendor on the failover: RELEASE FAIL" || fail "25. (F) control-rank rc=$rc $(cat "$T/o")"
! grep -q ERRTRAP "$T/o" && pass "25. no stray failing command under the ERR trap" || fail "25. ERRTRAP: $(grep ERRTRAP "$T/o")"
rm -rf "$S/g-902"

echo
(( fails == 0 )) && { echo "dispatch-rotate: all passed"; exit 0; }
echo "dispatch-rotate: $fails failure(s)"; exit 1
