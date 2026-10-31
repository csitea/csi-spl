#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_unanswered_sweep (SPEC-spool-fleet-roles.md 3.2) over fixture
#          rows, a scratch spool root and a fake sender; and
#          do_spl_unanswered_sweep_install_cron over a fake crontab. No hub, no
#          spool binary, no real crontab is touched.
#   1. classification: human-last listed; agent-last, archived topic, archived
#      channel, test workspace (list + name pattern), human DM, a channel post
#      to a human, a null-channel post
#      addressed to a human even after an agent, a terminal-typed line, the
#      probe human HUM-1 (prd), #issues and a fresh post left out; a
#      null-channel ALL-0 after an agent post (cstate thread) is open;
#      ack-only listed apart and never sent
#      a null-channel ALL-0 with no agent (read by its writer alone) is
#      listed in the "Reached nobody" table, ids only (spec 117 1.3)
#   2. DELIVER=0 sends and writes nothing
#   3. DELIVER=1: one note to the lease holder with the NEW items only; state
#      + last written; an immediate second sweep sends nothing
#   4. 2 h later: AGAIN to the holder (once); 2 h after that: escalated to the
#      orchestrator (once); then silence
#   5. a new human post in a known topic is a NEW item
#   6. a failed send keeps the items NEW and marks last sent=FAILED
#  5b. do_spl_unanswered_ack: an acked item is "handled", never sent; a new
#      human post after the ack opens it again; refusals; ACK_LIST
#   7. no lease: the master from lease.conf
#   8. bad input is refused
#   9. do_spl_dispatch_check's sweep row: never ran / fresh / stale / failed;
#      9b. a stale failed file while another machine holds the lease is ok
#  10. the cron install: dry run writes nothing, DRY_RUN=0 one exact tagged
#      line, idempotent, dev and prd lines apart, check, remove, worktree refused
#  12. M3 (2026-10-11), the counting test: a burst of human posts every 2 min
#      in one topic, swept every minute with SWEEP_MIN_AGE=3 and
#      SWEEP_ESCALATE_AGE=5, is listed at minute 3 (one NEW to the holder)
#      and escalated at minute 5 (one ESC to the orchestrator), each once
#      over 10 minutes; an agent reply ends it, a post after the reply is a
#      new item aged from itself. RED-CONTROL: aged from the newest post the
#      burst is "fresh" at every sweep and never listed
#  13. SPL-1718, the counting test: a human post at minute 0, an agent's take
#      line at minute 1, swept every minute for 40 minutes with the cron's
#      SWEEP_MIN_AGE=3 and SWEEP_ESCALATE_AGE=5: 'taken' for the 30-minute
#      grace, then NEW at minute 31 and ESC at minute 32, each once, aged
#      from the human post; a real answer at minute 35 ends it. RED on the
#      old code (a take was 'answered': 0 notes). CONTROLS: a real agent
#      reply at minute 1 is never listed; a take with no human anchor is
#      answered; SWEEP_TAKE_GRACE moves the window
#  11. seats (spec 101 D7): with a seat line in peer/seats every box sends,
#      the lease held on another box: one `peers` note per item (NEW, AGAIN,
#      ESC); a planted claim bug (a topic whose job is owned by a seat whose
#      gen is dead) is still listed, and the hub read names no claim column;
#      the check row judges a seated box. Control: no seats (or a seats file
#      with no seat line) -> today's single note to the lease holder, and
#      nothing from a box whose lease is remote
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

S="$T/spool"; mkdir -p "$S/dispatch" "$T/bin"
NOW=1790000000
H=$((NOW - 3600))              # an hour ago; the "fresh" row sits after every clock the test uses
# the fake sender: logs "<to> <first line of the body>"; fails while $T/sendfail exists
cat >"$T/send.sh" <<'EOF'
#!/usr/bin/env bash
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body-file) body="$2"; shift 2 ;; *) shift ;; esac; done
[ -e "$SEND_LOG.fail" ] && exit 11
{ echo "TO $to"; cat "$body"; echo; echo "END"; } >>"$SEND_LOG"
EOF
chmod +x "$T/send.sh"

