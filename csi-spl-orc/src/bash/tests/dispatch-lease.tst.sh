#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dispatch_lease (SPEC-spool-fleet-roles.md section 4). No live
#          agent is touched: a fake /proc (LEASE_PROC_ROOT) holds the agents, a
#          fake clock (LEASE_NOW) drives the ages, the spool sender is a stub.
#   1. renew binds the master BY ID, writes the lease, logs the bind once
#   2. a relaunched master (new pid) is followed with no manual step
#   3. no live master process = no renewal, logged once
#   4. no promotion while the master renews
#   5. promotion after 180 s of silence, logged + told once, kept fresh
#   6. handback when the master renews, logged + told once
#   7. a dead failover is never promoted; logged + told once
#   8. a non-claude process carrying the id does not count
#   9. lease.conf supplies the ids; ensure without it starts nothing
#  10. ensure starts both loops once, is idempotent, and restarts them after
#      they die (the reboot case); stop ends them
#  11. the desk reconcile cron calls ensure
#  13. the live failover test of 2026-10-01, replayed: renew stops, the
#      watcher (60 s ticks) promotes at 199 s, renew restarts, handback on the
#      next watcher tick
#  14. ensure returns at once to a caller that pipes it (run.sh's tee + `| cat`)
#  15. ensure refuses a tree whose lease code is not trunk's
#  16. ensure replaces a loop that runs older code; stop works by pid file
#  12. bad LEASE_CMD / LEASE_PERIOD are refused
#  17. an agent of ANOTHER user (environ unreadable to the box user, CLE-77907)
#      is found through its owner: renew binds it, live_ids lists it, and
#      with the hop off it is not seen (the 2026-10-01 GAP)
#  18. a STALLED master (CLE-77935, the 2026-10-02 usage-limit pane): its
#      process lives, its footer shows "Usage limit reached" under a turn
#      whose spinner is frozen, so renew stops once the spinner has not moved
#      for 45 s (logged once, with why), the failover is promoted after
#      180 s, and the master's own renewal is the handback; controls (the
#      04:09Z false positive): the banner under an idle "done" line, or under a
#      turn whose timer moves, is able; no pane at all is able (fail open); a
#      modal trust screen is a stall on sight, and a stalled failover is not
#      promoted
#  18b. a master IDLE at its usage limit (t1 865b7a05, the satellite on
#      2026-10-03: "Usage limit reached · resets 10:50am", no spinner) stops
#      renewing at once with the reset in the why; the failover takes over
#      after 180 s; once the reset time has passed (same pane, banner still
#      shown) the master renews again and the renewal is the handback;
#      a banner with no readable reset time is a stall unless the last
#      reply is a good one (spec 093 FR-000), with that good reply as control
#  18c. the "Teach auto mode about your environment?" modal (2026-10-04):
#      a pane without it is able and no Escape is sent; a mention of the
#      title above an idle prompt, and the title alone with no picker line,
#      stay able and send no Escape; with the new list emptied the old
#      matchers miss the dialog and the seat stays able; with the list, the
#      seat is not able, Escape is sent once, the orchestrator is told once,
#      and the lease fails over
#  19. LEASE_PRIORITY_ORCH / _DISPATCH rank one role each (lease.conf or env);
#      unset = LEASE_PRIORITY; validated the same way
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'LEASE_CMD=stop lease >/dev/null 2>&1; rm -rf "$T"' EXIT

P="$T/proc" D="$T/spool/dispatch"
mkdir -p "$P" "$T/bin"
cat >"$T/bin/send" <<'EOF'
#!/usr/bin/env bash
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
EOF
# The pane stub (LEASE_PANE_CMD): the screen of pid N is $T/pane/N; no file =
# no pane, which the lease reads as able (fail open). A banner's reset time is
# read in LEASE_LIMIT_TZ=Etc/GMT-3 (the boxes' summer offset), never this box's.
mkdir -p "$T/pane"
printf '#!/usr/bin/env bash\ncat "%s/pane/$1" 2>/dev/null\n' "$T" >"$T/bin/pane"
chmod +x "$T/bin/send" "$T/bin/pane"

# agent <pid> <id> [comm] / kill_agent <pid>
agent() { mkdir -p "$P/$1"; echo "${3:-claude}" >"$P/$1/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$2" >"$P/$1/environ"; }
kill_agent() { rm -rf "${P:?}/$1"; }

lease() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" LEASE_AGENT_RUN="${LEASE_AGENT_RUN:-0}" LEASE_PROC_ROOT="$P" LEASE_SEND="$T/bin/send" SENT="$T/sent" LEASE_PANE_CMD="$T/bin/pane" \
    LEASE_MASTER="${LM-M-1}" LEASE_FAILOVER="${LF-F-1}" LEASE_ORCH="${LO-O-1}" LEASE_LIMIT_TZ=Etc/GMT-3 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init || exit 1
    main() { if [ -n "${TICK:-}" ]; then spl_lease_ids master failover orch && "spl_lease_${TICK}_tick"; else do_spl_dispatch_lease; fi; }
    # WRAP_TEE: the output plumbing run.sh gives every action
    if [ -n "${WRAP_TEE:-}" ]; then main > >(tee -a /dev/null) 2> >(tee -a /dev/null >&2); else main; fi'
}
tick() { local verb="$1" now="$2"; shift 2; lease TICK="$verb" LEASE_NOW="$now" "$@" >/dev/null 2>&1; }
holder() { cut -d' ' -f1 "$D/lease"; }
logc() { grep -c -- "$1" "$D/lease.log" 2>/dev/null || true; }
sentc() { grep -c -- "$1" "$T/sent" 2>/dev/null || true; }

