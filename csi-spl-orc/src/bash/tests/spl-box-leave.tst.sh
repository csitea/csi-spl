#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_leave / do_spl_box_join (spec 064 L9, owner Q8: "global
#          drain oneliner, and a oneliner for starting as well"). One machine
#          (pc) of a two-machine fleet (pc,sat) drains; a fake /proc holds its
#          agents, the hub is a stub with the `spool lease` contract, the note
#          sender is a stub (a lane "exits" when its note arrives, unless it is
#          listed as never exiting), tmux's pane list is a stub, the
#          lease-loop restart is a stub, and the lanes' worktrees are real git
#          worktrees of a clone of a local bare origin.
#   1. 0 lanes: spawns refused (marker), pc ranked last in lease.conf, the
#      loop restarted once, both role leases handed to sat at once and kept
#      because sat's loop renewed them, no note, SAFE TO SWITCH OFF, exit 0
#   2. a spawn on a draining box is refused by spawn-window.sh: exit 6, one
#      line naming the drain and do_spl_box_join
#   3. join after the drain: marker gone, lease.conf back byte for byte, the
#      loop restarted, one JOINED line; spawn-window no longer refuses
#   4. 1 lane, pushed, exits on its note: one note, table yes|yes, SAFE
#  4b. stale rows get no note (PC dry run 2026-10-03): a live id whose pane is
#      gone, a live id whose pane is another session's window; an agent with
#      no worktree of its own (agy, main checkout) is a lane, pushed n/a
#   5. 3 lanes, one never exits (and holds an unpushed commit): it is waited
#      for, then NOT SAFE: 1 agents still running, exit 3, its hold dir named
#   6. leave again (idempotent): no second note, the saved original kept, the
#      ranking and the roles left as they are
#   7. DRY_RUN=1 (leave and join): WOULD lines, nothing written, exit 0
#   8. join on a machine that never left changes nothing
#   9. the next box in rank has no live lease loop (box-desk on the PC,
#      2026-10-03): it does not renew, so it is skipped and the next live box
#      gets the role; no live box at all: the role is kept here, with a WARN
#  Fixtures only in a mktemp root: the test refuses to run where its roots
#  could reach the live /var/spool-hub.
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
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
export SPOOL_TEST=1
S="$T/spool"; D="$S/dispatch"
mkdir -p "$T/bin" "$T/hub" "$T/proc" "$D" "$T/hold"

# The note stub: logs "<to> :: <body>", and the lane exits (its fake process
# goes) unless its id is in $T/never.
cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
grep -qx -- "$to" "$NEVER" 2>/dev/null && exit 0
for p in "$PROCS"/[0-9]*; do grep -qzx "SPOOL_AGENT_ID=$to" "$p/environ" 2>/dev/null && rm -rf "$p"; done
exit 0
STUB
# The hub stub (as fleet-lease.tst.sh): "holder gen at mark" per fleet+role.
# A box listed in $HUB_DIR/live runs a lease loop: a role written to it (mark
# w) is renewed by it before the next read (gen + 1, mark r), as its tick would.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
shift
fleet="" role="" holder="" ifgen=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; esac; shift 2; done
f="$HUB_DIR/$fleet.$role"; h="" g=0 at=0 mk=r
[ -s "$f" ] && read -r h g at mk <"$f"
if [ -z "$holder" ] && [ "$mk" = w ] && grep -qx -- "${h##*@}" "$HUB_DIR/live" 2>/dev/null; then
  g=$((g + 1)); mk=r; echo "$h $g $at $mk" >"$f"
fi
won=false
if [ -n "$holder" ] && [ "$ifgen" = "$g" ]; then g=$((g + 1)); h="$holder"; at=0; echo "$h $g $at w" >"$f"; won=true; fi
age=-1; [ "$g" -gt 0 ] && age=0
printf '{"fleet":"%s","role":"%s","holder":"%s","box":"b","gen":%s,"age_s":%s,"won":%s}\n' "$fleet" "$role" "$h" "$g" "$age" "$won"
STUB
printf '#!/usr/bin/env bash\necho ensure >>"%s/ensure.log"\n' "$T" >"$T/bin/ensure"
chmod +x "$T/bin/send" "$T/bin/hub" "$T/bin/ensure"

cat >"$D/lease.conf" <<'EOF'
LEASE_MASTER=c-002
LEASE_FAILOVER=c-003
LEASE_ORCH=c-001
LEASE_FLEET=main
LEASE_PRIORITY=pc,sat
LEASE_ENV=prd
LEASE_TENANT=t1
EOF
cp "$D/lease.conf" "$T/lease.conf.orig"
echo "c-001@pc 4 0" >"$T/hub/main.orch"
echo "c-002@pc 7 0" >"$T/hub/main.dispatch"
echo sat >"$T/hub/live"

