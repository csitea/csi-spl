#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the peer crons of spec 068 (sections 6.1, 6.2, 8.1, lane L6):
#          do_spl_peer_restart, do_spl_peer_distill, their _install_cron
#          actions, do_spl_peer_crons and the desk-reconcile cut, in a sandbox.
#          Nothing real is touched: sessions live in a fake /proc
#          (LEASE_PROC_ROOT), tmux is a stub keeping panes in a file (its
#          input box answers /exit-clean as the CLI does), spawn-window.sh,
#          ./run, the identity map, kill and crontab are stubs. The actions run
#          under ./run's `set -E` + an ERR trap that ends the run.
#   1. slot -> seat on both offsets (0 and 7): each seat owns 15 minutes,
#      001..004 at M, M+15, M+30, M+45; the distill names the seat of the NEXT
#      slot; the cron schedules
#   2. inert: no seats file = restart and distill exit 0 and write nothing
#   3. a restart: only the slot's seat; its poll loop stopped, the handoff
#      (no lease lines), the seed with the summary VERBATIM, a fresh session
#      under the same id, the old one /exit-cleaned, the loop started again
#   4. a failed start keeps the old one: it keeps its window name, the new
#      window is closed, its loop is started again, ask + owner DM
#   5. one seat at a time: a restart in flight -> the next one skips
#   6. the distill poke reaches only the seat due next (both offsets, the
#      offset read from peer.conf)
#   7. the seed: an oversize summary is cut at the cap (lines, bytes) with a
#      [cut] line; a missing or stale one restarts on the mechanical handoff
#      alone with ONE `WARN distill-missing <id>` (a grok seat here)
#   8. the crontab fixture before / after: do_spl_peer_crons is a dry run by
#      default, refuses a box with no seat, then installs the three peer tags,
#      removes the three old ones, keeps every other line byte for byte,
#      writes the desk-reconcile marker, and is idempotent; the installers
#   9. acceptance 8.1 on the fixture before and after (0 failing lines), and
#      the failing control: a line outside any checkout is named
#  10. the desk-reconcile cut: the lease ensure + dispatch tick run without
#      the marker and are cut with it; the desk steps run in both
#  11. the cron scripts run their action from the checkout, name a missing tool
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'for f in "$T"/loop.*.pid; do [ -f "$f" ] && kill -- "-$(cat "$f")" 2>/dev/null; done; rm -rf "$T"' EXIT
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/proc" "$T/tmux" "$D" "$T/hold" "$T/mem"
T0=1800000000   # 2027-01-15T08:00:00Z: minute 0
echo "100000.00 0.00" > "$T/proc/uptime"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\n' "$(id -un)" "$(id -un)" > "$S/box.env"

# --- stubs --------------------------------------------------------------------
# proc <pid> <id> [comm]: a live session carrying SPOOL_AGENT_ID=<id>
cat > "$T/bin/proc" <<'EOF'
#!/usr/bin/env bash
d="$T/proc/$1"; mkdir -p "$d"; echo "${3:-claude}" > "$d/comm"
printf 'SPOOL_AGENT_ID=%s\0' "$2" > "$d/environ"
printf 'Uid:\t%s\t%s\n' "$(id -u)" "$(id -u)" > "$d/status"
EOF
# tmux: panes in $T/tmux/panes as "<pane>\t<pid>\t<session>\t<name>"; a
# capture with -e draws the input box (typed.<pane>), Enter on /exit* ends the pid
cat > "$T/bin/tmux" <<'EOF'
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
    printf 'routed the t1 post\n❯ \n'
    if [ "$esc" = 1 ]; then printf '────────\n❯ %s\n────────\n' "$(cat "$T/tmux/typed.$tgt" 2>/dev/null)"; fi ;;
  rename-window) awk -F'\t' -v OFS='\t' -v p="$tgt" -v n="${args[0]}" '$1 == p {$4 = n} {print}' "$P" > "$P.new" && mv "$P.new" "$P"
    echo "rename $tgt ${args[0]}" >> "$L" ;;
  send-keys) k="${args[0]}"; echo "keys $tgt $k" >> "$L"
    if [ "$lit" = 1 ]; then printf '%s' "$k" >> "$T/tmux/typed.$tgt"
    elif [ "$k" = C-u ] || [ "$k" = C-c ]; then : > "$T/tmux/typed.$tgt"
    elif [ "$k" = Enter ]; then
      if grep -q '^/exit' "$T/tmux/typed.$tgt" 2>/dev/null; then rm -rf "$T/proc/$(field 2)"; fi
      : > "$T/tmux/typed.$tgt"
    fi ;;
  kill-window) awk -F'\t' -v p="$tgt" '$1 != p' "$P" > "$P.new" && mv "$P.new" "$P"; echo "kill $tgt" >> "$L" ;;
  *) echo "tmux stub: $cmd" >&2; exit 1 ;;