# tenant name chan task msg epoch who to by topic chanstate files body
r() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
ROWS="$T/rows.tsv"
{
  r t1 "" development 00000000-0000-4000-8000-000000000001 10000000-0000-4000-8000-000000000001 $H HUM-27 box-desk human open live - "the build is broken on the release page | please look"
  r t1 "" development 00000000-0000-4000-8000-000000000002 10000000-0000-4000-8000-000000000002 $H CLE-77 HUM-27 agent open live - ""
  r t1 "" development 00000000-0000-4000-8000-000000000003 10000000-0000-4000-8000-000000000003 $H HUM-27 box-desk human archived live - "archived topic"
  r t1 "" old-chan 00000000-0000-4000-8000-000000000004 10000000-0000-4000-8000-000000000004 $H HUM-27 box-desk human open archived - "archived channel"
  r e2e "" lobby 00000000-0000-4000-8000-000000000005 10000000-0000-4000-8000-000000000005 $H HUM-1 box-desk human open live - "probe post"
  r proof-x "Proof run" lobby 00000000-0000-4000-8000-000000000006 10000000-0000-4000-8000-000000000006 $H HUM-1 box-desk human open live - "proof post"
  r csitea "" "" 00000000-0000-4000-8000-000000000007 10000000-0000-4000-8000-000000000007 $H HUM-3 HUM-4 human open dm - "hi between humans"
  r csitea "" issues 00000000-0000-4000-8000-000000000008 10000000-0000-4000-8000-000000000008 $H HUM-3 box-desk human open live - "issue card"
  r csitea "" spool-hub 00000000-0000-4000-8000-000000000009 10000000-0000-4000-8000-000000000009 $((NOW + 100000)) HUM-3 box-desk human open live - "a fresh one"
  r csitea "" spool-hub 00000000-0000-4000-8000-00000000000a 10000000-0000-4000-8000-00000000000a $H HUM-3 box-desk human open live - "ok thanks!"
  r csitea "" spool-hub 00000000-0000-4000-8000-00000000000b 10000000-0000-4000-8000-00000000000b $H HUM-3 box-desk human open live - "👍"
  r csitea "" spool-hub 00000000-0000-4000-8000-00000000000c 10000000-0000-4000-8000-00000000000c $H HUM-3 box-desk human open live - "yes"
  r t1 "" lobby 00000000-0000-4000-8000-0000000000e1 10000000-0000-4000-8000-0000000000e1 $H HUM-10 box-desk terminal open live - ""
  r t1 "" dev 00000000-0000-4000-8000-0000000000e2 10000000-0000-4000-8000-0000000000e2 $H HUM-3 HUM-5 human open live - "for you, not an agent"
  r t1 "" dev 00000000-0000-4000-8000-0000000000e3 10000000-0000-4000-8000-0000000000e3 $H HUM-1 box-desk human open live - "probe post"
  r ws-a "" "" 00000000-0000-4000-8000-00000000000d 10000000-0000-4000-8000-00000000000d $H HUM-9 CLE-5 human open dm files ""
  r t1 "" "" 00000000-0000-4000-8000-0000000000e4 10000000-0000-4000-8000-0000000000e4 $H HUM-10 ALL-0 human open thread - "null channel after an agent"
  r t1 "" "" 00000000-0000-4000-8000-0000000000e7 10000000-0000-4000-8000-0000000000e7 $H HUM-8 HUM-9 human open thread - "addressed to a human even after an agent"
  r csitea "" "" 00000000-0000-4000-8000-0000000000e6 10000000-0000-4000-8000-0000000000e6 $H HUM-3 ALL-0 human open dm - "humans only, no agent in the topic"
} >"$ROWS"

sweep() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" ENV=prd SWEEP_ROWS_FILE="$ROWS" SWEEP_SEND="$T/send.sh" \
    SEND_LOG="$T/sent" SWEEP_NOW="$NOW" HOME="$T/home" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
    do_spl_unanswered_sweep'
}
sends() { grep -c '^TO ' "$T/sent" 2>/dev/null || echo 0; }

echo "CLE-002 $NOW" >"$S/dispatch/lease"
printf 'LEASE_MASTER=CLE-002\nLEASE_FAILOVER=CLE-003\nLEASE_ORCH=CLE-001\n' >"$S/dispatch/lease.conf"

# --- 1 + 2. classification, report only ------------------------------------------------
sweep >"$T/o" 2>&1; rc=$?
open_rows="$(grep -c '^| open |' "$T/o")"
[[ $rc -eq 0 && "$open_rows" == 4 ]] &&
  grep -q '^| open | t1 | #development | 00000000-0000-4000-8000-000000000001 |' "$T/o" &&
  grep -q '^| open | csitea | #spool-hub | 00000000-0000-4000-8000-00000000000c | .* | yes |' "$T/o" &&
  grep -q '^| open | ws-a | dm CLE-5 | .* | (files) |' "$T/o" &&
  grep -q '^| open | t1 | dm ALL-0 | 00000000-0000-4000-8000-0000000000e4 |' "$T/o" &&
  pass "1. human-last topics are listed (a 'yes', a files-only DM, a null-channel follow-up)" || fail "1. open rows=$open_rows rc=$rc $(cat "$T/o")"
grep -q 'broken on the release page \\| please look' "$T/o" && pass "1. a | in a body is escaped in the table" || fail "1. pipe escape"
for t in 02 03 04 05 06 07 08 09 e1 e2 e3 e6 e7; do
  grep -q "^| open .*0000000000$t" "$T/o" && fail "1. topic ..$t should be left out"
done
pass "1. agent-last, archived topic/channel, e2e, proof-*, to a human, terminal, HUM-1, #issues, fresh: left out"
[[ "$(grep -c '^| ack |' "$T/o")" == 2 ]] && pass "1. 'ok thanks!' and an emoji-only post are listed as acks" || fail "1. acks: $(grep '^| ack' "$T/o")"
grep -q '^| t1 | 2 | 0 | 0 | 0 | 2 | 1 | 0 | 1 | 2 | 0 | 0 | 1 | 0 |$' "$T/o" && grep -q '^| csitea | 1 | 2 | 0 | 1 | 0 | 0 | 0 | 0 | 1 | 1 | 1 | 0 | 0 |$' "$T/o" &&
  grep -q '^| e2e | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 |$' "$T/o" && grep -q '^SUM open=4 ack=2 nobody=1 new=4 resend=0 escalate=0$' "$T/o" &&
  pass "1. per-workspace counts" || fail "1. counts: $(grep -A10 'Per workspace' "$T/o")"