# agent <pid> <id> [rundir]: a live claude process carrying SPOOL_AGENT_ID, and its registry row
agent() {
  mkdir -p "$T/proc/$1"; echo claude >"$T/proc/$1/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$T/proc/$1/environ"
  printf '%s\tclaude\t%%%s\t%s\t20261003T000000Z\n' "$2" "$1" "${3:-/nonexistent/$2}" >>"$S/registry.tsv"
  printf '%%%s %s\n' "$1" "${4-$2@pc}" >>"$T/panes"
}
G=(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master)
"${G[@]}" init -q --bare "$T/origin.git"
"${G[@]}" clone -q "$T/origin.git" "$T/seed" 2>/dev/null
"${G[@]}" -C "$T/seed" commit -q --allow-empty -m seed && "${G[@]}" -C "$T/seed" push -q origin HEAD:master 2>/dev/null
# wt <name> [unpushed]: a lane's worktree, pushed, or with one local commit
wt() {
  "${G[@]}" -C "$T/seed" worktree add -q -b "$1" "$T/$1" origin/master 2>/dev/null
  [[ "${2:-}" == unpushed ]] && "${G[@]}" -C "$T/$1" commit -q --allow-empty -m local
  echo "$T/$1"
}

# run <action> [env...]: the action as ./run would call it, output to $T/o, rc to $T/rc
run() {
  local a="$1"; shift
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" LEASE_PROC_ROOT="$T/proc" LEASE_MACHINE=pc LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" \
    BOX_LEAVE_SEND="$T/bin/send" BOX_LEAVE_ENSURE_CMD="$T/bin/ensure" SENT="$T/sent" NEVER="$T/never" PROCS="$T/proc" \
    ROTATE_HOLD_DIR="$T/hold" DRAIN_SECS=0 DRAIN_POLL=1 BOX_LEAVE_RENEW_WAIT=1 BOX_LEAVE_RENEW_POLL=1 \
    BOX_LEAVE_PANES_CMD="cat $T/panes" SPOOL_AGENT_ID= "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-box-join.func.sh"
    '"$a" >"$T/o" 2>&1
  echo $? >"$T/rc"
}
rc() { cat "$T/rc"; }
has() { grep -qF -- "$1" "$T/o"; }
last() { tail -1 "$T/o"; }
sentc() { cat "$T/sent" 2>/dev/null | grep -c .; }
ensc() { cat "$T/ensure.log" 2>/dev/null | grep -c .; }
hubh() { cut -d' ' -f1 "$T/hub/main.$1"; }
spawn() {
  SPOOL_ROOT="$S" SPOOL_TMUX_SOCKET="$T/no-tmux.sock" SPOOL_SESSION='' \
    bash "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-window.sh" claude auto "$T" >"$T/so" 2>&1
  echo $? >"$T/src"
}

# the role seats run on pc; they are no lanes
agent 100 c-001; agent 101 c-002; agent 102 c-003

# ---- 1. 0 lanes ---------------------------------------------------------------
run do_spl_box_leave
[[ "$(rc)" == 0 && "$(last)" == "SAFE TO SWITCH OFF" ]] && pass "1. 0 lanes: SAFE TO SWITCH OFF, exit 0" || fail "1. verdict: rc=$(rc) $(cat "$T/o")"
[[ -s "$D/box.leave" ]] && pass "1. the drain marker is written" || fail "1. no marker"
grep -qx 'LEASE_PRIORITY=sat,pc' "$D/lease.conf" && cmp -s "$D/box-leave/lease.conf.before" "$T/lease.conf.orig" &&
  pass "1. pc ranked last; the original lease.conf saved" || fail "1. ranking: $(grep PRIORITY "$D/lease.conf")"
[[ "$(ensc)" == 1 ]] && pass "1. the lease loop restarted once on the new ranking" || fail "1. ensure count $(ensc)"
[[ "$(hubh orch)" == c-001@sat && "$(hubh dispatch)" == c-002@sat ]] && has "orch handed to sat: c-001@sat renewed it" &&
  pass "1. both role leases handed to sat at once (no stale wait)" || fail "1. hub: $(hubh orch) $(hubh dispatch)"
[[ "$(sentc)" == 0 ]] && has "no lane agents on pc" && pass "1. no note to a role seat" || fail "1. sent: $(cat "$T/sent" 2>/dev/null)"

