#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: perf round 11, row 03 -- the pre-push hygiene part runs its three
#          read-only checks at once: do_check_dist_hygiene in the foreground,
#          the fleet rules and qto doc map drift checks in the background
#          beside it, and nothing else about the part changes.
#   The three are stubs that meet at a 3-way barrier: each waits (bounded,
#   BAR_S seconds) until all three are in flight.
#   1. clean run: 3 in flight, 0 barrier timeouts, rc 0, the output in the old
#      order (dist, then fleet rules, then qto), the caller's HUP/INT/TERM
#      traps the same after the part as before it, no temp dir left
#   2. the fleet rules stub fails: rc 1, its output still after the dist
#      output and before the qto output
#   3. a TERM to the part while all three run: the caller's TERM trap runs
#      (exit 143), no process of either drift job's tree is left (a stub's
#      `sleep`, a stub's python3, as in check-qto-doc-drift.func.sh), and no
#      temp dir
#   RED CONTROL: the sequential part (origin/master before row 03) -> case 1
#   reads 1 in flight and 3 timeouts, FAIL.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
for _v in $(compgen -v); do case "$_v" in SPL_PREPUSH_*|PRE_PUSH_*) unset "$_v" ;; esac; done
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"
fails=0
pids=()
tmp_dir
# every process this test starts is stopped by its recorded pid, never a pattern
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
require_action "$FUNC"
BAR_S=4

# The fake tree: a git repo (so the part sweeps origin/master..HEAD, no WARN)
# carrying the two drift files, each defining its check as a barrier stub.
R="$T/tree"; RUN="$R/csi-spl-orc/src/bash/run"; mkdir -p "$RUN" "$T/bar" "$T/tmp"
git -C "$R" init -q -b master && git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
git -C "$R" update-ref refs/remotes/origin/master HEAD
# barrier <name>: enter, wait until 3 are in flight or BAR_S passes, record
# the most seen; the first to see 3 opens the gate for the others.
cat >"$T/barrier.sh" <<EOF
barrier() {
  local n=0 i
  touch "$T/bar/in.\$1"
  for (( i = 0; i < $BAR_S * 20; i++ )); do
    [[ -e "$T/bar/open" ]] && { n=3; break; }
    n=\$(find "$T/bar" -name 'in.*' | wc -l)
    (( n >= 3 )) && { touch "$T/bar/open"; break; }
    sleep 0.05
  done
  (( n >= 3 )) || touch "$T/bar/timeout.\$1"
  echo "\$n" >"$T/bar/seen.\$1"
  rm -f "$T/bar/in.\$1"
}
EOF
cat >"$RUN/check-fleet-rules-drift.func.sh" <<EOF
source "$T/barrier.sh"
do_check_fleet_rules_drift() {
  [[ -n "\${HANG:-}" ]] && { sleep 30 & echo \$! >"$T/fleet.pid"; wait \$!; }
  barrier fleet; echo "FLEET-OUT"; return "\${FLEET_RC:-0}"
}
EOF
cat >"$RUN/check-qto-doc-drift.func.sh" <<EOF
source "$T/barrier.sh"
do_check_qto_doc_drift() {
  [[ -n "\${HANG:-}" ]] && { python3 -c 'import os,time; open("$T/qto.pid","w").write(str(os.getpid())); time.sleep(30)'; }
  barrier qto; echo "QTO-OUT"
}
EOF