# --- 1. renew binds by id ------------------------------------------------------------
agent 100 M-1; agent 200 F-1; agent 300 X-9
tick renew 1000
[[ "$(cat "$D/lease")" == "M-1 1000" && "$(logc 'renew bind M-1 pid=100')" == 1 ]] &&
  pass "1. renew finds the master by SPOOL_AGENT_ID and writes the lease" || fail "1. lease '$(cat "$D/lease" 2>&1)' log: $(cat "$D/lease.log" 2>&1)"
tick renew 1060
[[ "$(cat "$D/lease")" == "M-1 1060" && "$(logc 'renew bind')" == 1 ]] &&
  pass "1. a second tick renews and logs nothing new" || fail "1. second tick: $(cat "$D/lease.log")"

# --- 2. relaunch -> rebind ----------------------------------------------------------
kill_agent 100; agent 150 M-1
tick renew 1120
[[ "$(cat "$D/lease")" == "M-1 1120" && "$(logc 'renew bind M-1 pid=150')" == 1 ]] &&
  pass "2. a relaunched master is followed (pid 100 -> 150)" || fail "2. rebind: $(cat "$D/lease.log")"

# --- 3/4. no master process -> no renewal; no promotion while fresh ----------------
kill_agent 150
tick renew 1180; tick renew 1240
[[ "$(cat "$D/lease")" == "M-1 1120" && "$(logc 'renew stop M-1')" == 1 ]] &&
  pass "3. no live master: no renewal, logged once" || fail "3. lease '$(cat "$D/lease")' log: $(cat "$D/lease.log")"
tick watch 1300
[[ "$(holder)" == M-1 && "$(logc FAILOVER)" == 0 && ! -s "$T/sent" ]] &&
  pass "4. 180 s exactly is not stale: no promotion" || fail "4. promoted early: $(cat "$D/lease.log")"

# --- 5. promotion after 180 s ------------------------------------------------------
tick watch 1301
tick watch 1361
[[ "$(cat "$D/lease")" == "F-1 1361" && "$(logc 'FAILOVER: M-1 silent 181s -> F-1 active')" == 1 ]] &&
  pass "5. the failover is promoted after 181 s and kept fresh" || fail "5. lease '$(cat "$D/lease")' log: $(cat "$D/lease.log")"
[[ "$(sentc '^F-1 :: DISPATCH LEASE: you are now ACTIVE')" == 1 && "$(sentc '^O-1 :: DISPATCH LEASE: failover F-1 took over')" == 1 ]] &&
  pass "5. failover + orchestrator told once" || fail "5. sent: $(cat "$T/sent")"

# --- 6. handback ---------------------------------------------------------------------
agent 160 M-1
tick renew 1400
tick watch 1410; tick watch 1470
[[ "$(holder)" == M-1 && "$(logc 'handback to M-1')" == 1 && ! -e "$D/lease.failover" ]] &&
  pass "6. the master's renewal is the handback, logged once" || fail "6. lease '$(cat "$D/lease")' log: $(cat "$D/lease.log")"
[[ "$(sentc '^F-1 :: DISPATCH LEASE: STANDBY')" == 1 && "$(sentc '^O-1 :: DISPATCH LEASE: master M-1 is back')" == 1 ]] &&
  pass "6. STANDBY + orchestrator note sent once" || fail "6. sent: $(cat "$T/sent")"

# --- 7. a dead failover is never promoted --------------------------------------------
kill_agent 160; kill_agent 200
tick watch 1800; tick watch 1860
[[ "$(holder)" == M-1 && "$(logc 'NO-FAILOVER')" == 1 && "$(sentc 'nobody dispatches')" == 1 ]] &&
  pass "7. dead failover: no promotion, logged + told once" || fail "7. lease '$(cat "$D/lease")' log: $(cat "$D/lease.log")"
agent 210 F-1
tick watch 1920
[[ "$(holder)" == F-1 && "$(logc ' FAILOVER: M-1')" == 2 && ! -e "$D/lease.nofailover" ]] &&
  pass "7. the failover is promoted once it lives again" || fail "7. revived: $(cat "$D/lease.log")"
kill_agent 210
tick watch 2200
[[ "$(cat "$D/lease")" == "F-1 1920" ]] &&
  pass "7. a failover that died while holding is not kept fresh" || fail "7. lease '$(cat "$D/lease")'"

# --- 8. only claude processes count ---------------------------------------------------
agent 400 M-1 bash
tick renew 2300
[[ "$(holder)" == F-1 ]] && pass "8. a bash process with the id does not renew" || fail "8. bash renewed: $(cat "$D/lease")"
kill_agent 400

# --- 9. lease.conf -----------------------------------------------------------------------
rm -rf "$T/spool"; mkdir -p "$D"
LM='' LF='' LO='' lease LEASE_CMD=ensure >"$T/o" 2>&1
[[ $? -eq 0 && ! -e "$D/renew.run" ]] && grep -q 'runs no dispatch lease' "$T/o" &&
  pass "9. no lease.conf: ensure starts nothing" || fail "9. $(cat "$T/o")"
printf 'LEASE_MASTER=M-1\nLEASE_FAILOVER=F-1\nLEASE_ORCH=O-1\nLEASE_MASTER=$(touch %s/pwned)\n' "$T" >"$D/lease.conf"
agent 500 M-1
LM='' LF='' LO='' tick renew 3000
[[ "$(cat "$D/lease")" == "M-1 3000" && ! -e "$T/pwned" ]] &&
  pass "9. ids come from lease.conf, which is read and never sourced" || fail "9. conf: $(cat "$D/lease" 2>&1)"