# ---- 2. a spawn on a draining box is refused --------------------------------
spawn
[[ "$(cat "$T/src")" == 6 && "$(grep -c . "$T/so")" == 1 ]] && grep -q 'this machine is draining .*do_spl_box_join' "$T/so" &&
  pass "2. spawn-window refuses on a draining box: exit 6, one line" || fail "2. spawn: rc=$(cat "$T/src") $(cat "$T/so")"

# ---- 3. join after the drain --------------------------------------------------
run do_spl_box_join
[[ "$(rc)" == 0 && ! -e "$D/box.leave" ]] && pass "3. join: the marker is gone" || fail "3. join: rc=$(rc) $(cat "$T/o")"
cmp -s "$D/lease.conf" "$T/lease.conf.orig" && [[ ! -e "$D/box-leave/lease.conf.before" ]] &&
  pass "3. lease.conf back byte for byte" || fail "3. lease.conf: $(cat "$D/lease.conf")"
[[ "$(ensc)" == 2 ]] && pass "3. the loop restarted on the restored ranking" || fail "3. ensure count $(ensc)"
last | grep -qx 'JOINED: pc takes agents again; lease rank orch 1/2 dispatch 1/2' &&
  pass "3. one JOINED status line" || fail "3. output: $(cat "$T/o")"
spawn
[[ "$(cat "$T/src")" != 6 ]] && ! grep -q draining "$T/so" && pass "3. spawn-window no longer refuses after join" || fail "3. spawn: $(cat "$T/so")"

# ---- 4. 1 lane, pushed, exits on its note -------------------------------------
agent 200 c-200 "$(wt l200)"
echo "c-001@pc 8 0" >"$T/hub/main.orch"
run do_spl_box_leave
[[ "$(rc)" == 0 && "$(last)" == "SAFE TO SWITCH OFF" ]] && pass "4. 1 lane that exits: SAFE, exit 0" || fail "4. rc=$(rc) $(cat "$T/o")"
[[ "$(sentc)" == 1 ]] && grep -q '^c-200 :: drain: push your work, write your hold note, report, exit' "$T/sent" &&
  grep -qF "$T/hold/drain-pc/c-200.md" "$T/sent" && pass "4. ONE drain note, naming its hold note" || fail "4. sent: $(cat "$T/sent")"
has "c-200 | yes | yes | " && pass "4. table: pushed yes, exited yes" || fail "4. table: $(cat "$T/o")"
[[ "$(hubh orch)" == c-001@sat ]] && pass "4. the orch lease taken back here is handed again" || fail "4. orch $(hubh orch)"
run do_spl_box_join

# ---- 4b. stale rows, and an agent with no worktree of its own -------------------
: >"$T/sent"
agent 63 c-063; sed -i '/^%63 /d' "$T/panes"
agent 33 c-033 "" "csitea relay"
agent 85 a-085 "$T/seed"
run do_spl_box_leave
[[ "$(rc)" == 0 ]] && has "stale row, no note: c-063: its pane %63 is gone from this box's tmux" &&
  has "stale row, no note: c-033: pane %33 is window 'csitea relay', not this lane" && has "lanes on pc: 1 (a-085)" &&
  pass "4b. a gone pane and another session's window are stale rows" || fail "4b. stale: rc=$(rc) $(cat "$T/o")"
[[ "$(sentc)" == 1 ]] && grep -q '^a-085 :: drain' "$T/sent" && pass "4b. no note to a stale row" || fail "4b. sent: $(cat "$T/sent")"
has "a-085 | n/a (no own worktree) | yes" && pass "4b. no own worktree: pushed n/a" || fail "4b. table: $(cat "$T/o")"
run do_spl_box_join

# ---- 5. 3 lanes, one never exits ----------------------------------------------
: >"$T/sent"
agent 300 c-300 "$(wt l300)"; agent 301 c-301 "$(wt l301)"; agent 302 c-302 "$(wt l302 unpushed)"
echo c-302 >"$T/never"
start=$(date +%s)
run do_spl_box_leave DRAIN_SECS=2
took=$(( $(date +%s) - start ))
[[ "$(rc)" == 3 && "$(last)" == "NOT SAFE: 1 agents still running" ]] && pass "5. one lane never exits: NOT SAFE: 1, exit 3" || fail "5. rc=$(rc) $(cat "$T/o")"
(( took >= 2 )) && has "waiting: 1 still running (c-302)" && pass "5. it was waited for (DRAIN_SECS)" || fail "5. no wait (${took}s)"
[[ "$(sentc)" == 3 ]] && ! grep -q '^c-0[36]3 ' "$T/sent" && pass "5. one note to each of the 3 lanes, none to a stale row" || fail "5. sent $(sentc)"
has "c-302 | no (1 unpushed, 0 dirty) | no | $T/hold/drain-pc/c-302.md (none)" && has "c-300 | yes | yes" &&
  pass "5. the runner listed with its unpushed commit and its hold dir" || fail "5. table: $(cat "$T/o")"

