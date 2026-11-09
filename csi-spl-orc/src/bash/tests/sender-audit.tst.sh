#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_sender_audit (SPL-5136) over planted journal lines, a fake
#          /proc and a fake spool sender. No hub, no spool binary.
#   1. dry run: reports the forged send, sends nothing, keeps the journal
#   2. a lane's send as another id: ONE note to orchestrator, journal consumed
#   3. RED CONTROL: the same chain sending as itself is not flagged
#   4. not flagged: no agent in the chain, a role seat caller, a dead chain,
#      a from_agent line naming the caller
#   5. flagged: a from_agent line naming someone else
#   6. a failed send keeps the batch for the next run
#   7. a malformed line is skipped; bad DRY_RUN is refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

S="$T/spool"; P="$T/proc"; J="$S/dispatch/sender-audit.jsonl"
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
  if [ "$#" -gt 0 ]; then printf '%s\0' "$@" >"$P/$pid/environ"; else : >"$P/$pid/environ"; fi
}
mkproc 100 1 claude SPOOL_AGENT_ID=c-777
# the copied environ: an inner process claims the seat, the outermost wins
mkproc 101 100 bash SPOOL_AGENT_ID=c-002
mkproc 200 1 claude SPOOL_AGENT_ID=c-002
mkproc 201 200 bash SPOOL_AGENT_ID=c-002
mkproc 300 1 cron

line() {  # MSG FROM CHAIN-JSON [CLAIM]
  printf '{"ts":"t","msg_id":"%s","from":"%s","chain":%s,"claim":"%s"}\n' "$1" "$2" "$3" "${4:-}" >>"$J"
}
audit() {
  out="$(env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_TEST=1 SPOOL_FROM_GUARD_PROC="$P" SPOOL_SENDER_AUDIT="$J" \
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

reset; line aaaaaaaa-1 c-002 '[101,100]'
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

reset; line bbbbbbbb-1 c-777 '[101,100]'
audit DRY_RUN=0
check "RED CONTROL: the same chain as itself is not flagged" 0 "$(sent)"

reset
line cccccccc-1 c-777 '[300]'
line cccccccc-2 c-777 '[201,200]'
line cccccccc-3 c-002 '[901,902]'
line cccccccc-4 c-002 '[]'
line cccccccc-5 c-002 '[101,100]' c-777
audit DRY_RUN=0
check "no agent, seat caller, dead or empty chain, own relay: not flagged" 0 "$(sent)"

reset; line dddddddd-1 c-002 '[101,100]' c-555
audit DRY_RUN=0
hit "a from_agent line naming someone else is flagged" "dddddddd-1" "$(cat "$T/sent")"

reset; line eeeeeeee-1 c-002 '[101,100]'; : >"$T/sent.fail"
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

reset; audit DRY_RUN=2
check "bad DRY_RUN: exit 1" 1 "$rc"

echo "-- sender-audit.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