# --- 10. ensure: start, idempotent, restart after death ------------------------------
cat >"$T/bin/run" <<EOF
#!/usr/bin/env bash
do_log() { echo "\$*"; }
source "$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh"
do_spl_dispatch_lease
EOF
chmod +x "$T/bin/run"
# this tree may hold unmerged edits of the lease code; section 15 tests that refusal
E=(LEASE_RUN="$T/bin/run" LEASE_PERIOD=1 LEASE_ALLOW_STALE=1)
alive() { local v; for v in renew watch; do flock -n "$D/$v.run" true 2>/dev/null && return 1; done; return 0; }
# both loops hold their lock AND have written pid + version (the files are
# written just after the lock is taken)
ready() { alive && local v && for v in renew watch; do [[ -s "$D/$v.pid" && -s "$D/$v.ver" ]] || return 1; done; }
fresh() { rm -f "$D"/renew.pid "$D"/watch.pid "$D"/renew.ver "$D"/watch.ver; }
waitfor() { local i; for i in $(seq 1 50); do "$@" && return 0; sleep 0.1; done; return 1; }
LM='' LF='' LO='' lease LEASE_CMD=ensure "${E[@]}" >"$T/o" 2>&1
waitfor ready && [[ "$(grep -c 'loop started' "$T/o")" == 2 ]] &&
  pass "10. ensure starts renew + watch" || fail "10. start: $(cat "$T/o" "$D"/*.out 2>&1)"
p1="$(cat "$D/renew.pid")"
LM='' LF='' LO='' lease LEASE_CMD=ensure "${E[@]}" >"$T/o" 2>&1
[[ "$(grep -c 'loop running' "$T/o")" == 2 && "$(grep -c 'loop started' "$T/o")" == 0 && "$(cat "$D/renew.pid")" == "$p1" ]] &&
  pass "10. a second ensure starts nothing" || fail "10. idempotent: $(cat "$T/o")"
LM='' LF='' LO='' timeout 10 bash -c "$(declare -f lease); $(declare -p T P D PROJ_ROOT); lease LEASE_CMD=renew ${E[*]}" >"$T/o" 2>&1
grep -q 'already runs' "$T/o" && pass "10. a second renew loop exits at once" || fail "10. dup loop: $(cat "$T/o")"
waitfor bash -c "grep -q '^M-1 ' '$D/lease'" && pass "10. the started renew loop renews" || fail "10. no renewal: $(cat "$D/lease.log")"
LM='' LF='' LO='' lease LEASE_CMD=stop >/dev/null 2>&1
dead() { ! flock -n "$D/renew.run" true 2>/dev/null && return 1; ! flock -n "$D/watch.run" true 2>/dev/null && return 1; return 0; }
waitfor dead && pass "10. stop ends both loops (the reboot)" || fail "10. still running after stop"
fresh
LM='' LF='' LO='' lease LEASE_CMD=ensure "${E[@]}" >"$T/o" 2>&1
waitfor ready && [[ "$(grep -c 'loop started' "$T/o")" == 2 && "$(cat "$D/renew.pid")" != "$p1" ]] &&
  pass "10. the next ensure brings both back" || fail "10. restart: $(cat "$T/o")"
LM='' LF='' LO='' lease LEASE_CMD=stop >/dev/null 2>&1; waitfor dead; fresh

# --- 14. a piped caller is not held ------------------------------------------------------
t0=$(date +%s)
LM='' LF='' LO='' timeout 20 bash -c "$(declare -f lease); $(declare -p T P D PROJ_ROOT); lease LEASE_CMD=ensure WRAP_TEE=1 ${E[*]} 2>&1 | cat" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && $(( $(date +%s) - t0 )) -lt 10 ]] && grep -q 'loop started' "$T/o" &&
  pass "14. 'ensure | cat' under run.sh's tee returns at once" || fail "14. rc=$rc after $(( $(date +%s) - t0 ))s: $(cat "$T/o")"
waitfor ready || fail "14. the loops did not start: $(ls -la "$D"; tail -5 "$D/lease.log"; cat "$D"/watch.out "$D"/renew.out)"

# --- 16. old code is replaced, stop by pid file ---------------------------------------------
p1="$(cat "$D/renew.pid")"; echo oldcode >"$D/renew.ver"
LM='' LF='' LO='' lease LEASE_CMD=ensure "${E[@]}" >"$T/o" 2>&1
newpid() { alive && [[ -s "$D/renew.pid" && "$(cat "$D/renew.pid")" != "$p1" ]]; }
waitfor newpid && [[ "$(logc 'ensure replaces renew (code oldcode')" == 1 ]] && ! kill -0 "$p1" 2>/dev/null &&
  pass "16. a loop on older code is replaced" || fail "16. replace: $(cat "$T/o") $(tail -3 "$D/lease.log")"
LM='' LF='' LO='' lease LEASE_CMD=stop >/dev/null 2>&1
dead && [[ "$(logc 'stop renew pid=')" -ge 1 ]] && pass "16. stop ends both loops by pid file" || fail "16. stop"

# --- 15. a stale tree is refused --------------------------------------------------------------
G="$T/gitfix"; mkdir -p "$G/orc/src/bash/run"
cp "$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh" "$G/orc/src/bash/run/"
git -C "$G" init -q && git -C "$G" add . && git -C "$G" -c user.name=t -c user.email=t@example.com commit -q -m fix &&
  git -C "$G" update-ref refs/remotes/origin/master HEAD
