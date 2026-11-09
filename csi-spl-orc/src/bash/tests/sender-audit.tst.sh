#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_sender_audit (SPL-5136) over planted journal lines, a fake
#          /proc and a fake spool sender. No hub, no spool binary.
#   1. dry run: reports the forged send, sends nothing, keeps the journal
#   2. a lane's send as another id: ONE note to orchestrator, journal consumed
#   3. RED CONTROL: the same chain sending as itself is not flagged
#   4. not flagged: no agent in the chain, a role seat caller, a dead chain
#      with no id (unjudgeable), a from_agent line naming the caller
#   5. flagged: a from_agent line naming someone else
#   6. a failed send keeps the batch for the next run
#   7. a malformed line is counted; bad DRY_RUN is refused
#   8. W1: the pane leg, through a private tmux server
#   9. W2: a dead chain with an id journalled at send time is flagged; a
#      reused pid is not read as the agent
#  10. W3: the counts, and no journal is never a clean result
#  11. the note names the box from its config, not the hostname
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'tmux -S "$T/tm.sock" kill-server 2>/dev/null; rm -rf "$T"' EXIT

S="$T/spool"; P="$T/proc"; J="$S/dispatch/sender-audit.jsonl"; TS="$T/tm.sock"
mkdir -p "$S/dispatch"
printf 'LEASE_MASTER=c-002\nLEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
cat >"$T/send.sh" <<'SEND'
#!/usr/bin/env bash
to="" kind="" task="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --kind) kind="$2"; shift 2 ;; --task) task="$2"; shift 2 ;; --body-file) body="$2"; shift 2 ;; *) shift 2 ;; esac; done
[ -e "$SEND_LOG.fail" ] && exit 11
{ echo "TO $to $kind $task"; cat "$body"; echo "END"; } >>"$SEND_LOG"
SEND
chmod +x "$T/send.sh"

mkproc() {  # PID PPID COMM [ENV...]
  local pid="$1" ppid="$2" comm="$3"
  shift 3
  mkdir -p "$P/$pid"
  printf '%s\n' "$comm" >"$P/$pid/comm"
  printf 'Name:\t%s\nPPid:\t%s\n' "$comm" "$ppid" >"$P/$pid/status"
  printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 5000 9\n' "$pid" "$comm" "$ppid" >"$P/$pid/stat"
  if [ "$#" -gt 0 ]; then printf '%s\0' "$@" >"$P/$pid/environ"; else : >"$P/$pid/environ"; fi
}
mkproc 100 1 claude SPOOL_AGENT_ID=c-777
# the copied environ: an inner process claims the seat, the outermost wins
mkproc 101 100 bash SPOOL_AGENT_ID=c-002
mkproc 200 1 claude SPOOL_AGENT_ID=c-002
mkproc 201 200 bash SPOOL_AGENT_ID=c-002
mkproc 300 1 cron