# spec 117 1.3: a null-channel ALL-0 with no agent in the topic is read by its
# writer alone. It used to be counted as to-human and listed nowhere; now it
# has its own table, ids and seat only (never the body), and is never sent.
nb="$(sed -n '/^### Reached nobody/,/^###/p' "$T/o")"
[[ "$(grep -c '^| csitea | ' <<<"$nb")" == 1 ]] &&
  grep -q '^| csitea | 00000000-0000-4000-8000-0000000000e6 | 10000000-0000-4000-8000-0000000000e6 | .* | HUM-3 |$' <<<"$nb" &&
  ! grep -q 'humans only, no agent' "$T/o" && ! grep -q '0000000000e7\|0000000000e4\|000000000007 ' <<<"$nb" &&
  pass "1. the reached-nobody table lists the writer-only row (ids + seat, no body); a DM to a human and a thread are not in it" ||
  fail "1. reached nobody: $nb"
[[ ! -e "$T/sent" && ! -e "$S/dispatch/unanswered.state" && ! -e "$S/dispatch/unanswered.last" ]] &&
  grep -q '^PLAN send to CLE-002: \*\*Unanswered sweep\*\*' "$T/o" &&
  pass "2. DELIVER=0: a PLAN line, nothing sent or written" || fail "2. wrote or sent: $(ls "$S/dispatch") $(cat "$T/o")"

# --- 3. deliver ----------------------------------------------------------------------------
sweep DELIVER=1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(sends)" == 1 ]] && grep -q '^TO CLE-002$' "$T/sent" &&
  [[ "$(grep -c '^| NEW |' "$T/sent")" == 4 ]] && ! grep -q 'ok thanks' "$T/sent" &&
  grep -q '00000000-0000-4000-8000-0000000000e4' "$T/sent" &&
  pass "3. ONE note to the lease holder, the 4 NEW items, no ack" || fail "3. rc=$rc $(cat "$T/o") $(cat "$T/sent" 2>/dev/null)"
[[ "$(wc -l <"$S/dispatch/unanswered.state")" == 4 ]] && grep -qx "ts=$NOW" "$S/dispatch/unanswered.last" &&
  grep -qx 'open=4' "$S/dispatch/unanswered.last" && grep -qx 'sent=ok' "$S/dispatch/unanswered.last" &&
  grep -qx 'per=csitea=1,t1=2,ws-a=1' "$S/dispatch/unanswered.last" &&
  pass "3. state (4 items) and last written" || fail "3. state/last: $(cat "$S/dispatch/unanswered.state" "$S/dispatch/unanswered.last")"
sweep DELIVER=1 SWEEP_NOW=$((NOW + 600)) >"$T/o" 2>&1
[[ "$(sends)" == 1 ]] && pass "3. the next sweep re-sends nothing" || fail "3. re-sent: $(cat "$T/sent")"

# --- 4. re-send once, escalate once --------------------------------------------------------
sweep DELIVER=1 SWEEP_NOW=$((NOW + 7200)) >"$T/o" 2>&1
[[ "$(sends)" == 2 && "$(grep -c '^| AGAIN |' "$T/sent")" == 4 ]] && [[ "$(grep -c '^TO CLE-002$' "$T/sent")" == 2 ]] &&
  pass "4. 2 h later: AGAIN to the holder" || fail "4. resend: $(cat "$T/sent")"
sweep DELIVER=1 SWEEP_NOW=$((NOW + 7800)) >"$T/o" 2>&1
[[ "$(sends)" == 2 ]] && pass "4. the re-send happens once" || fail "4. resent twice"
sweep DELIVER=1 SWEEP_NOW=$((NOW + 14400)) >"$T/o" 2>&1
[[ "$(sends)" == 3 ]] && grep -q '^TO CLE-001$' "$T/sent" && [[ "$(grep -c '^| ESC |' "$T/sent")" == 4 ]] &&
  grep -q 'ESCALATION' "$T/sent" && pass "4. 2 h after the re-send: escalated to the orchestrator" || fail "4. escalate: $(cat "$T/sent")"
sweep DELIVER=1 SWEEP_NOW=$((NOW + 30000)) >"$T/o" 2>&1
[[ "$(sends)" == 3 ]] && pass "4. after the escalation: silence" || fail "4. sent after escalation"

# --- 5. a new human post in a known topic --------------------------------------------------
sed -i 's/10000000-0000-4000-8000-000000000001\t[0-9]*/10000000-0000-4000-8000-0000000000f1\t'"$((NOW + 29000))"'/' "$ROWS"
sweep DELIVER=1 SWEEP_NOW=$((NOW + 31000)) >"$T/o" 2>&1
[[ "$(sends)" == 4 ]] && [[ "$(tail -n 20 "$T/sent" | grep -c '^| NEW |')" == 1 ]] && [[ "$(wc -l <"$S/dispatch/unanswered.state")" == 4 ]] &&
  pass "5. a new post in a known topic is NEW; the answered item leaves the state" || fail "5. $(cat "$S/dispatch/unanswered.state") $(tail -12 "$T/sent")"