# The caller: sources the part, sets its own traps, runs the part in the
# foreground, prints the traps after it. TMPDIR is the test's, so a temp dir
# the part leaves behind is seen.
cat >"$T/caller.sh" <<EOF
set -uo pipefail
do_log() { echo "\$*"; }
. "$FUNC"
source "$T/barrier.sh"
do_check_dist_hygiene() {
  [[ -n "\${HANG:-}" ]] && { echo "\$BASHPID" >"$T/caller.pid"; sleep 30 & echo \$! >"$T/dist.pid"; wait \$!; }
  barrier dist; echo "DIST-OUT"
}
trap 'echo caller-hup' HUP; trap 'echo caller-int' INT; trap 'echo caller-term; exit 143' TERM
trap -p HUP INT TERM >"$T/traps.before"
_pp_part_hygiene "$R"; rc=\$?
trap -p HUP INT TERM >"$T/traps.after"
exit "\$rc"
EOF
run() {  # [VAR=value ...] -> rc; output in $T/out
  rm -f "$T"/bar/* "$T"/*.pid "$T"/traps.*; rm -rf "${T:?}"/tmp/*
  env TMPDIR="$T/tmp" "$@" bash "$T/caller.sh" >"$T/out" 2>&1
}
show() { sed 's/^/    | /' "$T/out"; }
in_flight() { cat "$T"/bar/seen.* 2>/dev/null | sort -n | tail -1; }
timeouts() { find "$T/bar" -name 'timeout.*' | wc -l; }
order() { grep -E '^(DIST|FLEET|QTO)-OUT$' "$T/out" | tr '\n' ' '; }
left_in_tmp() { find "$T/tmp" -mindepth 1 | wc -l; }

# --- 1. clean run ---------------------------------------------------------------
run; rc=$?
n="$(in_flight)"; to="$(timeouts)"
[[ "$n" == 3 && "$to" == 0 ]] && pass "1. the three checks run at once: 3 in flight, 0 barrier timeouts" \
  || { fail "1. the three checks did NOT run at once: ${n:-0} in flight, $to barrier timeouts (want 3, 0)"; show; }
[[ $rc -eq 0 ]] && pass "1. a clean run -> rc 0" || { fail "1. a clean run -> rc $rc"; show; }
[[ "$(order)" == "DIST-OUT FLEET-OUT QTO-OUT " ]] && pass "1. output in the old order: dist, fleet rules, qto" \
  || { fail "1. output order is '$(order)'"; show; }
cmp -s "$T/traps.before" "$T/traps.after" && [[ -s "$T/traps.before" ]] \
  && pass "1. the caller's HUP/INT/TERM traps are the same after the part as before it" \
  || { fail "1. the caller's traps changed"; diff "$T/traps.before" "$T/traps.after"; }
[[ "$(left_in_tmp)" == 0 ]] && pass "1. no temp dir left" || fail "1. $(left_in_tmp) temp entries left in TMPDIR"

# --- 2. a drift check fails ----------------------------------------------------
run FLEET_RC=1; rc=$?
[[ $rc -eq 1 ]] && pass "2. the fleet rules check fails -> the part's rc is 1" || { fail "2. a failing fleet rules check -> rc $rc (want 1)"; show; }
[[ "$(order)" == "DIST-OUT FLEET-OUT QTO-OUT " ]] && pass "2. its output still comes after the dist output, before qto" \
  || { fail "2. output order is '$(order)'"; show; }

# --- 3. TERM to the part --------------------------------------------------------
rm -f "$T"/bar/* "$T"/*.pid "$T"/traps.*; rm -rf "${T:?}"/tmp/*
env TMPDIR="$T/tmp" HANG=1 bash "$T/caller.sh" >"$T/out" 2>&1 &
cpid=$!; pids+=("$cpid")
for (( i = 0; i < 100; i++ )); do
  [[ -s "$T/caller.pid" && -s "$T/fleet.pid" && -s "$T/qto.pid" && -s "$T/dist.pid" ]] && break
  sleep 0.1
done
fpid="$(cat "$T/fleet.pid" 2>/dev/null)"; qpid="$(cat "$T/qto.pid" 2>/dev/null)"; dpid="$(cat "$T/dist.pid" 2>/dev/null)"
pids+=(${fpid:+"$fpid"} ${qpid:+"$qpid"} ${dpid:+"$dpid"})
if [[ -n "$fpid" && -n "$qpid" ]]; then
  kill -TERM "$cpid"
  rc=0; timeout 20 tail --pid="$cpid" -f /dev/null || rc=$?
  wait "$cpid"; crc=$?
  [[ $rc -eq 0 && $crc -eq 143 ]] && grep -q '^caller-term$' "$T/out" \
    && pass "3. a TERM to the part goes on to the caller's TERM trap (exit 143)" \
    || { fail "3. TERM: caller rc $crc, wait rc $rc, caller trap $(grep -c '^caller-term$' "$T/out") times"; show; }
  alive=""
  for p in "$fpid" "$qpid"; do kill -0 "$p" 2>/dev/null && alive+=" $p($(ps -o comm= -p "$p"))"; done
  [[ -z "$alive" ]] && pass "3. no process of either drift job is left (the fleet stub's sleep, the qto stub's python3)" \
    || fail "3. drift job processes still running:$alive"
  [[ "$(left_in_tmp)" == 0 ]] && pass "3. no temp dir left after the TERM" || fail "3. $(left_in_tmp) temp entries left in TMPDIR after the TERM"
else
  fail "3. the drift jobs did not start within 10 s (fleet pid '${fpid}', qto pid '${qpid}')"; show
fi

echo ""
[[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