stale() {
  env PROJ_PATH="$G/orc" SPOOL_ROOT="$T/spool" LEASE_RUN=/bin/true "$@" bash -c '
    do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; LEASE_CMD=ensure do_spl_dispatch_lease'
}
stale >"$T/o" 2>&1 && grep -q 'loop started' "$T/o" && pass "15. a tree on trunk's lease code starts the loops" || fail "15. on trunk: $(cat "$T/o")"
echo '# local edit' >>"$G/orc/src/bash/run/spl-dispatch-lease.func.sh"
rm -f "$D"/*.run
stale >"$T/o" 2>&1 && fail "15. a stale tree was accepted: $(cat "$T/o")" ||
  { grep -q "not origin/master's version" "$T/o" && [[ "$(logc 'REFUSED ensure from a stale tree')" == 1 ]] &&
    pass "15. a tree whose lease code is not trunk's is refused, and logged" || fail "15. refusal: $(cat "$T/o")"; }
stale LEASE_ALLOW_STALE=1 >"$T/o" 2>&1 && pass "15. LEASE_ALLOW_STALE=1 overrides" || fail "15. override: $(cat "$T/o")"

# --- 11. the cron tick ensures the loops ------------------------------------------------
grep -q 'LEASE_CMD=ensure .*do_spl_dispatch_lease' "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" &&
  pass "11. desk-reconcile-cron.sh ensures the lease loops every tick" || fail "11. the cron does not call ensure"

# --- 12. refusals ---------------------------------------------------------------------------
lease LEASE_CMD=nope >/dev/null 2>&1 && fail "12. bad LEASE_CMD accepted" || pass "12. bad LEASE_CMD refused"
lease LEASE_CMD=show LEASE_PERIOD=0 >/dev/null 2>&1 && fail "12. LEASE_PERIOD=0 accepted" || pass "12. LEASE_PERIOD=0 refused"
echo 'M-1 3000' >"$D/lease"
out="$(lease LEASE_CMD=show LEASE_NOW=3010 2>&1)"
[[ "$out" == "M-1 10" ]] && pass "12. show prints holder and age" || fail "12. show: $out"

# --- 13. the 2026-10-01 live sequence ------------------------------------------------------
rm -rf "$T/spool" "$T/sent"; mkdir -p "$D"; rm -rf "${P:?}"/*
agent 700 M-1; agent 800 F-1
tick renew 10000
kill_agent 700
for t in 10019 10079 10139; do tick watch $t; done
[[ "$(holder)" == M-1 && ! -s "$T/sent" ]] && pass "13. ticks at 19/79/139 s: no promotion" || fail "13. early: $(cat "$D/lease.log")"
tick watch 10199
[[ "$(cat "$D/lease")" == "F-1 10199" && "$(logc 'FAILOVER: M-1 silent 199s -> F-1 active')" == 1 && "$(sentc '^F-1 :: DISPATCH LEASE: you are now ACTIVE')" == 1 ]] &&
  pass "13. promoted at 199 s (180 s + up to one tick)" || fail "13. promote: $(cat "$D/lease.log")"
agent 701 M-1
tick renew 10233
tick watch 10259
[[ "$(holder)" == M-1 && "$(logc 'handback to M-1')" == 1 && "$(sentc '^F-1 :: DISPATCH LEASE: STANDBY')" == 1 ]] &&
  pass "13. renew restarts, handback on the next watcher tick" || fail "13. handback: $(cat "$D/lease.log")"
[[ "$(wc -l <"$T/sent")" == 4 ]] && pass "13. four notes, no repeats" || fail "13. sent: $(cat "$T/sent")"

# --- 17. an agent of another user: its environ is the owner's only ------------------------
if [[ "$(id -u)" == 0 ]]; then echo "SKIP: 17. root reads every environ"; else
rm -rf "$T/spool" "$T/sent"; mkdir -p "$D"; rm -rf "${P:?}"/*
# other <pid> <id>: the real environ unreadable, the owner's view in environ.priv
other() { agent "$1" "$2"; mv "$P/$1/environ" "$P/$1/environ.priv"; printf 'HOME=/x\0' >"$P/$1/environ"; chmod 000 "$P/$1/environ"; }
cat >"$T/bin/hop" <<'EOF2'
#!/usr/bin/env bash
shift; a=(); for x in "$@"; do [[ "$x" == */environ ]] && x="$x.priv"; a+=("$x"); done
echo "hop ${a[*]}" >>"$HOPLOG"; exec "${a[@]}"
EOF2
chmod +x "$T/bin/hop"
other 900 M-1; other 901 F-1; agent 902 X-9
tick renew 20000 SPOOL_OWNER_HOP=force SPOOL_OWNER_HOP_CMD="$T/bin/hop" HOPLOG="$T/hops"
[[ "$(cat "$D/lease")" == "M-1 20000" && "$(logc 'renew bind M-1 pid=900')" == 1 ]] &&
  pass "17. renew binds a master whose environ only its owner reads" || fail "17. lease '$(cat "$D/lease" 2>&1)' log: $(cat "$D/lease.log" 2>&1)"
[[ "$(wc -l <"$T/hops")" == 1 ]] && pass "17. one owner hop for the whole walk" || fail "17. hops: $(cat "$T/hops")"
ids="$(env PROJ_PATH="$PROJ_ROOT" LEASE_PROC_ROOT="$P" SPOOL_OWNER_HOP=force SPOOL_OWNER_HOP_CMD="$T/bin/hop" HOPLOG="$T/hops" bash -c '
  do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_live_ids' | tr '\n' ' ')"
[[ "$ids" == "F-1 M-1 X-9 " ]] && pass "17. live_ids lists the other user's agents too" || fail "17. live_ids: '$ids'"
tick renew 20060 SPOOL_OWNER_HOP=0
[[ "$(cat "$D/lease")" == "M-1 20000" && "$(logc 'renew stop M-1')" == 1 ]] &&
  pass "17. control: with the hop off the master is not seen (the GAP)" || fail "17. control: $(cat "$D/lease.log")"
chmod -R u+rwX "$P"
fi