# --- 5b. the dispatcher ack -----------------------------------------------------------------
ack() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" LEASE_NOW="$NOW" SPOOL_AGENT_ID=CLE-002 "$@" bash -c '
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-ack.func.sh"
    do_spl_unanswered_ack'
}
LD=00000000-0000-4000-8000-00000000000d
ack TOPIC=$LD REASON="a link, no question" >"$T/o" 2>&1 && grep -q "^ACK $LD by CLE-002" "$T/o" &&
  grep -qP "^$NOW\t$LD\tCLE-002\ta link, no question$" "$S/dispatch/unanswered.acks" &&
  pass "5b. the ack is recorded with its time, topic, who and why" || fail "5b. ack: $(cat "$T/o") $(cat "$S/dispatch/unanswered.acks" 2>/dev/null)"
sweep >"$T/o" 2>&1
! grep -q "^| open | ws-a" "$T/o" && grep -q '^| ws-a | 0 | 0 | 1 |' "$T/o" &&
  pass "5b. an acked item is handled: not listed, not sent" || fail "5b. handled: $(grep ws-a "$T/o")"
cp "$ROWS" "$T/rows.keep"
sed -i "s/10000000-0000-4000-8000-00000000000d\t[0-9]*/10000000-0000-4000-8000-0000000000fd\t$((NOW + 100))/" "$ROWS"
sweep SWEEP_NOW=$((NOW + 2000)) >"$T/o" 2>&1
grep -q "^| open | ws-a | dm CLE-5 | $LD |" "$T/o" && pass "5b. a new human post after the ack opens it again" || fail "5b. reopen: $(grep ws-a "$T/o")"
cp "$T/rows.keep" "$ROWS"
ack TOPIC=$LD >"$T/o" 2>&1 && fail "5b. an ack without REASON accepted" || pass "5b. REASON is required"
ack TOPIC=zz REASON=x >"$T/o" 2>&1 && fail "5b. a bad TOPIC accepted" || pass "5b. a bad TOPIC is refused"
ack ACK_LIST=1 >"$T/o" 2>&1; grep -q "| $LD | CLE-002 | a link, no question |" "$T/o" && pass "5b. ACK_LIST shows the acks" || fail "5b. list: $(cat "$T/o")"

# --- 6. a failed send ------------------------------------------------------------------------
rm -f "$S/dispatch/unanswered.state"; : >"$T/sent.fail"
sweep DELIVER=1 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && ! -e "$S/dispatch/unanswered.state" ]] && grep -qx 'sent=FAILED' "$S/dispatch/unanswered.last" &&
  pass "6. a failed send: exit 1, items stay NEW, last says FAILED" || fail "6. rc=$rc $(cat "$S/dispatch/unanswered.last")"
rm -f "$T/sent.fail"

# --- 7. no lease ------------------------------------------------------------------------------
rm -f "$S/dispatch/lease"
sweep >"$T/o" 2>&1
grep -q '^PLAN send to CLE-002:' "$T/o" && pass "7. no lease: the master from lease.conf" || fail "7. $(grep PLAN "$T/o")"
echo "CLE-003 $NOW" >"$S/dispatch/lease"
sweep >"$T/o" 2>&1
grep -q '^PLAN send to CLE-003:' "$T/o" && pass "7. the failover when it holds the lease" || fail "7. $(grep PLAN "$T/o")"

# --- 8. refusals ------------------------------------------------------------------------------
sweep ENV=stg >"$T/o" 2>&1 && fail "8. ENV=stg accepted" || pass "8. ENV other than dev/prd refused"
sweep DELIVER=2 >"$T/o" 2>&1 && fail "8. DELIVER=2 accepted" || pass "8. DELIVER must be 0 or 1"
sweep SWEEP_MIN_AGE=x >"$T/o" 2>&1 && fail "8. SWEEP_MIN_AGE=x accepted" || pass "8. a non-integer knob refused"

# --- 9. the dispatch check row ----------------------------------------------------------------
crow() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" LEASE_NOW="$1" "${@:2}" bash -c '
    gaps=0; do_log() { echo "$*"; }
    row() { echo "| $1 | $2 | $3 |"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
    spl_lease_init ro; spl_sweep_check_row'
}
printf 'ts=%s\nopen=3\nper=csitea=1,t1=2\nto=CLE-002\nsent=ok\n' "$NOW" >"$S/dispatch/unanswered.last"
crow $((NOW + 60)) | grep '| unanswered sweep | last 60s ago to CLE-002, 3 open (csitea=1, t1=2) | ok |' >/dev/null &&
  pass "9. a fresh sweep: ok with its open count" || fail "9. $(crow $((NOW + 60)))"
crow $((NOW + 4000)) | grep 'GAP stale' >/dev/null && pass "9. stale: GAP" || fail "9. stale: $(crow $((NOW + 4000)))"
sed -i 's/sent=ok/sent=FAILED/' "$S/dispatch/unanswered.last"
crow $((NOW + 60)) | grep 'GAP the last note was not delivered' >/dev/null && pass "9. failed send: GAP" || fail "9. failed"
# 9b. a standby box: its sweep sends nothing while another machine holds the
#     lease, so a stale sent=FAILED file from when it held it is no GAP; the
#     control is the same file with the lease held on this machine
cp "$S/dispatch/lease" "$T/lease.keep"
echo "c-002@box-b $NOW" >"$S/dispatch/lease"
crow $((NOW + 60)) LEASE_MACHINE=box-a >"$T/o" 2>&1
! grep -q 'GAP' "$T/o" && grep -q '| unanswered sweep | .* | ok (remote holder c-002@box-b: that machine sends) |' "$T/o" &&
  pass "9b. remote lease + stale sent=FAILED: ok, no GAP" || fail "9b. remote: $(cat "$T/o")"
