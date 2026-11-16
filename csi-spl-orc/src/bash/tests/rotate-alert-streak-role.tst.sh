#!/usr/bin/env bash
# rotate-alert-streak-role.tst.sh - one rotation alert streak per role
# (SPL-5684, spec 175 section 5.3)
#
# The master and the failover shared rotate.dispatch.alert-streak: a failover
# alert overwrote the master's streak, and a DONE OK of either removed both,
# so the master's next failure on the same old pid opened a new ask. 19
# rotation-ack alerts came of 1..3 real streaks. The proof count is
# "rotation-failed asks per (seat, old pid) = 1". Cases:
#   (a) master FAIL on pid 102, failover FAIL on pid 103, master FAIL on 102
#       again: 1 ask per (seat, pid), the repeat logs ALERT SKIP
#   (b) a failover DONE OK leaves the master's streak: the master's next
#       FAIL on pid 102 is still a repeat, no new ask
#   (c) a master DONE OK ends the master's streak and keeps the failover's
#   (d) the streak files are rotate.dispatch.<role>.alert-streak and
#       rotate.orch.orch.alert-streak
#   (e) control: a new old pid on the master is a new streak, a new ask
#
# Run: bash csi-spl-orc/src/bash/tests/rotate-alert-streak-role.tst.sh </dev/null
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export SPOOL_ROOT="$T/spool"
# shellcheck source=/dev/null
source "$HERE/../run/spl-rotate-lib.func.sh"
export ROTATE_STATE_DIR="$T/state" ROTATE_LOG="$T/rotate.log" ROTATE_BOX=box-a DRY_RUN=0 ROTATE_CMD=auto
export LEASE_MASTER=c-902 LEASE_FAILOVER=c-903 LEASE_ORCH=c-900
mkdir -p "$ROTATE_STATE_DIR" "$SPOOL_ROOT"
printf '#!/usr/bin/env bash\necho "$ASK_FROM $ASK_SUMMARY" >> "%s/asks.log"\n' "$T" > "$T/run"; chmod +x "$T/run"
export ROTATE_RUN="$T/run"
spl_is_agent_id() { return 1; }
spl_rotate_owner_say() { echo "say $*" >> "$T/say.log"; }

# fail ROLE PID: one ACK failure of ROLE on old pid PID
fail_at() { ROTATE_OLD_PID="$2" spl_rotate_alert "$1" "20261115T1715Z-$1" ACK "no ack within 600s" >/dev/null; }
# asks ID PID: the asks of seat ID on old pid PID
asks() { grep -c "^$1 ROTATION FAILED .* pid $2\$" "$T/asks.log" 2>/dev/null || true; }

# (a)
fail_at master 102; fail_at failover 103; fail_at master 102
[[ "$(asks c-902 102)" == 1 && "$(asks c-903 103)" == 1 ]] &&
  pass "(a) master, failover, master again: 1 ask per (seat, old pid)" ||
  fail "(a) asks c-902/102=$(asks c-902 102) c-903/103=$(asks c-903 103): $(cat "$T/asks.log")"
grep -q -- '-master ALERT SKIP repeat 2 of ask ' "$ROTATE_LOG" &&
  pass "(a) the master's repeat logs ALERT SKIP repeat 2" || fail "(a) no repeat line: $(grep ALERT "$ROTATE_LOG")"
# (b)
spl_rotate_log 20261115T1745Z-failover DONE OK "failover refreshed" >/dev/null
fail_at master 102
[[ "$(asks c-902 102)" == 1 ]] && grep -q -- '-master ALERT SKIP repeat 3 of ask ' "$ROTATE_LOG" &&
  pass "(b) a failover DONE OK keeps the master's streak: still 1 ask on c-902 pid 102" ||
  fail "(b) asks c-902/102=$(asks c-902 102): $(grep ALERT "$ROTATE_LOG")"
# (c)
fail_at failover 103
spl_rotate_log 20261115T1815Z-master DONE OK "master rotated" >/dev/null
[[ ! -e "$ROTATE_STATE_DIR/rotate.dispatch.master.alert-streak" && -s "$ROTATE_STATE_DIR/rotate.dispatch.failover.alert-streak" ]] &&
  pass "(c) a master DONE OK ends the master's streak only" || fail "(c) $(ls "$ROTATE_STATE_DIR")"
# (d)
fail_at orch 101
[[ -s "$ROTATE_STATE_DIR/rotate.orch.orch.alert-streak" && ! -e "$ROTATE_STATE_DIR/rotate.dispatch.alert-streak" ]] &&
  grep -q '^failover c-903 ACK 103 ' "$ROTATE_STATE_DIR/rotate.dispatch.failover.alert-streak" &&
  pass "(d) one streak file per role, no shared rotate.dispatch.alert-streak" || fail "(d) $(ls "$ROTATE_STATE_DIR")"
# (e)
fail_at master 2902
[[ "$(asks c-902 2902)" == 1 ]] && pass "(e) control: a new old pid on the master is a new ask" || fail "(e) asks c-902/2902=$(asks c-902 2902)"

echo
(( fails == 0 )) && { echo "rotate-alert-streak-role: all passed"; exit 0; }
echo "rotate-alert-streak-role: $fails failure(s)"; exit 1