esac
EOF
# spawn-window.sh <kind> <ID> <workdir> <seed> <slug> -> "<ID> <pane>"
cat > "$T/bin/spawn" <<'EOF'
#!/usr/bin/env bash
id="$2"; n="${id##*-}"; pid=$(( 3000 + 10#$n )); pane="%3$n"
echo "spawn $1 $2 $5 SPAWN_REUSE_ID=${SPAWN_REUSE_ID:-} seed=$4" >> "$T/spawn.log"
mode="$(cat "$T/spawn.mode.$id" 2>/dev/null || echo ok)"
[ "$mode" = nopane ] && { echo "spawn-window: no pane"; exit 4; }
printf '%s\t%s\t$0\t%s@sat\n' "$pane" "$pid" "$id" >> "$T/tmux/panes"
[ "$mode" = nostart ] || "$T/bin/proc" "$pid" "$id" "$1"
echo "$id $pane"
EOF
# ./run: the handoff sources, the alert legs, the poll loop start
cat > "$T/bin/run" <<'EOF'
#!/usr/bin/env bash
echo "$2 PEER_SEAT=${PEER_SEAT:-} ASK_KIND=${ASK_KIND:-} DESK_TO=${DESK_TO:-}" >> "$T/run.log"
case "$2" in
  do_spl_asks_open) echo '{"asks":[]}' ;;
  do_spl_lane_map) echo '{"lanes":[]}' ;;
  do_spl_ask_put|do_spl_desk_reply|do_spl_peer_poll) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/kill" <<'EOF'
#!/usr/bin/env bash
echo "kill $*" >> "$T/kill.log"; rm -rf "$T/proc/$2"
EOF
cat > "$T/bin/ai" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  adopt) echo "adopt $2 $3" >> "$T/ai.log"; echo "$3" > "$T/ai.$2" ;;
  pane-of) p="$(cat "$T/ai.$2" 2>/dev/null)"; [ -n "$p" ] && [ -d "$T/proc/$p" ] || exit 1
    awk -F'\t' -v p="$p" '$2 == p {print $1; exit}' "$T/tmux/panes" ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "❯ \\n"\n' > "$T/bin/footer"
cat > "$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
# the action, as ./run runs it: set -E and an ERR trap that ends the run
cat > "$T/bin/act" <<'EOF'
#!/usr/bin/env bash
set -E
trap 'echo "ERRTRAP: $BASH_COMMAND (line $LINENO)"; exit 99' ERR
do_log() { echo "$*"; }
do_require_bin() { return 0; }
for f in spl-peer-crons spl-peer-distill spl-peer-restart-install-cron spl-peer-distill-install-cron spl-peer-ensure-install-cron; do
  source "$PROJ_PATH/src/bash/run/$f.func.sh"
done
"$1" || exit $?
EOF
chmod +x "$T/bin/"*

export T PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" SPOOL_TEST=1 SPOOL_DESK_BOX=box-desk PEER_BOX=sat \
  LEASE_PROC_ROOT="$T/proc" LEASE_PANE_CMD="$T/bin/footer" ROTATE_TMUX="$T/bin/tmux" ROTATE_SPAWN="$T/bin/spawn" ROTATE_RUN="$T/bin/run" \
  ROTATE_KILL="$T/bin/kill" ROTATE_AI="$T/bin/ai" ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/mem" PEER_RUN="$T/bin/run" \
  ROTATE_AS_AGENT_DIRECT=1 ROTATE_POLL=1 ROTATE_IDLE_SEC=0 ROTATE_EXIT_SETTLE=1 ROTATE_TERM_WAIT=2 ROTATE_NEW_EXIT_WAIT=2 \
  PEER_START_WAIT=3 PEER_EXIT_WAIT=4 PEER_POKE_SETTLE=0
unset SPOOL_BOX_TAG SPOOL_AGENT_ID PEER_RESTART_OFFSET CLAUDE_BIN

