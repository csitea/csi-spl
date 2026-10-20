#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: clock-skew drill for the LOCAL dispatch lease (renew + watch, no
#          LEASE_FLEET; SPL-2704, found by the SPL-2139 drill). The lease file
#          holds a wall-clock epoch; the watch must age it on the monotonic
#          clock (LEASE_MONO fakes it, LEASE_NOW fakes the wall clock).
#   1. the wall clock jumps +300 s while the master renews every 60 s: the
#      watch looks before the renewal (same lease) and after it (a new lease
#      it has not seen): never a promotion, nothing logged or told
#   2. the wall clock steps -600 s, then the master goes silent: the failover
#      is promoted within LEASE_STALE + one tick of the silence (monotonic)
#   3. no last look (a fresh watch, or one from before a reboot): the wall age
#      decides, so a lease already stale on the wall clock is failed over at
#      the first tick
#   4. no clock step and the mono clock left to follow LEASE_NOW: 180 s is
#      not stale, 181 s is (the plain path is unchanged)
#  RED control: cases 1 and 2 fail on the code before SPL-2704 (wall age).
#  The fleet mode is drilled by fleet-lease.tst.sh and lease-clock-skew.tst.sh.
#  Fixtures only in a mktemp root; no tmux, no network, no real clock.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
export SPOOL_TEST=1

mkdir -p "$T/bin" "$T/pane"
cat >"$T/bin/send" <<'STUB'
#!/bin/sh
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body) body="$2"; shift 2 ;; *) shift ;; esac; done
echo "$to :: $body" >>"$SENT"
STUB
printf '#!/bin/sh\nexit 0\n' >"$T/bin/asksrun"
printf '#!/bin/sh\nf="%s/pane/$1"; [ -e "$f" ] || exit 1; exec cat "$f"\n' "$T" >"$T/bin/pane"
chmod +x "$T/bin/send" "$T/bin/asksrun" "$T/bin/pane"

# A drill is one spool root, one fake /proc: <root>/proc, <root>/spool.
R=""
new_root() { R="$T/$1"; mkdir -p "$R/proc" "$R/spool/dispatch"; }
agent() { mkdir -p "$R/proc/$1"; echo claude >"$R/proc/$1/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$R/proc/$1/environ"; }
kill_agent() { rm -rf "${R:?}/proc/$1"; }
boot() { printf 'cpu 0\nbtime %s\n' "$1" >"$R/proc/stat"; }

# tick <renew|watch> <wall> <mono|-> : one tick of that loop ("-" = no LEASE_MONO)
tick() {
  local verb="$1" wall="$2" mono="$3" m=()
  [[ "$mono" != - ]] && m=(LEASE_MONO="$mono")
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$R/spool" LEASE_PROC_ROOT="$R/proc" LEASE_SEND="$T/bin/send" SENT="$R/sent" \
    LEASE_PANE_CMD="$T/bin/pane" LEASE_ASKS_RUN="$T/bin/asksrun" LEASE_AGENT_RUN=0 LEASE_LIMIT_TZ=Etc/GMT-3 \
    LEASE_MASTER=M-1 LEASE_FAILOVER=F-1 LEASE_ORCH=O-1 LEASE_NOW="$wall" "${m[@]}" TICK="$verb" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    spl_lease_init && spl_lease_ids master failover orch && "spl_lease_${TICK}_tick"' >>"$R/out" 2>&1
}
holder() { cut -d' ' -f1 "$R/spool/dispatch/lease" 2>/dev/null; }
failovers() { grep -c 'FAILOVER:' "$R/spool/dispatch/lease.log" 2>/dev/null || true; }
told() { [[ -s "$R/sent" ]] && wc -l <"$R/sent" || echo 0; }

# --- 1. +300 s wall jump while the master renews --------------------------------------
new_root plus; agent 100 M-1; agent 200 F-1
tick renew 1000 100; tick watch 1000 100
# watch before the renewal: same lease, wall age 60 + 300
tick watch 1360 160; tick renew 1360 160
tick watch 1420 220; tick renew 1420 220
# the renewal lands, the wall jumps +300 again, then the watch first sees it
tick renew 1430 230; tick watch 1790 280
tick renew 1790 290; tick watch 1850 340
[[ "$(holder)" == M-1 && "$(failovers)" == 0 && "$(told)" == 0 ]] &&
  pass "1. a +300 s wall jump never promotes the failover while the master renews" ||
  fail "1. holder=$(holder) failovers=$(failovers) told=$(told) log: $(cat "$R/spool/dispatch/lease.log" 2>&1)"

# --- 2. -600 s wall step, then the master goes silent ---------------------------------
new_root minus; agent 100 M-1; agent 200 F-1
tick renew 5000 1000; tick watch 5000 1000
kill_agent 100
# the master's last renewal was at mono 1000; the wall steps -600 s
for mono in 1060 1120 1180 1240; do tick renew $((mono + 4000 - 600)) "$mono"; tick watch $((mono + 4000 - 600)) "$mono"; done
[[ "$(holder)" == F-1 && "$(failovers)" == 1 ]] && grep -q 'FAILOVER: M-1 silent 240s -> F-1 active' "$R/spool/dispatch/lease.log" &&
  pass "2. after a -600 s wall step a silent master is failed over within LEASE_STALE + one tick (240 s)" ||
  fail "2. holder=$(holder) failovers=$(failovers) log: $(cat "$R/spool/dispatch/lease.log" 2>&1)"

# --- 3. no usable last look: the wall age decides -------------------------------------
new_root fresh; agent 200 F-1; boot 50
printf 'M-1 1000\n' >"$R/spool/dispatch/lease"
tick watch 1181 900
[[ "$(holder)" == F-1 && "$(failovers)" == 1 ]] &&
  pass "3. a fresh watch fails a lease 181 s old on the wall clock over at its first tick" ||
  fail "3. holder=$(holder) log: $(cat "$R/spool/dispatch/lease.log" 2>&1)"
new_root reboot; agent 200 F-1; boot 50
printf 'M-1 1000\n' >"$R/spool/dispatch/lease"
tick watch 1000 900
boot 2000
tick watch 1181 1000
[[ "$(holder)" == F-1 && "$(failovers)" == 1 ]] &&
  pass "3. a last look from before a reboot (other btime) is not used: wall age 181 s fails over" ||
  fail "3. reboot: holder=$(holder) log: $(cat "$R/spool/dispatch/lease.log" 2>&1)"

# --- 4. no clock step, LEASE_MONO unset (follows LEASE_NOW) ---------------------------
new_root plain; agent 100 M-1; agent 200 F-1
tick renew 1000 -; tick watch 1000 -
kill_agent 100
tick watch 1180 -
[[ "$(holder)" == M-1 && "$(failovers)" == 0 ]] && pass "4. 180 s is not stale" || fail "4. promoted at 180 s: $(cat "$R/spool/dispatch/lease.log" 2>&1)"
tick watch 1181 -
[[ "$(holder)" == F-1 ]] && grep -q 'FAILOVER: M-1 silent 181s -> F-1 active' "$R/spool/dispatch/lease.log" &&
  pass "4. 181 s is stale: the failover is promoted" || fail "4. holder=$(holder) log: $(cat "$R/spool/dispatch/lease.log" 2>&1)"

echo "lease-local-clock-skew: $fails failure(s)"
[[ $fails -eq 0 ]]