# ---- 6. leave again: idempotent -----------------------------------------------
cp "$D/lease.conf" "$T/lc.drained"
run do_spl_box_leave
[[ "$(rc)" == 3 && "$(sentc)" == 3 ]] && has "c-302: drain note already sent" && pass "6. again: no second note" || fail "6. sent $(sentc) $(cat "$T/o")"
cmp -s "$D/lease.conf" "$T/lc.drained" && cmp -s "$D/box-leave/lease.conf.before" "$T/lease.conf.orig" &&
  has "ranking already puts pc last" && has "orch held by c-001@sat - nothing to hand" &&
  pass "6. again: ranking, saved original and roles left as they are" || fail "6. $(cat "$T/o")"

# ---- 7. DRY_RUN=1 ---------------------------------------------------------------
run do_spl_box_join DRY_RUN=1
[[ "$(rc)" == 0 && -e "$D/box.leave" ]] && cmp -s "$D/lease.conf" "$T/lc.drained" && has "WOULD take agents here again" &&
  pass "7. join DRY_RUN=1: WOULD, nothing removed" || fail "7. join dry: $(cat "$T/o")"
run do_spl_box_join
rm -f "$T/never"; echo "c-001@pc 20 0" >"$T/hub/main.orch"; e0=$(ensc); : >"$T/sent"
run do_spl_box_leave DRY_RUN=1
[[ "$(rc)" == 0 && ! -e "$D/box.leave" && "$(sentc)" == 0 && "$(ensc)" == "$e0" && "$(hubh orch)" == c-001@pc ]] &&
  cmp -s "$D/lease.conf" "$T/lease.conf.orig" && pass "7. leave DRY_RUN=1: nothing written, sent or handed" || fail "7. leave dry: $(cat "$T/o")"
has "WOULD refuse every spawn" && has "WOULD LEASE_PRIORITY=pc,sat -> sat,pc" && has "orch: WOULD hand c-001@pc -> c-001@sat" &&
  has "c-302: WOULD send the drain note" && last | grep -qx 'DRY_RUN=1: nothing changed; right now: NOT SAFE: 1 agents still running' &&
  pass "7. leave DRY_RUN=1 prints what it would do" || fail "7. dry output: $(cat "$T/o")"

# ---- 8. join on a machine that never left ---------------------------------------
e0=$(ensc)
run do_spl_box_join
[[ "$(rc)" == 0 && "$(ensc)" == "$e0" ]] && cmp -s "$D/lease.conf" "$T/lease.conf.orig" && has "already taken here" &&
  pass "8. join on a machine that never left changes nothing" || fail "8. $(cat "$T/o")"

# ---- 9. a dead box next in rank ---------------------------------------------------
run do_spl_box_join
sed -i 's/^LEASE_PRIORITY=.*/LEASE_PRIORITY=pc,dead,sat/' "$D/lease.conf"
echo "c-001@pc 30 0" >"$T/hub/main.orch"; echo "c-002@pc 30 0" >"$T/hub/main.dispatch"
run do_spl_box_leave
has "orch: dead did not renew it within 1s (no live lease loop there) - skipped" &&
  has "orch handed to sat: c-001@sat renewed it (skipped, no renewal: dead)" && [[ "$(hubh orch)" == c-001@sat && "$(hubh dispatch)" == c-002@sat ]] &&
  pass "9. a box with no live lease loop is skipped; the next live box holds the roles" || fail "9. dead: $(cat "$T/o")"
grep -q 'BOX-LEAVE orch: pc handed orch to sat (c-001@sat renewed it), skipped dead' "$D/lease.log" && pass "9. the hand-over is in lease.log" || fail "9. lease.log"
run do_spl_box_join
: >"$T/hub/live"
echo "c-001@pc 40 0" >"$T/hub/main.orch"
run do_spl_box_leave
[[ "$(hubh orch)" == c-001@pc ]] && has "orch: WARN no other box renewed it (tried dead sat) - kept on pc" &&
  pass "9. no live box: the role is kept here, with a WARN" || fail "9. none live: $(hubh orch) $(cat "$T/o")"
run do_spl_box_join

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