crow $((NOW + 60)) LEASE_MACHINE=box-b | grep 'GAP the last note was not delivered' >/dev/null &&
  pass "9b. control: the same file + a LOCAL lease is still a GAP" || fail "9b. local: $(crow $((NOW + 60)) LEASE_MACHINE=box-b)"
cp "$T/lease.keep" "$S/dispatch/lease"
rm -f "$S/dispatch/unanswered.last"
crow "$NOW" | grep 'never ran | GAP' >/dev/null && pass "9. never ran: GAP" || fail "9. never: $(crow "$NOW")"

# --- 10. the cron install -----------------------------------------------------------------------
# a fake crontab: -l prints the file, <file> replaces it
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/unanswered-sweep-cron.sh" "$SRC/csi-spl-orc/src/bash/scripts/"
printf '*/3 * * * * other job # csi-spl:desk-reconcile\n' >"$T/crontab"
cron() {
  env PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" PROJ_PATH="$PROJ_ROOT" DESK_CRON_SRC="$SRC" \
    SWEEP_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep-install-cron.func.sh"
    do_spl_unanswered_sweep_install_cron'
}
before="$(md5sum <"$T/crontab")"
cron >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q '^    +\* \* \* \* \* ENV=prd SWEEP_MIN_AGE=3 SWEEP_ESCALATE_AGE=5 .*unanswered-sweep-cron.sh >> .*/cron.out 2>&1 # csi-spl:unanswered-sweep$' "$T/o" &&
  pass "10. dry run: the diff, nothing written" || fail "10. dry: rc=$rc $(cat "$T/o")"