# the world: four seats, each a live session in its own pane (c-001 pid 101 in %1 ...)
SEATS="c-001 c-002 g-003 g-004"
world() {
  rm -rf "$T/proc/"[0-9]* "$T/tmux/"* "$T/"*.log "$T/spawn.mode."* "$T/ai."* "$D"/rotate.* "$S/peer" "$S"/[cg]-00*
  printf 'LEASE_ENV=prd\nLEASE_TENANT=t1\nASKS_OWNER=HUM-10\n' > "$D/lease.conf"
  mkdir -p "$S/peer"
  local s n h
  for s in $SEATS; do
    n=$((10#${s#*-})); h=claude; [[ "$s" == g-* ]] && h=grok
    echo "$s $h" >> "$S/peer/seats"
    mkdir -p "$S/$s/inbox" "$S/$s/outbox"
    "$T/bin/proc" "$((100 + n))" "$s" "$h"
    printf '%%%s\t%s\t$0\t%s@sat\n' "$n" "$((100 + n))" "$s" >> "$T/tmux/panes"
  done
}
# loop <id>: a running poll loop of <id> (holds poll.run, its pid in poll.pid)
loop() {
  local d="$S/peer/$1"; mkdir -p "$d"
  setsid bash -c 'exec 7> "$1"; flock 7; echo $$ > "$2"; echo $$ > "$3"; exec sleep 300' _ "$d/poll.run" "$d/poll.pid" "$T/loop.$1.pid" &
  for _ in $(seq 1 30); do [[ -s "$d/poll.pid" ]] && break; sleep 0.1; done
}
alive() { [[ -d "$T/proc/$1" ]]; }
win() { awk -F'\t' -v p="$1" '$1 == p {print $4}' "$T/tmux/panes"; }
waitfor() { for _ in $(seq 1 50); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
at() { echo $((T0 + $1 * 60)); }   # the epoch of minute <m> of the hour
summary() {  # summary <id> <file content source cmd...>: a fresh distilled.md
  local d="$S/$1/handoff"; mkdir -p "$d"; shift
  echo "$((T0 - 300))" > "$d/distill.poked"; "$@" > "$d/distilled.md"; touch -d "@$((T0 - 200))" "$d/distilled.md"
}
between() { sed -n '/^<!-- distilled:begin -->$/,/^<!-- distilled:end -->$/p' "$1" | sed '1d;$d'; }

# --- 1. slot -> seat ------------------------------------------------------------
# shellcheck source=../run/spl-peer-crons.func.sh
( do_log() { :; }; source "$PROJ_ROOT/src/bash/run/spl-peer-crons.func.sh"
  bad=""
  for off in 0 7; do
    declare -A own=()
    for m in $(seq 0 59); do s="$(spl_peer_slot_seat "$m" "$off")"; own[$s]=$(( ${own[$s]:-0} + 1 )); done
    for s in 1 2 3 4; do
      [[ "${own[$s]}" == 15 ]] || bad+=" off$off:seat$s=${own[$s]}min"
      m="$(spl_peer_slot_minute "$s" "$off")"
      [[ "$(spl_peer_slot_seat "$m" "$off")" == "$s" ]] || bad+=" off$off:slot$m"
      # the distill fires 5 min before the slot and names that slot's seat
      [[ "$(spl_peer_slot_seat "$(( (m + 55) % 60 + 5 ))" "$off")" == "$s" ]] || bad+=" off$off:distill-before-$m"
    done
    unset own
  done
  got="$(for m in 0 15 30 45; do spl_peer_slot_seat "$m" 0; done; for m in 7 22 37 52; do spl_peer_slot_seat "$m" 7; done)"
  [[ "$(tr '\n' ' ' <<<"$got")" == "1 2 3 4 1 2 3 4 " ]] || bad+=" table:$(tr '\n' ' ' <<<"$got")"
  # a line that starts late still names its own seat; minutes 0..6 belong to seat 4 at offset 7
  [[ "$(spl_peer_slot_seat 3 0) $(spl_peer_slot_seat 3 7) $(spl_peer_slot_seat 59 0)" == "1 4 4" ]] || bad+=" late"
  export PEER_RESTART_OFFSET=0; s0="$(spl_peer_cron_sched restart)|$(spl_peer_cron_sched distill)"
  PEER_RESTART_OFFSET=7; s7="$(spl_peer_cron_sched restart)|$(spl_peer_cron_sched distill)|$(spl_peer_cron_sched ensure)"
  [[ "$s0" == "0,15,30,45 * * * *|10,25,40,55 * * * *" ]] || bad+=" sched0=$s0"
  [[ "$s7" == "7,22,37,52 * * * *|2,17,32,47 * * * *|* * * * *" ]] || bad+=" sched7=$s7"
  [[ -z "$bad" ]] && echo OK || echo "$bad" ) > "$T/o" 2>&1
[[ "$(cat "$T/o")" == OK ]] && pass "1. slot -> seat: n=60 minutes x 2 offsets, 15 min per seat, 001..004 at :00/:15/:30/:45 and :07/:22/:37/:52, distill names the next slot's seat, schedules" ||
  fail "1. slot -> seat:$(cat "$T/o")"
world
LEASE_NOW="$(at 22)" PEER_RESTART_OFFSET=7 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q 'GATE PLAN seat c-002 (claude): pid 102 in %2' "$T/o" && [[ ! -e "$T/spawn.log" && ! -e "$D/rotate.log" ]] &&
  pass "1. the action at :22, offset 7: a dry run naming c-002, nothing touched" || fail "1. dry run rc=$rc: $(cat "$T/o")"

# --- 2. inert ---------------------------------------------------------------------
mkdir -p "$T/empty"
SPOOL_ROOT="$T/empty" LEASE_NOW="$T0" DRY_RUN=0 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1; r1=$?
SPOOL_ROOT="$T/empty" LEASE_NOW="$(at 55)" DRY_RUN=0 "$T/bin/act" do_spl_peer_distill >> "$T/o" 2>&1; r2=$?
[[ $r1 == 0 && $r2 == 0 && -z "$(find "$T/empty" -mindepth 1)" ]] && pass "2. inert: no seat = restart and distill exit 0 and write nothing" ||
  fail "2. inert rc $r1/$r2, wrote: $(find "$T/empty" -mindepth 1 | sed -n 1,3p) $(cat "$T/o")"

# --- 3. a restart -------------------------------------------------------------------
world
loop c-001
lpid="$(cat "$S/peer/c-001/poll.pid")"
printf 'I was routing topic 1068e306.\nI hold msgs 8896800b and f2bf978c.\nWaiting on c-118 for the L3 fix.\nNext: answer HUM-10.\n' > "$T/sum.md"
summary c-001 cat "$T/sum.md"
LEASE_NOW="$T0" DRY_RUN=0 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1; rc=$?
seed="$(ls "$S/c-001/handoff/"*-peer-c-001.seed.md 2>/dev/null | sed -n 1p)"
hand="${seed%.seed.md}.md"
[[ $rc == 0 ]] && alive 3001 && ! alive 101 && grep -q ' DONE OK c-001@sat is pid 3001 in %3001' "$T/o" &&
  pass "3. restart at :00: c-001 is the fresh pid 3001, the old pid 101 is gone" || fail "3. restart rc=$rc: $(cat "$T/o")"
[[ "$(grep -c . "$T/spawn.log")" == 1 ]] && grep -q '^spawn claude c-001 peer-restart SPAWN_REUSE_ID=1 ' "$T/spawn.log" &&
  alive 102 && alive 103 && alive 104 && pass "3. only the slot's seat: one spawn (claude c-001, same id), the other three untouched" ||
  fail "3. spawns: $(cat "$T/spawn.log" 2>/dev/null)"
! kill -0 "$lpid" 2>/dev/null && grep -q ' LOOP OK the c-001 poll loop is stopped' "$T/o" &&
  pass "3. its running poll loop (pid $lpid) was stopped first" || fail "3. the loop survived: $(cat "$T/o")"
waitfor "$T/run.log" '^do_spl_peer_poll PEER_SEAT=c-001 ' && pass "3. its poll loop is started again" || fail "3. no loop start: $(cat "$T/run.log")"
[[ -s "$hand" ]] && ! grep -q '^- lease' "$hand" && grep -q '^## 2. In flight' "$hand" &&
  pass "3. the handoff: the 060 sections, no lease lines" || fail "3. handoff $hand: $(head -12 "$hand" 2>/dev/null)"
cmp -s <(between "$seed") "$T/sum.md" && grep -q '^## B. The mechanical handoff' "$seed" && [[ -e "$S/c-001/handoff/distilled.${seed##*/}" || -n "$(ls "$S/c-001/handoff/"distilled.*-peer-c-001.md 2>/dev/null)" ]] &&
  [[ ! -e "$S/c-001/handoff/distilled.md" ]] && pass "3. the seed holds the summary VERBATIM ($(wc -c < "$T/sum.md") bytes), then the handoff; the summary is consumed" ||
  fail "3. seed: $(cat "$seed" 2>/dev/null | sed -n 1,20p)"
grep -q 'keys %1 /exit-clean' "$T/tmux/log" && grep -q 'kill %1' "$T/tmux/log" && [[ "$(win %3001)" == c-001@sat ]] &&
  pass "3. the old session got /exit-clean, its window is closed, the new one is c-001@sat" || fail "3. retire: $(cat "$T/tmux/log")"
[[ "$(grep -c -- '-peer-c-001 ' "$D/rotate.log")" -ge 6 ]] && ! grep -q 'distill-missing' "$D/rotate.log" &&
  pass "3. one rotate.log line per step, no distill-missing" || fail "3. rotate.log: $(cat "$D/rotate.log")"

# --- 4. a failed start keeps the old one ------------------------------------------------
world
echo nostart > "$T/spawn.mode.c-002"
LEASE_NOW="$(at 15)" DRY_RUN=0 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1; rc=$?
[[ $rc == 1 ]] && alive 102 && [[ "$(win %2)" == c-002@sat && -z "$(win %3002)" ]] &&
  grep -q 'SPAWN FAIL no claude session carrying c-002 started in %3002 within 3s; the old session (pid 102) keeps the seat' "$T/o" &&
  pass "4. a fresh session that does not start: the old pid 102 keeps the seat and its window name, the new window is closed" ||
  fail "4. failed start rc=$rc win=$(win %2)/$(win %3002): $(cat "$T/o")"
grep -q '^do_spl_ask_put .*ASK_KIND=blocker' "$T/run.log" && grep -q '^do_spl_desk_reply .*DESK_TO=HUM-10' "$T/run.log" &&
  pass "4. alerted: an ask and an owner DM" || fail "4. alert: $(cat "$T/run.log")"
waitfor "$T/run.log" '^do_spl_peer_poll PEER_SEAT=c-002 ' && pass "4. the old session's poll loop is started again" || fail "4. no loop: $(cat "$T/run.log")"
grep -q "adopt c-002 102" "$T/ai.log" 2>/dev/null && pass "4. the identity map points at the old pid again" || fail "4. map: $(cat "$T/ai.log" 2>/dev/null)"

# --- 5. one seat at a time --------------------------------------------------------------
world
setsid bash -c 'exec 6>> "$1"; flock 6; echo $$ > "$2"; exec sleep 300' _ "$S/peer/restart.lock" "$T/loop.lock.pid" &
for _ in $(seq 1 30); do [[ -s "$T/loop.lock.pid" ]] && break; sleep 0.1; done
LEASE_NOW="$(at 30)" DRY_RUN=0 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1; rc=$?
[[ $rc == 0 && ! -e "$T/spawn.log" ]] && alive 103 && grep -q 'GATE SKIP another seat restart runs on this box' "$T/o" &&
  pass "5. one seat at a time: with a restart in flight the next one skips, nothing spawned" || fail "5. lock rc=$rc: $(cat "$T/o")"
kill -- "-$(cat "$T/loop.lock.pid")" 2>/dev/null; rm -f "$T/loop.lock.pid"

# --- 6. the distill poke reaches only the seat due next -----------------------------------
dpoke() {  # dpoke <minute> <expected pane> <expected id> [env...]
  rm -f "$T/tmux/log" "$T"/tmux/typed.* "$S"/*/handoff/distill.poked
  env LEASE_NOW="$(at "$1")" DRY_RUN=0 "${@:4}" "$T/bin/act" do_spl_peer_distill > "$T/o" 2>&1 || return 1
  [[ "$(grep -c '^keys ' "$T/tmux/log")" == 2 && "$(grep -c "^keys $2 " "$T/tmux/log")" == 2 ]] || return 1
  grep -q "^keys $2 Enter" "$T/tmux/log" && grep -qF "keys $2 SEAT DISTILL: your seat $3 restarts at" "$T/tmux/log" &&
    grep -qF "$S/$3/handoff/distilled.md" "$T/tmux/log" || return 1
  [[ "$(ls "$S"/*/handoff/distill.poked | wc -l)" == 1 && -s "$S/$3/handoff/distill.poked" ]]
}
world
ok=1 got=""
dpoke 55 %1 c-001 PEER_RESTART_OFFSET=0 || { ok=0; got+=" :55/0 $(cat "$T/tmux/log" 2>/dev/null)"; }
dpoke 10 %2 c-002 PEER_RESTART_OFFSET=0 || { ok=0; got+=" :10/0"; }
dpoke 40 %4 g-004 PEER_RESTART_OFFSET=0 || { ok=0; got+=" :40/0"; }
echo PEER_RESTART_OFFSET=7 > "$S/peer/peer.conf"
dpoke 2 %1 c-001 || { ok=0; got+=" :02/peer.conf=7 $(cat "$T/o")"; }
dpoke 32 %3 g-003 || { ok=0; got+=" :32/peer.conf=7"; }
(( ok )) && pass "6. distill: n=5 pokes (:55 :10 :40 at offset 0, :02 :32 at offset 7 from peer.conf), each typed into ONLY the next slot's pane, naming its own distilled.md" ||
  fail "6. distill:$got"
grep -q '^keys %3 .*restarts at :37' "$T/tmux/log" && grep -q '^keys %3 .*At most 40 lines and 4096 bytes' "$T/tmux/log" &&
  pass "6. the poke names the slot and the caps" || fail "6. poke text: $(cat "$T/tmux/log")"

# --- 7. the seed: caps, missing, stale --------------------------------------------------------
world
seedof() { ls "$S/$1/handoff/"*-peer-"$1".seed.md 2>/dev/null | tail -1; }
summary c-002 seq -f 'line %g of a long summary' 1 60
LEASE_NOW="$(at 15)" DRY_RUN=0 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1
s="$(seedof c-002)"; between "$s" > "$T/cut"
[[ "$(wc -l < "$T/cut")" -le 40 && "$(wc -c < "$T/cut")" -le 4096 && "$(tail -1 "$T/cut")" == "[cut]" ]] &&
  cmp -s <(sed '$d' "$T/cut") <(seq -f 'line %g of a long summary' 1 39) &&
  pass "7. 60 lines: cut at the line cap (39 whole lines + [cut] = 40)" || fail "7. line cap: $(wc -l < "$T/cut") lines: $(tail -3 "$T/cut")"
world
summary c-001 bash -c 'for i in $(seq 1 10); do printf "%04d-%0995d\n" "$i" 0; done'
LEASE_NOW="$T0" DRY_RUN=0 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1
between "$(seedof c-001)" > "$T/cut"
[[ "$(wc -c < "$T/cut")" -le 4096 && "$(tail -1 "$T/cut")" == "[cut]" && "$(sed '$d' "$T/cut" | awk 'length($0) != 1000' | wc -l)" == 0 &&
   "$(wc -l < "$T/cut")" == 5 ]] && pass "7. 10 x 1000 bytes: cut at the byte cap on whole lines (4 lines + [cut], $(wc -c < "$T/cut") bytes)" ||
  fail "7. byte cap: $(wc -c < "$T/cut") bytes, $(wc -l < "$T/cut") lines"
world
LEASE_NOW="$(at 30)" DRY_RUN=0 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1; rc=$?
s="$(seedof g-003)"
[[ $rc == 0 ]] && alive 3003 && [[ "$(cat "$T/proc/3003/comm")" == grok ]] && grep -q '^spawn grok g-003 ' "$T/spawn.log" &&
  grep -q '^## A. Your own summary: none (no distill poke)' "$s" && grep -q '^## B. The mechanical handoff' "$s" &&
  [[ "$(grep -c 'WARN distill-missing g-003' "$D/rotate.log")" == 1 ]] &&
  pass "7. no summary: the grok seat g-003 restarts on the mechanical handoff alone, ONE 'WARN distill-missing g-003' in rotate.log" ||
  fail "7. missing rc=$rc: $(cat "$T/o") -- $(cat "$D/rotate.log" 2>/dev/null)"
world
summary g-004 echo "an old summary"
touch -d "@$((T0 - 900))" "$S/g-004/handoff/distilled.md"
LEASE_NOW="$(at 45)" DRY_RUN=0 "$T/bin/act" do_spl_peer_restart > "$T/o" 2>&1
grep -q 'none (distilled.md older than the poke)' "$(seedof g-004)" && ! grep -q 'an old summary' "$(seedof g-004)" &&
  [[ "$(grep -c 'WARN distill-missing g-004' "$D/rotate.log")" == 1 ]] &&
  pass "7. a summary older than the poke is not used: one WARN distill-missing g-004" || fail "7. stale: $(cat "$D/rotate.log")"

# --- 8. the crontab fixture before / after ----------------------------------------------------
SH="$T/shared"; SC="$SH/csi-spl-orc/src/bash/scripts"; L="$T/log"
mkdir -p "$SC" "$SH/csi-spl-orc/src/bash/features/box-sessions/scripts" "$L"
git init -q "$SH"
for f in desk-reconcile orch-rotate dispatch-rotate unanswered-sweep agent-boot-restore agent-identity-reconcile; do
  printf '#!/bin/sh\n' > "$SC/$f-cron.sh"; chmod +x "$SC/$f-cron.sh"
done
printf '#!/bin/sh\n' > "$SH/csi-spl-orc/run"; printf '#!/bin/sh\n' > "$SH/csi-spl-orc/src/bash/features/box-sessions/scripts/save-sessions.sh"
chmod +x "$SH/csi-spl-orc/run"
for n in restart distill ensure; do cp "$PROJ_ROOT/src/bash/scripts/peer-$n-cron.sh" "$SC/"; done
# the 9 tags measured on the first box (spec 068 6.2) + a box-cron row, same shapes
cat > "$T/crontab.before" <<EOF
MAILTO=""
# operator note: keep
*/5 * * * * cd $SH && git fetch -q origin master && git checkout -q --detach origin/master; ENV=dev TENANT_ID=t1 $SC/desk-reconcile-cron.sh >> $L/cron.out 2>&1 # csi-spl:desk-reconcile
1-59/5 * * * * ENV=prd TENANT_ID=t1 $SC/desk-reconcile-cron.sh >> $L/cron-prd.out 2>&1 # csi-spl:desk-reconcile-prd
5 * * * * $SC/orch-rotate-cron.sh >> $L/orch.out 2>&1 # csi-spl:orch-rotate
15 * * * * $SC/dispatch-rotate-cron.sh >> $L/dispatch.out 2>&1 # csi-spl:dispatch-rotate
*/10 * * * * $SC/unanswered-sweep-cron.sh >> $L/sweep.out 2>&1 # csi-spl:unanswered-sweep
@reboot $SC/agent-boot-restore-cron.sh >> $L/boot.out 2>&1 # csi-spl:agent-boot-restore
17 * * * * cd $SH/csi-spl-orc && ./run -a do_spl_agent_id_reap >> $L/reap.out 2>&1 # csi-spl:agent-id-reap
*/2 * * * * $SC/agent-identity-reconcile-cron.sh >> $L/idr.out 2>&1 # csi-spl:agent-identity-reconcile
0 6 * * 1 cd $SH/csi-spl-orc && ./run -a do_check_pre_push_lint >> $L/scan.out 2>&1 # csi-spl:weekly-full-scan
* * * * * /bin/bash '$SH/csi-spl-orc/src/bash/features/box-sessions/scripts/save-sessions.sh' >> '$L/save.log' 2>&1 # csi-spl:box-cron:box-save-sessions
EOF
[[ "$(grep -oE '# csi-spl:[a-z-]+$' "$T/crontab.before" | grep -vc box-cron)" == 9 ]] || fail "8. fixture: not 9 tags"
cp "$T/crontab.before" "$T/crontab"
crons() { env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SH" PEER_CRON_LOG_DIR="$L/peer" "$@"; }
crons "$T/bin/act" do_spl_peer_crons > "$T/o" 2>&1; rc=$?
[[ $rc == 0 ]] && cmp -s "$T/crontab" "$T/crontab.before" && [[ ! -e "$S/peer/crons.applied" ]] &&
  [[ "$(grep -cE '^  \+[^+].*# csi-spl:peer-(restart|distill|ensure)$' "$T/o")" == 3 ]] &&
  [[ "$(grep -cE '^  -[^-].*# csi-spl:(orch-rotate|dispatch-rotate|unanswered-sweep)$' "$T/o")" == 3 ]] &&
  grep -q 'APPLY=1 ./run -a do_spl_peer_crons' "$T/o" &&
  pass "8. default = dry run: the diff (+3 peer tags, -3 old), the exact APPLY=1 command, nothing written" || fail "8. dry rc=$rc: $(cat "$T/o")"
mv "$S/peer/seats" "$S/peer/seats.off"
crons APPLY=1 "$T/bin/act" do_spl_peer_crons > "$T/o" 2>&1; rc=$?
[[ $rc == 1 ]] && cmp -s "$T/crontab" "$T/crontab.before" && [[ ! -e "$S/peer/crons.applied" ]] && grep -q 'FATAL no seat in' "$T/o" &&
  pass "8. APPLY=1 on a box with no seat is refused, nothing changed" || fail "8. no-seat gate rc=$rc: $(cat "$T/o")"
mv "$S/peer/seats.off" "$S/peer/seats"
crons APPLY=1 "$T/bin/act" do_spl_peer_crons > "$T/o" 2>&1; rc=$?
{ grep -vE '# csi-spl:(orch-rotate|dispatch-rotate|unanswered-sweep)$' "$T/crontab.before"
  echo "0,15,30,45 * * * * $SC/peer-restart-cron.sh >> $L/peer/restart.out 2>&1 # csi-spl:peer-restart"
  echo "10,25,40,55 * * * * $SC/peer-distill-cron.sh >> $L/peer/distill.out 2>&1 # csi-spl:peer-distill"
  echo "* * * * * $SC/peer-ensure-cron.sh >> $L/peer/ensure.out 2>&1 # csi-spl:peer-ensure"; } > "$T/crontab.want"
[[ $rc == 0 ]] && cmp -s "$T/crontab" "$T/crontab.want" && grep -q '^applied ' "$S/peer/crons.applied" && [[ -d "$L/peer" ]] &&
  pass "8. APPLY=1: the crontab after = before - 3 old tags + 3 peer tags, every other line byte for byte ($(grep -c . "$T/crontab") lines), the desk-reconcile marker written" ||
  fail "8. apply rc=$rc: $(diff "$T/crontab.want" "$T/crontab") $(cat "$T/o")"
cp "$T/crontab" "$T/crontab.after"
crons APPLY=1 "$T/bin/act" do_spl_peer_crons > "$T/o" 2>&1
cmp -s "$T/crontab" "$T/crontab.after" && grep -q '(no change)' "$T/o" && pass "8. APPLY=1 again: no change (idempotent)" || fail "8. idempotent: $(diff "$T/crontab.after" "$T/crontab")"
cp "$T/crontab.before" "$T/crontab"
crons PEER_RESTART_OFFSET=7 "$T/bin/act" do_spl_peer_crons > "$T/o" 2>&1
grep -qE '^  \+7,22,37,52 \* \* \* \* .*# csi-spl:peer-restart$' "$T/o" && grep -qE '^  \+2,17,32,47 \* \* \* \* .*# csi-spl:peer-distill$' "$T/o" &&
  pass "8. offset 7: restart at 7,22,37,52 and distill at 2,17,32,47" || fail "8. offset 7: $(cat "$T/o")"
: > "$T/crontab"; ok=1
for n in restart distill ensure; do
  cp "$T/crontab" "$T/crontab.pre"
  crons "$T/bin/act" "do_spl_peer_${n}_install_cron" > "$T/o" 2>&1 && cmp -s "$T/crontab" "$T/crontab.pre" &&
    grep -qE "^    \+.*# csi-spl:peer-$n\$" "$T/o" || { ok=0; echo "dry $n: $(cat "$T/o")"; }
  crons DRY_RUN=0 "$T/bin/act" "do_spl_peer_${n}_install_cron" > "$T/o" 2>&1 || { ok=0; echo "install $n: $(cat "$T/o")"; }
  crons DRY_RUN=0 "$T/bin/act" "do_spl_peer_${n}_install_cron" > /dev/null 2>&1
  crons PEER_CRON_ACTION=check "$T/bin/act" "do_spl_peer_${n}_install_cron" > "$T/o" 2>&1 || { ok=0; echo "check $n: $(cat "$T/o")"; }
done
cmp -s "$T/crontab" <(grep -E '# csi-spl:peer-' "$T/crontab.want") || { ok=0; echo "lines: $(diff <(grep -E '# csi-spl:peer-' "$T/crontab.want") "$T/crontab")"; }
crons CRON_REMOVE=1 DRY_RUN=0 "$T/bin/act" do_spl_peer_distill_install_cron > /dev/null 2>&1
[[ "$(grep -c . "$T/crontab")" == 2 ]] && ! grep -q peer-distill "$T/crontab" || { ok=0; echo "remove: $(cat "$T/crontab")"; }
(( ok )) && pass "8. the three _install_cron actions: dry run writes nothing, install twice = one exact line each, check passes, CRON_REMOVE=1 takes only its own line" ||
  fail "8. installers"

# --- 9. acceptance 8.1 -------------------------------------------------------------------------
# shellcheck disable=SC2034 # SPL_ORG_APP is read by spl_peer_cron_8_1
c81() { ( do_log() { :; }; source "$PROJ_ROOT/src/bash/run/spl-peer-crons.func.sh"; SPL_ORG_APP=csi-spl; spl_peer_cron_8_1 "$1" ); }
c81 "$T/crontab.before" > "$T/o81b"; rb=$?
c81 "$T/crontab.after" > "$T/o81a"; ra=$?
[[ $rb == 0 && $ra == 0 ]] && grep -qx 'OK 8.1 10 command line(s), 0 failing' "$T/o81b" && grep -qx 'OK 8.1 10 command line(s), 0 failing' "$T/o81a" &&
  pass "9. acceptance 8.1: before n=10 and after n=10 command lines each resolve into a csi-spl checkout, 0 failing" ||
  fail "9. 8.1: before rc=$rb $(cat "$T/o81b") / after rc=$ra $(cat "$T/o81a")"
mkdir -p "$T/adhoc"; printf '#!/bin/sh\n' > "$T/adhoc/loop.sh"; chmod +x "$T/adhoc/loop.sh"
{ cat "$T/crontab.after"; echo "*/5 * * * * $T/adhoc/loop.sh >> /dev/null 2>&1"; echo "@reboot /var/tmp/gone/launch.sh"; echo "0 1 * * * tmux new -d"; } > "$T/crontab.bad"
c81 "$T/crontab.bad" > "$T/o"; rc=$?
[[ $rc == 1 ]] && grep -q "^FAIL 8.1 line 13: $T/adhoc/loop.sh is in no csi-spl checkout" "$T/o" &&
  grep -q '^FAIL 8.1 line 14: /var/tmp/gone/launch.sh resolves nowhere' "$T/o" && grep -q '^FAIL 8.1 line 15: no script path' "$T/o" &&
  grep -qx 'FAIL 8.1 13 command line(s), 3 failing' "$T/o" &&
  pass "9. the failing control: a script outside any checkout, one under /var/tmp that is gone, a line with no script - each named by line" ||
  fail "9. control rc=$rc: $(cat "$T/o")"
cp "$T/crontab.before" "$T/crontab"
crons APPLY=0 "$T/bin/act" do_spl_peer_crons > "$T/o" 2>&1
grep -q '^  OK 8.1 10 command line(s), 0 failing' "$T/o" && pass "9. do_spl_peer_crons prints 8.1 on the crontab after" || fail "9. not printed: $(cat "$T/o")"

# --- 10. the desk-reconcile cut ------------------------------------------------------------------
DR="$T/drc"; mkdir -p "$DR/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" "$DR/csi-spl-orc/src/bash/scripts/"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/drc.log"\n' "$T" > "$DR/csi-spl-orc/run"; chmod +x "$DR/csi-spl-orc/run"
drc() { rm -f "$T/drc.log"; env SPOOL_ROOT="$T/drspool" DESK_CRON_TOOLS=true DESK_TRUNK_CHECK=0 ENV=dev TENANT_ID=t1 \
  bash "$DR/csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh" > "$T/o" 2>&1; }
mkdir -p "$T/drspool/peer"
drc
grep -q 'do_spl_dispatch_lease' "$T/drc.log" && grep -q 'do_spl_dispatch_tick' "$T/drc.log" && grep -q 'do_spl_desk_up_all' "$T/drc.log" &&
  pass "10. no marker (today): the reconcile runs the lease ensure and the dispatch tick, as before" || fail "10. control: $(cat "$T/drc.log" 2>/dev/null)"
echo "applied x" > "$T/drspool/peer/crons.applied"
drc
! grep -q 'do_spl_dispatch_lease' "$T/drc.log" && ! grep -q 'do_spl_dispatch_tick' "$T/drc.log" && grep -q 'do_spl_desk_up_all' "$T/drc.log" &&
  grep -q 'do_spl_desk_welcome' "$T/drc.log" && grep -q 'the lease ensure and the dispatch tick are cut' "$T/o" &&
  pass "10. marker written by APPLY=1: the lease ensure and the dispatch tick are cut, the desk steps still run" || fail "10. cut: $(cat "$T/drc.log") $(cat "$T/o")"

# --- 11. the cron scripts ---------------------------------------------------------------------------
printf '#!/usr/bin/env bash\necho "$* DRY_RUN=${DRY_RUN:-}" >> "%s/cronrun.log"\n' "$T" > "$SH/csi-spl-orc/run"
ok=1
for n in restart distill ensure; do
  PEER_CRON_TOOLS=true bash "$SC/peer-$n-cron.sh" > "$T/o" 2>&1 || { ok=0; echo "$n: $(cat "$T/o")"; }
done
[[ "$(cat "$T/cronrun.log")" == $'-a do_spl_peer_restart DRY_RUN=0\n-a do_spl_peer_distill DRY_RUN=0\n-a do_spl_peer_ensure DRY_RUN=' ]] || { ok=0; echo "ran: $(cat "$T/cronrun.log")"; }
PEER_CRON_TOOLS=no-such-tool-x bash "$SC/peer-restart-cron.sh" > "$T/o" 2>&1; rc=$?
[[ $rc == 3 ]] && grep -q no-such-tool-x "$T/o" || { ok=0; echo "tools rc=$rc"; }
(( ok )) && pass "11. the cron scripts run their action from the checkout (restart, distill with DRY_RUN=0), and name a missing tool (exit 3)" ||
  fail "11. cron scripts"

echo
(( fails == 0 )) && { echo "peer-restart: all passed"; exit 0; }
echo "peer-restart: $fails failure(s)"; exit 1
