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
chmod +x "$T/bin/send"

# agent <pid> <id> [comm] / kill_agent <pid>
agent() { mkdir -p "$P/$1"; echo "${3:-claude}" >"$P/$1/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$2" >"$P/$1/environ"; }
kill_agent() { rm -rf "${P:?}/$1"; }

lease() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" LEASE_PROC_ROOT="$P" LEASE_SEND="$T/bin/send" SENT="$T/sent" \
    LEASE_MASTER="${LM-M-1}" LEASE_FAILOVER="${LF-F-1}" LEASE_ORCH="${LO-O-1}" "$@" bash -c '
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

echo "dispatch-lease: $fails failure(s)"
[[ $fails -eq 0 ]]