line() {  # MSG FROM CHAIN-JSON [CLAIM] [AGENT] [STARTS-JSON] [UNREAD] [PANE]
  printf '{"ts":"t","msg_id":"%s","from":"%s","chain":%s,"claim":"%s","agent":"%s","starts":%s,"unread":%s,"pane":%s}\n' \
    "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-[]}" "${7:-0}" "${8:-false}" >>"$J"
}
audit() {
  out="$(env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_TEST=1 SPOOL_FROM_GUARD_PROC="$P" SPOOL_SENDER_AUDIT="$J" SPOOL_TMUX_SOCKET="$TS" \
    SEND_LOG="$T/sent" SENDER_AUDIT_SEND="$T/send.sh" HOME="$T/home" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-sender-audit.func.sh"
    do_spl_sender_audit' 2>&1)"; rc=$?
}
reset() { rm -f "$J" "$J.work" "$T/sent" "$T/sent.fail"; }
sent() { [ -e "$T/sent" ] && grep -c '^TO ' "$T/sent" || echo 0; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want '$2' got '$3'"; fi; }
hit() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1: no '$2' in: $3" ;; esac; }

reset; line aaaaaaaa-1 c-002 '[101,100]' '' c-777
audit DRY_RUN=1
check "dry run: exit 0" 0 "$rc"
hit "dry run: names the forged send" "aaaaaaaa-1 c-002 c-777 environ" "$out"
check "dry run: nothing sent" 0 "$(sent)"
[ -e "$J" ] && pass "dry run: journal kept" || fail "dry run: journal kept"

audit DRY_RUN=0
check "forged: one note" 1 "$(sent)"
hit "forged: to orchestrator on fleet-anomaly" "TO orchestrator note fleet-anomaly" "$(cat "$T/sent")"
hit "forged: the note names the caller" "| aaaaaaaa-1 | c-002 | c-777 (by its environ) |" "$(cat "$T/sent")"
[ ! -e "$J" ] && [ ! -e "$J.work" ] && pass "forged: journal consumed" || fail "forged: journal consumed"

reset; line bbbbbbbb-1 c-777 '[101,100]' '' c-777
audit DRY_RUN=0
check "RED CONTROL: the same chain as itself is not flagged" 0 "$(sent)"

reset
line cccccccc-1 c-777 '[300]'
line cccccccc-2 c-777 '[201,200]' '' c-002
line cccccccc-3 c-002 '[901,902]' '' '' '["1","1"]' 0 true
line cccccccc-4 c-002 '[]'
line cccccccc-5 c-002 '[101,100]' c-777 c-777
audit DRY_RUN=0
check "no agent, seat caller, dead or empty chain, own relay: not flagged" 0 "$(sent)"

reset; line dddddddd-1 c-002 '[101,100]' c-555 c-777
audit DRY_RUN=0
hit "a from_agent line naming someone else is flagged" "dddddddd-1" "$(cat "$T/sent")"

reset; line eeeeeeee-1 c-002 '[101,100]' '' c-777; : >"$T/sent.fail"
audit DRY_RUN=0
check "failed send: exit 1" 1 "$rc"
[ -e "$J.work" ] && pass "failed send: batch kept" || fail "failed send: batch kept"
rm -f "$T/sent.fail"
audit DRY_RUN=0
hit "failed send: retried on the next run" "eeeeeeee-1" "$(cat "$T/sent")"
[ ! -e "$J.work" ] && pass "retry: batch consumed" || fail "retry: batch consumed"

reset; { echo 'not json'; echo '{"msg_id":"x; rm","from":"c-002","chain":[101,100]}'; } >"$J"
audit DRY_RUN=0
check "malformed lines: exit 0" 0 "$rc"
check "malformed lines: nothing sent" 0 "$(sent)"
hit "malformed lines: counted, not read as clean" "WARN sender audit: 0 flagged, 0 judged, 0 unjudgeable, 2 malformed" "$out"

reset; audit DRY_RUN=2
check "bad DRY_RUN: exit 1" 1 "$rc"

# W1: no id in the environ, the chain's pane names c-779. The socket is set and
# SPOOL_BOX_USER is not, so this also proves the action resolves the spool env.
reset
tmux -S "$TS" new-session -d -s w1 -n 'c-779 lane' 'sleep 300'
pp="$(tmux -S "$TS" display -p -t w1 '#{pane_pid}')"
mkproc "$pp" 1 bash
line 11111111-1 c-002 "[$pp]" '' '' '["5000"]' 0 true
audit DRY_RUN=0
check "W1 pane: exit 0" 0 "$rc"
hit "W1 pane: flagged by its pane" "11111111-1 c-002 c-779 pane" "$out"
hit "W1 pane: counted as judged" "1 flagged, 1 judged, 0 unjudgeable" "$out"
case "$out" in *"unbound variable"*) fail "W1 pane: no unbound variable" ;; *) pass "W1 pane: no unbound variable" ;; esac

# W2: the chain is gone, the id journalled at send time still decides.
reset; line 22222222-1 c-002 '[901,902]' '' c-779 '["1","2"]' 0 true
audit DRY_RUN=0
hit "W2 dead chain, id from send time: flagged" "| 22222222-1 | c-002 | c-779 (by its environ) |" "$(cat "$T/sent")"
# An unread pid at send time is judged live, while it still runs.
reset; line 22222222-2 c-002 '[101,100]' '' '' '["5000","5000"]' 1 false
audit DRY_RUN=1
hit "W2 unread at send, still running: read live" "22222222-2 c-002 c-777 environ" "$out"
# The same pids, another start time: a reused pid is not that agent.
reset; line 22222222-3 c-002 '[101,100]' '' '' '["1","1"]' 1 false
audit DRY_RUN=0
check "W2 reused pid: nothing sent" 0 "$(sent)"
hit "W2 reused pid: unjudgeable" "WARN sender audit: 0 flagged, 0 judged, 1 unjudgeable" "$out"
# A line from before the start times were journalled cannot be judged.
reset; printf '{"msg_id":"22222222-4","from":"c-002","chain":[101,100]}\n' >"$J"
audit DRY_RUN=1
hit "W2 old line: unjudgeable" "0 judged, 1 unjudgeable" "$out"

# W3: a clean result only when something was judged.
reset; line 33333333-1 c-777 '[101,100]' '' c-777
audit DRY_RUN=1
hit "W3 all judged: OK with the counts" "OK sender audit: 0 flagged, 1 judged, 0 unjudgeable, 0 malformed" "$out"
reset; audit DRY_RUN=1
hit "W3 no journal, dry run: says so" "WARN sender audit: no journal" "$out"
check "W3 no journal, dry run: exit 0" 0 "$rc"
reset; audit DRY_RUN=0
hit "W3 no journal, real run: says so" "not a clean result" "$out"
reset; : >"$J"; audit DRY_RUN=1
hit "W3 empty journal: not OK" "WARN sender audit: 0 flagged, 0 judged" "$out"
reset; line 33333333-2 c-002 '[101,100]' '' c-777
line 33333333-3 c-002 '[901]' '' '' '["1"]' 0 true
audit DRY_RUN=0
hit "W3 the note carries the counts" "This run: 1 flagged, 1 judged, 1 unjudgeable, 0 malformed." "$(cat "$T/sent")"

reset; line 33333333-4 c-002 '[101,100]' '' c-777
audit DRY_RUN=0 SPOOL_DESK_BOX=cfgbox
hit "the note names the configured box" "Sender audit on cfgbox (SPL-5136)" "$(cat "$T/sent")"

echo "-- sender-audit.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