# --- 18. a stalled master: alive, but not able to act ----------------------------------------
rm -rf "$T/spool" "$T/sent"; mkdir -p "$D"; rm -rf "${P:?}"/* "$T/pane"/*
# the footer of CLE-002's pane at 2026-10-02 03:54Z, as tmux capture-pane printed
# it; <line> replaces the spinner line (default: the frozen one it showed)
stall() {
  { echo "${2:-✢ Cogitating… (12s · ↓ 214 tokens)}"; cat <<'EOF2'

──────────────────────────────────────────────────────────── box: CLE-002 ─
❯ [channel post from HUM-10, topic 5fe56859] a
────────────────────────────────────────────────────────────────────────────
  ⚠ Usage limit reached · limit resets 7:20am
    Continuing automatically at 7:20am · esc to cancel · /usage-credits to continue now
  ⏵⏵ auto mode on · gh auth login for PR status · 3 monitors
EOF2
  } >"$T/pane/$1"
}
idle() { printf '● done\n\n────\n❯ \n────\n  ⏵⏵ auto mode on\n' >"$T/pane/$1"; }
agent 1000 M-1; agent 1100 F-1; idle 1000; idle 1100
tick renew 30000
[[ "$(cat "$D/lease")" == "M-1 30000" ]] && pass "18. an idle master renews" || fail "18. idle: $(cat "$D/lease.log")"
stall 1000
tick renew 30060
[[ "$(cat "$D/lease")" == "M-1 30060" ]] && pass "18. a first sighting of the banner is no proof: still renews" || fail "18. first sighting: $(cat "$D/lease.log")"
tick renew 30120; tick renew 30180
[[ "$(cat "$D/lease")" == "M-1 30060" && "$(logc 'renew stop M-1 (stalled pid=1000: Usage limit reached, turn frozen 60s at (12s · ↓ 214 tokens))')" == 1 ]] &&
  pass "18. banner + a spinner frozen 60 s stops the renewal, logged once with why" || fail "18. stall: lease '$(cat "$D/lease")' log: $(cat "$D/lease.log")"
tick watch 30241
[[ "$(holder)" == F-1 && "$(logc 'FAILOVER: M-1 silent 181s -> F-1 active')" == 1 && "$(sentc '^F-1 :: DISPATCH LEASE: you are now ACTIVE')" == 1 ]] &&
  pass "18. the failover is promoted 180 s after the last renewal" || fail "18. promote: $(cat "$D/lease.log")"
# the 04:09Z false positive: the turn ended, the banner stayed under the prompt
stall 1000 '✻ Brewed for 16s · done 7.14 · 5 monitors still running'
tick renew 30300; tick watch 30310
[[ "$(holder)" == M-1 && "$(logc 'handback to M-1')" == 1 && "$(logc 'renew bind M-1 pid=1000')" == 2 ]] &&
  pass "18. control: banner under an idle 'done' line is able; the renewal is the handback" || fail "18. handback: $(cat "$D/lease.log")"
stall 1000 '✶ Cogitating… (12s · ↓ 214 tokens)'; tick renew 30360
stall 1000 '✢ Musing… (1m 13s · ↓ 2.1k tokens)'; tick renew 30420
[[ "$(cat "$D/lease")" == "M-1 30420" && "$(logc 'renew stop M-1')" == 1 ]] &&
  pass "18. control: banner over a turn whose timer moves is able" || fail "18. working: $(cat "$D/lease.log")"
rm -f "$T/pane/1000"
tick renew 30480
[[ "$(cat "$D/lease")" == "M-1 30480" ]] && pass "18. control: no pane found = able (fail open)" || fail "18. no pane: $(cat "$D/lease.log")"
trust() { printf ' Do you trust the files in this folder?\n ❯ 1. Yes, proceed\n   2. No, exit\n' >"$T/pane/$1"; }
trust 1000; trust 1100
tick renew 30540
[[ "$(cat "$D/lease")" == "M-1 30480" && "$(logc 'renew stop M-1 (stalled pid=1000: Do you trust the files)')" == 1 ]] &&
  pass "18. a modal trust screen is a stall on sight" || fail "18. trust: $(cat "$D/lease.log")"
tick watch 30661; tick watch 30721
[[ "$(holder)" == M-1 && "$(logc 'F-1 is not able to act (stalled pid=1100')" == 1 && "$(sentc 'nobody dispatches')" == 1 ]] &&
  pass "18. a stalled failover is not promoted; logged + told once" || fail "18. failover stall: $(cat "$D/lease.log")"

# --- 18b. a master idle at its usage limit (t1 865b7a05) -------------------------------
rm -rf "$T/spool" "$T/sent"; mkdir -p "$D"; rm -rf "${P:?}"/* "$T/pane"/*
# 2026-10-03 06:00Z = 09:00 at UTC+3; every poke answered by the banner, no turn
N=1791007200
limited() {
  cat >"$T/pane/$1" <<EOF2
❯ [channel post from HUM-10, topic 865b7a05] status?
  ⎿  ${2:-Usage limit reached · resets 10:50am}
     /upgrade to increase your usage limit.

──────────────────────────────────────────────────────────── box: c-002 ─
❯ 
────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on · 3 monitors
EOF2
}
agent 1000 M-1; agent 1100 F-1; idle 1000; idle 1100
tick renew $N
limited 1000; tick renew $((N + 60))
[[ "$(cat "$D/lease")" == "M-1 $N" && "$(logc 'renew stop M-1 (stalled pid=1000: Usage limit reached, resets in 109 min)')" == 1 ]] &&
  pass "18b. idle at the limit, reset ahead: renew stops on sight, logged once with the reset" || fail "18b. idle limit: lease '$(cat "$D/lease")' log: $(cat "$D/lease.log")"
[[ "$(cat "$D/able.M-1")" == "stalled pid=1000: Usage limit reached, resets in 109 min" ]] &&
  pass "18b. able.M-1 names the limit" || fail "18b. able: $(cat "$D/able.M-1")"
tick renew $((N + 120)); tick watch $((N + 181))
[[ "$(holder)" == F-1 && "$(logc 'FAILOVER: M-1 silent 181s -> F-1 active')" == 1 ]] &&
  pass "18b. the failover takes over 180 s after the last renewal" || fail "18b. promote: $(cat "$D/lease.log")"
# 07:51Z: the reset passed; the pane still shows the old banner (the stale case)
tick renew $((N + 6660)); tick watch $((N + 6670))
[[ "$(holder)" == M-1 && "$(logc 'handback to M-1')" == 1 ]] &&
  pass "18b. reset passed, banner still shown: the master renews again, the handback follows" || fail "18b. restore: $(cat "$D/lease.log")"
# spec 093 FR-000: a banner with no reset time and no spinner is a stall,
# unless the transcript's last assistant entry is a good reply (a stale banner)
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}\n' >"$T/good.jsonl"
printf '{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Usage limit reached"}]}}\n' >"$T/err.jsonl"
printf '#!/usr/bin/env bash\ncat "%s/$TR_FILE"\n' "$T" >"$T/bin/tr"; chmod +x "$T/bin/tr"
limited 1000 'Usage limit reached'; tick renew $((N + 6720)) LEASE_TRANSCRIPT_CMD="$T/bin/tr" TR_FILE=good.jsonl
[[ "$(cat "$D/lease")" == "M-1 $((N + 6720))" ]] &&
  pass "18b. control: a banner with no reset time under a good last reply still renews (stale banner)" || fail "18b. no time, good turn: $(cat "$D/lease.log")"
tick renew $((N + 6780)) LEASE_TRANSCRIPT_CMD="$T/bin/tr" TR_FILE=err.jsonl
[[ "$(cat "$D/lease")" == "M-1 $((N + 6720))" && "$(cat "$D/able.M-1")" == "stalled pid=1000: Usage limit reached, no spinner" ]] &&
  pass "18b. a banner with no reset time, no spinner, last reply an API error: renew stops (093 FR-000)" || fail "18b. no time, error: lease '$(cat "$D/lease")' able '$(cat "$D/able.M-1")'"

# --- 18c. the "Teach auto mode about your environment?" modal ----------------
rm -rf "$T/spool" "$T/sent" "$T/keys"; mkdir -p "$D"; rm -rf "${P:?}"/* "$T/pane"/*
cat >"$T/bin/keys" <<'EOF'
#!/usr/bin/env bash
printf '%s Escape\n' "$1" >>"$KEYS"
EOF
chmod +x "$T/bin/keys"
dialog() {
  # Claude Code 2.1.287: title, the body sentence, and the picker
  # Yes / Not now / Don't show again. Esc cancels (the "later" choice).
  cat >"$T/pane/$1" <<'EOF2'
╭──────────────────────────────────────────────╮
│ Teach auto mode about your environment?      │
│                                              │
│ Auto mode works better when it knows your    │
│ environment. Takes about a minute.           │
│                                              │
│ ❯ 1. Yes                                     │
│   2. Not now                                 │
│   3. Don't show again                        │
╰──────────────────────────────────────────────╯
  ⏵⏵ auto mode on
EOF2
}
agent 1000 M-1; agent 1100 F-1; idle 1000; idle 1100
K=(LEASE_KEYS_CMD="$T/bin/keys" KEYS="$T/keys" LEASE_MODAL_WAIT=0)
N=1792000000
tick renew "$N" "${K[@]}"
[[ "$(cat "$D/lease")" == "M-1 $N" && ! -s "$T/keys" ]] &&
  pass "18c. without the dialog the master is able and no Esc is sent" ||
  fail "18c. idle: lease '$(cat "$D/lease" 2>&1)' keys '$(cat "$T/keys" 2>/dev/null)'"
cat >"$T/pane/1000" <<'EOF2'
The seat sat in Teach auto mode about your environment? and a poke waited.
Don't show again only stops the offer. Esc cancels and chooses nothing.

────
❯ 
────
  ⏵⏵ auto mode on
EOF2
tick renew $((N + 30)) "${K[@]}"
[[ "$(cat "$D/lease")" == "M-1 $((N + 30))" && ! -s "$T/keys" ]] &&
  pass "18c. a mention above an idle prompt is able and no Esc is sent" ||
  fail "18c. mention: lease '$(cat "$D/lease" 2>&1)' keys '$(cat "$T/keys" 2>/dev/null)' log: $(cat "$D/lease.log")"
cat >"$T/pane/1000" <<'EOF2'
Teach auto mode about your environment?
  2. Not now
  3. Don't show again

────
❯ 
────
  ⏵⏵ auto mode on
EOF2
tick renew $((N + 40)) "${K[@]}"
[[ "$(cat "$D/lease")" == "M-1 $((N + 40))" && ! -s "$T/keys" ]] &&
  pass "18c. the same lines above an idle prompt are the transcript, not the dialog" ||
  fail "18c. pasted: lease '$(cat "$D/lease" 2>&1)' keys '$(cat "$T/keys" 2>/dev/null)'"
cat >"$T/pane/1000" <<'EOF2'
Teach auto mode about your environment?

✢ Cogitating… (4s · ↓ 20 tokens)
EOF2
tick renew $((N + 50)) "${K[@]}"
[[ "$(cat "$D/lease")" == "M-1 $((N + 50))" && ! -s "$T/keys" ]] &&
  pass "18c. the title alone, with no picker line, is able and no Esc is sent" ||
  fail "18c. title-only: lease '$(cat "$D/lease" 2>&1)' keys '$(cat "$T/keys" 2>/dev/null)'"
dialog 1000
tick renew $((N + 60)) "${K[@]}" LEASE_MODAL_RES=
[[ "$(cat "$D/lease")" == "M-1 $((N + 60))" && ! -s "$T/keys" ]] &&
  pass "18c. control: the old matcher misses the dialog, so the seat stays able" ||
  fail "18c. control: lease '$(cat "$D/lease")' log: $(cat "$D/lease.log")"
tick renew $((N + 120)) "${K[@]}"
[[ "$(cat "$D/lease")" == "M-1 $((N + 60))" && "$(logc 'renew stop M-1 (stalled pid=1000: Teach auto mode about your environment)')" == 1 ]] &&
  pass "18c. the dialog is not able, logged once" ||
  fail "18c. stall: lease '$(cat "$D/lease")' log: $(cat "$D/lease.log")"
[[ "$(cat "$T/keys" 2>/dev/null)" == "1000 Escape" ]] &&
  pass "18c. one Esc sent" || fail "18c. keys: '$(cat "$T/keys" 2>/dev/null)'"
[[ "$(sentc 'O-1 :: DISPATCH LEASE: M-1 pid=1000 is blocked by a modal')" == 1 ]] &&
  pass "18c. the orchestrator is told once" || fail "18c. sent: $(cat "$T/sent" 2>/dev/null)"
tick renew $((N + 180)) "${K[@]}"
[[ "$(cat "$T/keys" 2>/dev/null)" == "1000 Escape" && "$(sentc 'blocked by a modal')" == 1 && "$(logc 'still blocked after one Esc')" == 1 ]] &&
  pass "18c. a second tick does not press Esc again or alert again" ||
  fail "18c. twice: keys '$(cat "$T/keys" 2>/dev/null)' sent: $(cat "$T/sent" 2>/dev/null)"
tick watch $((N + 241)) "${K[@]}"
[[ "$(holder)" == F-1 && "$(logc 'FAILOVER: M-1 silent 181s -> F-1 active')" == 1 ]] &&
  pass "18c. the lease fails over once the master stays blocked" ||
  fail "18c. promote: $(cat "$D/lease.log")"
# Esc clears the dialog before the recheck: the seat stays able and nobody is told.
rm -rf "$T/spool" "$T/sent" "$T/keys"; mkdir -p "$D"
cat >"$T/bin/keys-clear" <<EOF
#!/usr/bin/env bash
printf '%s Escape\n' "\$1" >>"\$KEYS"
printf 'done\n> \n  auto mode on\n' >"$T/pane/\$1"
EOF
chmod +x "$T/bin/keys-clear"
idle 1000; idle 1100; dialog 1000
tick renew $((N + 300)) LEASE_KEYS_CMD="$T/bin/keys-clear" KEYS="$T/keys" LEASE_MODAL_WAIT=0
[[ "$(cat "$D/lease")" == "M-1 $((N + 300))" && "$(cat "$T/keys" 2>/dev/null)" == "1000 Escape" && ! -s "$T/sent" ]] &&
  pass "18c. Esc that clears the dialog: the recheck is able and no alert is sent" ||
  fail "18c. cleared: lease '$(cat "$D/lease" 2>&1)' keys '$(cat "$T/keys" 2>/dev/null)' sent '$(cat "$T/sent" 2>/dev/null)'"
grep -q 'LEASE_MODAL_WAIT:-3' "$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh" &&
  grep -q 'teach auto mode about your environment' "$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh" &&
  grep -q "don't show again" "$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh" &&
  pass "18c. the recheck waits a few seconds (default 3) and the list names the dialog and its picker" ||
  fail "18c. the source lost the default wait or the dialog line"

# --- 19. a per-role machine ranking (t1 aad0e6cf) ---------------------------
rank19() {
  env -i PATH="$PATH" PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/r19" LEASE_MACHINE=pc "$@" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init >/dev/null && spl_lease_conf && spl_fleet_ids || exit 1
    echo "orch=$(spl_fleet_rank sat orch)$(spl_fleet_rank pc orch) dispatch=$(spl_fleet_rank sat dispatch)$(spl_fleet_rank pc dispatch)"' 2>&1
}
mkdir -p "$T/r19/dispatch"
printf 'LEASE_FLEET=main\nLEASE_PRIORITY=pc,sat\nLEASE_PRIORITY_ORCH=sat,pc\n' >"$T/r19/dispatch/lease.conf"
[[ "$(rank19)" == "orch=01 dispatch=10" ]] &&
  pass "19. LEASE_PRIORITY_ORCH (lease.conf) ranks sat first for orch; dispatch keeps LEASE_PRIORITY (pc first)" || fail "19. per-role: $(rank19)"
printf 'LEASE_FLEET=main\nLEASE_PRIORITY=pc,sat\n' >"$T/r19/dispatch/lease.conf"
[[ "$(rank19)" == "orch=10 dispatch=10" ]] &&
  pass "19. control: no per-role key, LEASE_PRIORITY ranks both roles" || fail "19. control: $(rank19)"
[[ "$(rank19 LEASE_PRIORITY_DISPATCH=sat,pc)" == "orch=10 dispatch=01" ]] &&
  pass "19. LEASE_PRIORITY_DISPATCH (env) ranks dispatch on its own" || fail "19. dispatch: $(rank19 LEASE_PRIORITY_DISPATCH=sat,pc)"
[[ "$(rank19 LEASE_PRIORITY_ORCH=sat)" == *"FATAL this machine (pc) is not in LEASE_PRIORITY_ORCH"* &&
   "$(rank19 LEASE_PRIORITY_ORCH=Sat,pc)" == *"FATAL LEASE_PRIORITY_ORCH must list the machines"* ]] &&
  pass "19. a per-role ranking is validated like LEASE_PRIORITY" || fail "19. validate: $(rank19 LEASE_PRIORITY_ORCH=sat)"

# --- 20. the agent run report (t1 bc1a43e1, fix A) --------------------------
# c-001@<box> read green while no c-001 ran on it. The report lists every live
# agent: run when the lease's own test says it can act, stop + why when its
# pane is stuck; no line for an id with no process. It presses no key.
report20() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/r20" LEASE_PROC_ROOT="$P" LEASE_PANE_CMD="$T/bin/pane" \
    LEASE_LIMIT_TZ=Etc/GMT-3 LEASE_NOW=1791007260 LEASE_KEYS_CMD="$T/bin/keys" KEYS="$T/keys" LEASE_MODAL_WAIT=0 bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init >/dev/null || exit 1
    spl_lease_agent_run_report' 2>&1
}
rm -rf "${P:?}"/* "$T/pane"/* "$T/keys" "$T/r20"; mkdir -p "$T/r20/dispatch"
agent 2000 c-001; idle 2000
agent 2100 c-002; limited 2100
agent 2200 g-003 grok
cat >"$T/pane/2500" <<'EOF2'
Teach auto mode about your environment?
  1. Yes
  2. Not now
  3. Don't show again
EOF2
agent 2500 c-005
report20 >/dev/null
R20="$T/r20/dispatch/agent-run.tsv"
[[ "$(grep -P '^c-001\trun$' -c "$R20")" == 1 && "$(grep -P '^g-003\trun$' -c "$R20")" == 1 ]] &&
  pass "20. an able claude agent and a live grok agent report run" || fail "20. run: $(cat "$R20" 2>&1)"
grep -qP '^c-002\tstop\tstalled pid=2100: Usage limit reached, resets in 109 min$' "$R20" &&
  pass "20. an agent idle at its usage limit reports stop, with the lease's why" || fail "20. limit: $(cat "$R20" 2>&1)"
grep -qP '^c-005\tstop\tstalled pid=2500: ' "$R20" && [[ ! -s "$T/keys" ]] &&
  pass "20. a modal is stop and the report sends no Escape (the lease's able check would)" ||
  fail "20. modal: $(cat "$R20" 2>&1) keys '$(cat "$T/keys" 2>/dev/null)'"
! grep -q '^c-004' "$R20" && [[ "$(grep -vc '^#' "$R20")" == 4 ]] &&
  pass "20. an id with no process has no line (control: exactly the 4 live ids)" || fail "20. lines: $(cat "$R20" 2>&1)"
kill_agent 2100; report20 >/dev/null
! grep -q '^c-002' "$R20" && [[ "$(grep -vc '^#' "$R20")" == 3 ]] &&
  pass "20. a killed agent drops out of the next report" || fail "20. killed: $(cat "$R20" 2>&1)"
D20="$T/r20/dispatch/agent-run-$(date -u -d @1791007260 +%F).log"
[[ "$(grep -c '^1791007260 ' "$D20")" == 7 && "$(grep -c '^1791007260 c-002 stop$' "$D20")" == 1 &&
   "$(tail -n 3 "$D20" | grep -c '^1791007260 c-002 ')" == 0 ]] &&
  pass "20. each report appends '<epoch> <id> run|stop' to the UTC day log, the killed one gone (spec 123 4.3)" || fail "20. day log: $(cat "$D20" 2>&1)"
[[ "$(env PROJ_PATH="$PROJ_ROOT" SPOOL_TEST=1 SPOOL_ROOT="$T/r20b" bash -c '
    do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"; spl_lease_init >/dev/null
    spl_lease_agent_run_tick; sleep 0.2; ls "$LEASE_DIR"/agent-run.tsv 2>/dev/null | wc -l')" == 0 ]] &&
  pass "20. the tick writes nothing under SPOOL_TEST=1 unless LEASE_AGENT_RUN=1" || fail "20. tick ran under SPOOL_TEST"

# --- 21. an m- lane (vibe) is reported run (t1 5c3bb16a) ---------------------
# vibe renames itself "Vibe CLI" (setproctitle: comm AND cmdline), and runs as
# the agent user, so its environ is read through the owner hop. Without
# SPT_NOENV setproctitle zeroed that environ: no SPOOL_AGENT_ID, no line, roster
# running = f. spawn-mistral.sh now launches it with SPT_NOENV=1.
if [[ "$(id -u)" == 0 ]]; then echo "SKIP: 21. root reads every environ"; else
rm -rf "${P:?}"/* "$T/pane"/* "$T/r20"; mkdir -p "$T/r20/dispatch"
# vibe21 <pid> <id> [clobbered]: comm "Vibe CLI", environ only its owner reads
vibe21() {
  mkdir -p "$P/$1"; echo "Vibe CLI" >"$P/$1/comm"
  if [[ -n "${3:-}" ]]; then head -c 64 /dev/zero >"$P/$1/environ.priv"
  else printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0SPT_NOENV=1\0' "$2" >"$P/$1/environ.priv"; fi
  printf 'HOME=/x\0' >"$P/$1/environ"; chmod 000 "$P/$1/environ"
}
agent 2000 c-001; idle 2000
vibe21 2700 m-587; vibe21 2800 m-588 clobbered
SPOOL_OWNER_HOP=force SPOOL_OWNER_HOP_CMD="$T/bin/hop" HOPLOG="$T/hops" report20 >/dev/null
grep -qP '^m-587\trun$' "$R20" && grep -qP '^c-001\trun$' "$R20" &&
  pass "21. a live m- lane (comm 'Vibe CLI', environ via its owner) reports run" || fail "21. m- run: $(cat "$R20" 2>&1)"
! grep -q '^m-588' "$R20" &&
  pass "21. control: a vibe whose environ setproctitle zeroed (no SPT_NOENV) has no line" || fail "21. clobbered: $(cat "$R20" 2>&1)"
ids="$(env LEASE_PROC_ROOT="$P" SPOOL_OWNER_HOP=force SPOOL_OWNER_HOP_CMD="$T/bin/hop" HOPLOG="$T/hops" PROJ_PATH="$PROJ_ROOT" bash -c '
  do_log() { :; }; source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
  eval "$(declare -f spl_lease_live_ids | sed "s/ | \"Vibe CLI\")/)/")"; spl_lease_live_ids' | tr '\n' ' ')"
[[ "$ids" == "c-001 " ]] && pass "21. control: the old comm list never hops to 'Vibe CLI' (m-587 missing)" || fail "21. old: '$ids'"
chmod -R u+rwX "$P"
fi

echo "dispatch-lease: $fails failure(s)"
[[ $fails -eq 0 ]]