cron SWEEP_CRON_ACTION=check >"$T/o" 2>&1 && fail "10. check passed with no line" || pass "10. check fails while not installed"
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
want="* * * * * ENV=prd SWEEP_MIN_AGE=3 SWEEP_ESCALATE_AGE=5 $SRC/csi-spl-orc/src/bash/scripts/cron-no-stack.sh $T/log/cron.lock $SRC/csi-spl-orc/src/bash/scripts/unanswered-sweep-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:unanswered-sweep"
[[ $rc -eq 0 && "$(grep -c 'unanswered-sweep$' "$T/crontab")" == 1 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'desk-reconcile' "$T/crontab" &&
  pass "10. DRY_RUN=0: one exact tagged line (every minute, min age 3, escalation 5), the other line kept" || fail "10. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cron SWEEP_CRON_EVERY=10 >"$T/o" 2>&1
grep -q '^    [-+]2-59/10 \* \* \* \* ENV=prd SWEEP_MIN_AGE=3 ' "$T/o" && pass "10. SWEEP_CRON_EVERY=10 keeps the offset schedule" || fail "10. every 10: $(cat "$T/o")"
cron SWEEP_CRON_MIN_AGE=6 >"$T/o" 2>&1 && fail "10. an escalation before the min age accepted" || pass "10. SWEEP_CRON_ESCALATE_AGE < SWEEP_CRON_MIN_AGE refused"
cron DRY_RUN=0 >/dev/null 2>&1; cron DRY_RUN=0 ENV=dev >/dev/null 2>&1
[[ "$(grep -c '# csi-spl:unanswered-sweep$' "$T/crontab")" == 1 && "$(grep -c '# csi-spl:unanswered-sweep-dev$' "$T/crontab")" == 1 ]] &&
  pass "10. idempotent; the dev line is its own" || fail "10. lines: $(cat "$T/crontab")"
cron SWEEP_CRON_ACTION=check >"$T/o" 2>&1 && pass "10. check passes once installed" || fail "10. check: $(cat "$T/o")"
cron SWEEP_CRON_ACTION=remove DRY_RUN=0 ENV=dev >/dev/null 2>&1
[[ "$(grep -c 'unanswered-sweep' "$T/crontab")" == 1 ]] && grep -q '# csi-spl:unanswered-sweep$' "$T/crontab" &&
  pass "10. removing dev leaves prd" || fail "10. remove: $(cat "$T/crontab")"
mkdir -p "$T/repo-wt/X"
cron DESK_CRON_SRC="$T/repo-wt/X" >"$T/o" 2>&1 && fail "10. a worktree source accepted" || pass "10. an agent worktree is refused"
SWEEP_CRON_TOOLS=bash bash "$SRC/csi-spl-orc/src/bash/scripts/unanswered-sweep-cron.sh" --check-tools >"$T/o" 2>&1 &&
  SWEEP_CRON_TOOLS=no-such-tool-x bash "$SRC/csi-spl-orc/src/bash/scripts/unanswered-sweep-cron.sh" --check-tools >"$T/o" 2>&1
[[ $? -eq 3 ]] && grep -q 'no-such-tool-x' "$T/o" && pass "10. the cron script names a missing tool (exit 3)" || fail "10. tools: $(cat "$T/o")"

# --- 12. M3: a burst is aged from its OLDEST unanswered post ------------------------------------
S="$T/spool12"; mkdir -p "$S/dispatch"; rm -f "$T/sent"
echo "c-002 $NOW" >"$S/dispatch/lease"
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
B=00000000-0000-4000-8000-0000000000b1
# burst_rows <minute> [first msg n]: the topic's row as the hub hands it at
# <minute>: the newest post (one every 2 min from minute 0) plus the oldest
# unanswered one (msg n, default 0)
burst_rows() {
  local last=$(( $1 / 2 * 2 )) f="${2:-0}"
  printf '%s\t\tdev\t%s\t10000000-0000-4000-8000-0000000000%02d\t%s\tHUM-10\tbox-desk\thuman\topen\tlive\t-\tpost %s\t%s\t10000000-0000-4000-8000-0000000000%02d\n' \
    t1 "$B" "$last" $(( NOW + last * 60 )) "$last" $(( NOW + f * 60 )) "$f" >"$T/rows12.tsv"
}
s12() { sweep SWEEP_ROWS_FILE="$T/rows12.tsv" DELIVER=1 SWEEP_MIN_AGE=3 SWEEP_ESCALATE_AGE=5 SWEEP_NOW=$(( NOW + $1 * 60 )); }
listed="" escalated=""
for m in 0 1 2 3 4 5 6 7 8 9; do
  burst_rows "$m"; n0="$(sends)"; l0="$(cat "$T/sent" 2>/dev/null | wc -l)"; s12 "$m" >"$T/o" 2>&1
  [[ "$(sends)" != "$n0" ]] || continue
  tail -n +$(( l0 + 1 )) "$T/sent" | grep '^| NEW | t1 | #dev | '"$B"' |' >/dev/null && listed="$listed $m"
  tail -n +$(( l0 + 1 )) "$T/sent" | grep '^| ESC | t1 | #dev | '"$B"' |' >/dev/null && escalated="$escalated $m"
done
[[ "$listed" == " 3" ]] && pass "12. a burst every 2 min is listed at minute 3, once (NEW to the holder)" ||
  fail "12. listed at minute(s) '${listed# }' (want 3)"
[[ "$escalated" == " 5" ]] && grep -q '^TO c-001$' "$T/sent" &&
  pass "12. ... and escalated to the orchestrator at minute 5, once" || fail "12. escalated at minute(s) '${escalated# }' (want 5): $(cat "$T/sent" 2>/dev/null)"
[[ "$(sends)" == 2 && "$(grep -c '^| AGAIN |' "$T/sent")" == 0 ]] &&
  pass "12. 10 sweeps, 5 posts: 2 notes in all, no AGAIN" || fail "12. notes: $(sends) $(grep -c '^| AGAIN |' "$T/sent")"
grep -q '^| ESC | t1 | #dev | '"$B"' | .* | 5m | HUM-10 | post 4 |' "$T/sent" &&
  pass "12. the row shows the newest post and the age of the oldest" || fail "12. row: $(grep '^| ESC' "$T/sent")"
# an agent answered after minute 9; a post at minute 12 starts a new item
burst_rows 12 12; s12 14 >"$T/o" 2>&1
grep -q '^| open | t1 | #dev | '"$B"' |' "$T/o" && fail "12. the post after the reply listed at 2 min" ||
  pass "12. a post after an agent reply is aged from itself (fresh at 2 min)"
n0="$(sends)"; s12 15 >"$T/o" 2>&1
[[ "$(sends)" == $(( n0 + 1 )) ]] && tail -n 30 "$T/sent" | grep '^| NEW | .* | 3m | HUM-10 | post 12 |' >/dev/null &&
  pass "12. ... and is a NEW item at 3 min" || fail "12. new after reply: $(tail -n 12 "$T/sent")"
# the control: one lone post (13-column row, its own anchor) waits the same 3 min
printf '%s\t\tdev\t%s\t10000000-0000-4000-8000-0000000000ff\t%s\tHUM-10\tbox-desk\thuman\topen\tlive\t-\tlone post\n' t1 "${B%1}2" "$NOW" >"$T/rows12.tsv"
rm -f "$S/dispatch/unanswered.state"
s12 2 >"$T/o" 2>&1; a="$(grep -c '^| open |' "$T/o")"; s12 3 >"$T/o" 2>&1; b="$(grep -c '^| open |' "$T/o")"
[[ "$a $b" == "0 1" ]] && pass "12. control: a lone post (old 13-column row) is fresh at 2 min, listed at 3" || fail "12. lone: $a $b"

# --- 13. SPL-1718: a take line is not the answer --------------------------------------------------
S="$T/spool13"; mkdir -p "$S/dispatch"; rm -f "$T/sent"
echo "c-002 $NOW" >"$S/dispatch/lease"
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
TK=00000000-0000-4000-8000-0000000000d1 HM=10000000-0000-4000-8000-0000000000d1
# take_rows <minute> [take|agent]: the topic's row as the hub hands it: the
# human post (minute 0), then from minute 1 the take line (or a real reply)
# with the human post as its anchor, from minute 35 a real answer (no anchor)
take_rows() {
  if (( $1 == 0 )); then
    printf '%s\t\tdev\t%s\t%s\t%s\tHUM-10\tbox-desk\thuman\topen\tlive\t-\twhy is the deploy red\t%s\t%s\n' t1 "$TK" "$HM" "$NOW" "$NOW" "$HM"
  elif (( $1 >= 35 )) || [[ "${2:-take}" == agent ]]; then
    printf '%s\t\tdev\t%s\t10000000-0000-4000-8000-0000000000d3\t%s\tc-002\tHUM-10\tagent\topen\tlive\t-\t\t\t\n' t1 "$TK" $(( NOW + 60 ))
  else
    printf '%s\t\tdev\t%s\t10000000-0000-4000-8000-0000000000d2\t%s\tc-002\tHUM-10\ttake\topen\tlive\t-\t\t%s\t%s\n' t1 "$TK" $(( NOW + 60 )) "$NOW" "$HM"
  fi >"$T/rows13.tsv"
}
s13() { sweep SWEEP_ROWS_FILE="$T/rows13.tsv" DELIVER=1 SWEEP_MIN_AGE=3 SWEEP_ESCALATE_AGE=5 SWEEP_NOW=$(( NOW + $1 * 60 )) "${@:2}"; }
# run13 <take|agent> [env...]: 41 sweeps, minute 0..40; sets listed / escalated / taken13
run13() {
  local kind="$1" m n0 l0; shift
  listed="" escalated="" taken13=0; rm -f "$T/sent" "$S/dispatch/unanswered.state"
  for m in $(seq 0 40); do
    take_rows "$m" "$kind"; n0="$(sends)"; l0="$(cat "$T/sent" 2>/dev/null | wc -l)"; s13 "$m" "$@" >"$T/o" 2>&1
    grep -q '^| t1 | 0 | 0 | 0 | 0 | 0 | 0 | 1 |' "$T/o" && taken13=$(( taken13 + 1 ))
    [[ "$(sends)" != "$n0" ]] || continue
    tail -n +$(( l0 + 1 )) "$T/sent" | grep '^| NEW | t1 | #dev | '"$TK"' |' >/dev/null && listed="$listed $m"
    tail -n +$(( l0 + 1 )) "$T/sent" | grep '^| ESC | t1 | #dev | '"$TK"' |' >/dev/null && escalated="$escalated $m"
  done
}
run13 take
[[ "$listed" == " 31" && "$escalated" == " 32" && "$(sends)" == 2 ]] &&
  pass "13. a take at minute 1, no answer: NEW at minute 31, ESC at 32, each once (n=41 sweeps, 2 notes)" ||
  fail "13. take: listed '${listed# }' (want 31) escalated '${escalated# }' (want 32) notes $(sends)"
[[ "$taken13" == 30 ]] && pass "13. the 30 sweeps of minutes 1..30 count it 'taken'" || fail "13. taken in $taken13 sweep(s) (want 30)"
grep -q '^| NEW | t1 | #dev | '"$TK"' | .* | 31m | c-002 | (taken by c-002 30m ago, no answer since) |' "$T/sent" &&
  pass "13. the row is aged from the human post and names the taker" || fail "13. row: $(grep '^| NEW' "$T/sent")"
run13 agent
[[ -z "$listed$escalated" && "$(sends)" == 0 ]] &&
  pass "13. CONTROL: a real agent reply at minute 1 is never listed (41 sweeps, 0 notes)" || fail "13. control reply: '$listed' '$escalated' $(sends)"
run13 take SWEEP_TAKE_GRACE=10
[[ "$listed" == " 11" && "$escalated" == " 12" ]] && pass "13. SWEEP_TAKE_GRACE=10: NEW at minute 11, ESC at 12" ||
  fail "13. grace 10: '${listed# }' '${escalated# }'"
printf '%s\t\tdev\t%s\t10000000-0000-4000-8000-0000000000d2\t%s\tc-002\tHUM-10\ttake\topen\tlive\t-\t\t\t\n' t1 "$TK" "$H" >"$T/rows13.tsv"
sweep SWEEP_ROWS_FILE="$T/rows13.tsv" >"$T/o" 2>&1
grep -q '^| t1 | 0 | 0 | 0 | 0 | 0 | 1 | 0 |' "$T/o" && pass "13. CONTROL: a take with no human post before it is answered" || fail "13. no anchor: $(grep '^| t1' "$T/o")"
sweep SWEEP_ROWS_FILE="$T/rows13.tsv" SWEEP_TAKE_GRACE=0 >"$T/o" 2>&1
grep -q 'FATAL SWEEP_TAKE_GRACE must be a positive integer' "$T/o" && pass "13. SWEEP_TAKE_GRACE=0 is refused" || fail "13. grace 0: $(cat "$T/o")"

# --- 11. seats: the sweep stays, from every box, one peers note per item (D7) -------------------
S="$T/spool11"; mkdir -p "$S/dispatch" "$S/peer"; rm -f "$T/sent"
CB=00000000-0000-4000-8000-0000000000cb
{
  r t1 "" development 00000000-0000-4000-8000-0000000000c1 10000000-0000-4000-8000-0000000000c1 $H HUM-27 box-desk human open live - "first open item"
  r csitea "" spool-hub 00000000-0000-4000-8000-0000000000c2 10000000-0000-4000-8000-0000000000c2 $H HUM-3 box-desk human open live - "second open item"
  # the planted claim bug: the hub says a seat owns this job, but that seat's
  # gen is dead and nobody answers. The sweep reads the last message, never
  # the claim, so it must still be listed
  r t1 "" development $CB 10000000-0000-4000-8000-0000000000cb $H HUM-27 box-desk human open live - "owned by a dead gen"
  r t1 "" development 00000000-0000-4000-8000-0000000000c3 10000000-0000-4000-8000-0000000000c3 $H CLE-77 HUM-27 agent open live - ""
} >"$T/rows11.tsv"
echo "c-002@box-b $NOW" >"$S/dispatch/lease"
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$S/dispatch/lease.conf"
printf '# seats of this box\nc-001 claude\nc-002 claude\n' >"$S/peer/seats"
s11() { sweep SWEEP_ROWS_FILE="$T/rows11.tsv" LEASE_MACHINE=box-a "$@"; }
# per note in the fake send log: "<to> <item rows in it>"
notes() { awk '/^TO /{to=$2; n=0} /^\| (NEW|AGAIN|ESC) \|/{n++} /^END$/{print to, n}' "$T/sent" 2>/dev/null; }
s11 >"$T/o" 2>&1
grep -q '^PLAN send to peers: 3 note(s), one per item:' "$T/o" && [[ ! -e "$T/sent" ]] &&
  pass "11. DELIVER=0 with seats: the plan is 3 peers notes, nothing sent" || fail "11. plan: $(grep PLAN "$T/o")"
s11 DELIVER=1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(notes | sort | uniq -c | sed 's/^ *//')" == "3 peers 1" ]] &&
  pass "11. seats + the lease on another box: this box sends, 3 notes to peers, one item each" || fail "11. rc=$rc notes=$(notes) $(cat "$T/o")"
grep -q "^| NEW | t1 | #development | $CB | .* | owned by a dead gen |" "$T/sent" &&
  pass "11. the planted claim bug (owned, holder gen dead) is still reported" || fail "11. claim bug missing: $(cat "$T/sent")"
grep -q '^\*\*Unanswered sweep\*\*' "$T/sent" && [[ "$(grep -c '^| | workspace |' "$T/sent")" == 3 ]] &&
  pass "11. each note carries the heading and the table header" || fail "11. note shape: $(cat "$T/sent")"
grep -qx 'to=peers' "$S/dispatch/unanswered.last" && grep -qx 'sent=ok' "$S/dispatch/unanswered.last" &&
  pass "11. last records to=peers" || fail "11. last: $(cat "$S/dispatch/unanswered.last")"
n_sql="$(PROJ_PATH="$PROJ_ROOT" bash -c 'source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"; _spl_sweep_rows_sql' | grep -ciE 'claim|responsible|offer_n|handled_at')"
[[ "$n_sql" == 0 ]] && pass "11. the hub read names no claim column (it does not trust the claim)" || fail "11. the sweep SQL reads the claim: $n_sql line(s)"
s11 DELIVER=1 SWEEP_NOW=$((NOW + 7200)) >"$T/o" 2>&1
[[ "$(notes | tail -3 | sort -u)" == "peers 1" && "$(grep -c '^| AGAIN |' "$T/sent")" == 3 ]] &&
  pass "11. 2 h later: 3 AGAIN notes to peers" || fail "11. again: $(notes)"
s11 DELIVER=1 SWEEP_NOW=$((NOW + 14400)) >"$T/o" 2>&1
[[ "$(notes | wc -l)" == 9 && "$(notes | tail -3 | sort -u)" == "peers 1" && "$(grep -c '^| ESC |' "$T/sent")" == 3 ]] &&
  grep -q 'ESCALATION' "$T/sent" && ! grep -q '^TO c-001$' "$T/sent" &&
  pass "11. the escalation: 3 ESC notes to peers, none to a fixed id" || fail "11. esc: $(notes)"
crow $((NOW + 14460)) LEASE_MACHINE=box-a >"$T/o" 2>&1
grep -q '| unanswered sweep | last 60s ago to peers, 3 open' "$T/o" && ! grep -q 'remote holder' "$T/o" &&
  pass "11. the check row judges a seated box (no remote-holder pass)" || fail "11. check row: $(cat "$T/o")"
# control: no seat line -> today's recipient
rm -f "$T/sent" "$S/dispatch/unanswered.state"
printf '# no seat yet\n' >"$S/peer/seats"
s11 DELIVER=1 >"$T/o" 2>&1
[[ ! -e "$T/sent" ]] && grep -q 'held by c-002@box-b: this machine.s sweep sends nothing' "$T/o" &&
  pass "11. control: a seats file with no seat + a remote lease: nothing sent from here (today)" || fail "11. control remote: $(cat "$T/o") $(cat "$T/sent" 2>/dev/null)"
rm -f "$S/peer/seats"
s11 DELIVER=1 LEASE_MACHINE=box-b >"$T/o" 2>&1
[[ "$(notes)" == "c-002 3" ]] && ! grep -q '^TO peers' "$T/sent" &&
  pass "11. control: no seats file + a local lease: ONE note with 3 items to the lease holder (today)" || fail "11. control local: notes=$(notes) $(cat "$T/o")"

echo
(( fails == 0 )) && { echo "unanswered-sweep: all passed"; exit 0; }
echo "unanswered-sweep: $fails failure(s)"; exit 1
