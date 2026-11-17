#!/usr/bin/env bash
# rotate-open-takes.tst.sh - a role rotation hands the old session's open
# takes to the new one, and rings the new pane for a post the old one heard
# (SPL-5523, spec 060 section 6).
#
# 2026-11-11 08:46:56Z HUM-24's post e3347dc8 rang the retiring c-002
# pane 37 s after the new session's ack; the old session declined it
# (381296b6), the new one heard nothing until the owner named it at 09:01Z.
# The handoff listed screen, asks, outbox, inbox, lanes, never the takes.
# Cases:
#   (a) three takes by the seat, one answered: the handoff lists exactly the
#       two open ones, with workspace and human from the desk's take line
#   (b) not listed: another seat's take, a take older than 48 h, a take whose
#       only later post went to an agent is still open (an agent relay
#       answers nobody)
#   (c) the seed says they are the new session's own, and lists them
#   (d) no take at all: section 10 says none, the seed says none
#   (e) after CLOSE the inbox message that came in after the handoff is rung
#       again on the new pane; one from before is not
#   (f) SPL-5629: the desk root belongs to the desk user and the caller (the
#       rotation, the box user) cannot enter it: the outbox is read as the
#       desk user (sudo -n -u), so an answered take is not listed
#   (g) SPL-5629: that read fails too: section 10 is ONE warning line
#       "outboxes unreadable as <caller>: takes unverified", no take rows
#   (h) SPL-5704: no desk take line (workspace ?), but the sweep's topic rows
#       (<lease dir>/unanswered.rows) say the topic is archived, or its last
#       post is another agent's to a person after the take: not listed; a
#       topic whose last line is the take itself, or an agent relay, stays
#   (i) SPL-5737: the topic has an unanswered.acks row ("no reply needed"):
#       an ack at or after the take, or at most 300 s before it (the
#       2026-11-16 a6d4d910 shape: ack 10 s before the take), drops the take;
#       an ack 400 s before it does not
#
# Red control: ROTATE_LIB=<origin/master's spl-rotate-lib.func.sh> lists 0;
# the lib before SPL-5629 fails (f) and (g); before SPL-5704 fails (h);
# before SPL-5737 fails (i).
# Run: bash csi-spl-orc/src/bash/tests/rotate-open-takes.tst.sh </dev/null
# shellcheck disable=SC2034 # the ROTATE_* / LEASE_* globals are read by the sourced lib
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export SPOOL_ROOT="$T/spool" SPOOL_TEST=1
# shellcheck source=/dev/null
source "${ROTATE_LIB:-$HERE/../run/spl-rotate-lib.func.sh}"
set -o pipefail

ID=c-902 BOX=box-t now="$(date +%s)"
ROTATE_BOX="$BOX" LEASE_DIR="$T/dispatch" LEASE_FILE="$T/dispatch/lease"
ROTATE_SPEC=spec.md ROTATE_HOLD_DIR="$T/hold" ROTATE_MEMORY_DIR="$T/memory"
ROTATE_RUN=false ROTATE_TMUX=false ROTATE_OLD_PID=1 ROTATE_OLD_PANE=""
ROTATE_TRANSCRIPT="$T/none.jsonl"
mkdir -p "$LEASE_DIR" "$SPOOL_ROOT/$ID/inbox" "$ROTATE_HOLD_DIR" "$ROTATE_MEMORY_DIR"
A=aaaaaaaa-0000-4000-8000-000000000001 B=bbbbbbbb-0000-4000-8000-000000000002
C=cccccccc-0000-4000-8000-000000000003 D=dddddddd-0000-4000-8000-000000000004
E=eeeeeeee-0000-4000-8000-000000000005

# take EPOCH TOPIC BY PLAN: one ledger row, do_spl_take's format
take() { printf '%s\t%s\t%s\t%s\tpost-%s\n' "$1" "$2" "$3" "$4" "${2:0:4}" >> "$LEASE_DIR/take.log"; }
# post WS EPOCH TOPIC TO BODY: one message of ID in that workspace's desk outbox
n=0
post() {
  n=$((n + 1))
  mkdir -p "$T/desk/$1/$BOX/spool/$ID/outbox"
  jq -n --arg ts "$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)" --arg t "$3" --arg to "$4" --arg b "$5" --arg id "m-$n" \
    '{v: 1, msg_id: $id, task_id: $t, ts: $ts, from: "c-902", to: $to, kind: "note", body: $b, files: []}' \
    > "$T/desk/$1/$BOX/spool/$ID/outbox/$n.json"
}
line() { echo "Taken by $ID@$BOX: $1. I post the result here."; }

take $((now - 900)) "$A" "$ID@$BOX" "I read the invoices"
take $((now - 800)) "$B" "$ID@$BOX" "I check the relay link"
take $((now - 700)) "$C" "$ID@$BOX" "I answer the status"
take $((now - 600)) "$D" "c-903@$BOX" "another seat's take"
take $((now - 72 * 3600)) "$E" "$ID@$BOX" "an old take"
post csitea $((now - 900)) "$A" HUM-24 "$(line 'I read the invoices')"
post csitea $((now - 850)) "$A" c-001 "relay to the orchestrator"
post t1 $((now - 800)) "$B" HUM-10 "$(line 'I check the relay link')"
post csitea $((now - 700)) "$C" HUM-10 "$(line 'I answer the status')"
post csitea $((now - 650)) "$C" HUM-10 "**Done:** the status is green."
ROTATE_TAKES_OUTBOXES="csitea	$T/desk/csitea/$BOX/spool/$ID/outbox
t1	$T/desk/t1/$BOX/spool/$ID/outbox"

# section 10 of the handoff: its "- topic" lines
spl_rotate_handoff master "$ID" rid-1 "$T/handoff.md" >/dev/null 2>&1 || true
sec="$(sed -n '/^## 10\. Open takes/,/^## /p' "$T/handoff.md" 2>/dev/null)"
got="$(grep -c '^- topic ' <<<"$sec" || true)"
echo "open takes listed: $got"
[[ "$got" == 2 ]] && pass "(a) the handoff lists exactly the two open takes" || fail "(a) want 2 listed, got $got: $sec"
grep -q "^- topic $A, workspace csitea, HUM-24, taken .*: I read the invoices$" <<<"$sec" &&
  grep -q "^- topic $B, workspace t1, HUM-10, taken .*: I check the relay link$" <<<"$sec" &&
  pass "(a) each with its workspace, human, take time and plan" || fail "(a) rows: $sec"
grep -qE "$C|$D|$E" <<<"$sec" && fail "(b) an answered, foreign or old take is listed" ||
  pass "(b) answered, another seat's and 48 h old takes left out; an agent relay is no answer"
[[ "$(sed -n 1p <<<"${ROTATE_OPEN_TAKES:-}" | cut -f1)" == "$B" ]] && pass "(a) newest first" || fail "(a) order: ${ROTATE_OPEN_TAKES:-none}"

seed="$(spl_rotate_open_takes_seed 2>/dev/null)"
grep -q "They are yours now" <<<"$seed" && [[ "$(grep -c '^- topic ' <<<"$seed")" == 2 ]] &&
  pass "(c) the seed says they are the new session's and lists both" || fail "(c) seed: $seed"

# (d) no take at all
: > "$LEASE_DIR/take.log"
spl_rotate_handoff master "$ID" rid-2 "$T/handoff2.md" >/dev/null 2>&1 || true
sed -n '/^## 10\. Open takes/,$p' "$T/handoff2.md" | grep -x none >/dev/null &&
  [[ "$(spl_rotate_open_takes_seed)" == "Open takes: none (handoff section 10)." ]] &&
  pass "(d) no take: none in the handoff and the seed" || fail "(d) $(tail -3 "$T/handoff2.md")"

# (e) the re-ring after CLOSE
printf '#!/bin/bash\necho "$*" >> %s/notify.log\n' "$T" > "$T/notify"
chmod +x "$T/notify"
ROTATE_NOTIFY="$T/notify" ROTATE_HANDOFF="$T/handoff.md"
touch -d '-1 hour' "$ROTATE_HANDOFF"
echo '{"from":"c-001","kind":"note","task_id":"x","msg_id":"old-1","body":"before"}' > "$SPOOL_ROOT/$ID/inbox/1.json"
touch -d '-2 hours' "$SPOOL_ROOT/$ID/inbox/1.json"
echo '{"from":"HUM-24","kind":"note","task_id":"49510bea","msg_id":"e3347dc8","body":"attach the invoice"}' > "$SPOOL_ROOT/$ID/inbox/2.json"
rung="$(spl_rotate_reping "$ID" 2>/dev/null)"
[[ "$rung" == 1 ]] && grep -q -- "--to $ID --from HUM-24 --kind note --task 49510bea --msg-id e3347dc8 --body attach the invoice" "$T/notify.log" &&
  ! grep -q old-1 "$T/notify.log" &&
  pass "(e) the post that came in after the handoff is rung on the new pane, the older one not" ||
  fail "(e) rung=${rung:-none}: $(cat "$T/notify.log" 2>/dev/null)"

# (f) and (g): the real outbox walk (no ROTATE_TAKES_OUTBOXES) over a desk
# root the caller cannot enter; the box config and sudo are stubs
unset ROTATE_TAKES_OUTBOXES
DU=desk-usr R="$T/desk-user-root"
spl_desk_roots() { printf '%s\t%s\n' "$(id -un)" "$T/caller-root" "$DU" "$R"; }
spl_desk_user() { echo "$DU"; }
spl_desk_box_default() { echo "$BOX"; }
spl_rotate_can_enter() { [[ "$1" != "$R"* ]]; }
printf '#!/bin/bash\necho "$*" >> %s/sudo.log\n[[ -e %s/sudo.deny || "$1 $2 $3" != "-n -u %s" ]] && exit 1\nshift 3; exec "$@"\n' "$T" "$T" "$DU" > "$T/sudo"
chmod +x "$T/sudo"
ROTATE_SUDO="$T/sudo"
F=ffffffff-0000-4000-8000-000000000006
: > "$LEASE_DIR/take.log"
take $((now - 500)) "$F" "$ID@$BOX" "I answer the invoice"
fpost() {
  n=$((n + 1)); mkdir -p "$R/desk/t1/$BOX/spool/$ID/outbox"
  jq -n --arg ts "$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)" --arg t "$F" --arg to HUM-10 --arg b "$2" --arg id "m-$n" \
    '{v: 1, msg_id: $id, task_id: $t, ts: $ts, from: "c-902", to: $to, kind: "note", body: $b, files: []}' \
    > "$R/desk/t1/$BOX/spool/$ID/outbox/$n.json"
}
fpost $((now - 500)) "$(line 'I answer the invoice')"
fpost $((now - 450)) "**Done:** the invoice is attached."
spl_rotate_handoff master "$ID" rid-3 "$T/handoff3.md" >/dev/null 2>&1 || true
sec="$(sed -n '/^## 10\. Open takes/,$p' "$T/handoff3.md" 2>/dev/null)"
grep -qx none <<<"$sec" && grep -q -- "-n -u $DU" "$T/sudo.log" 2>/dev/null &&
  pass "(f) a desk root the caller cannot enter is read as the desk user: the answered take is not listed" ||
  fail "(f) want none, read as $DU; got: $sec; sudo: $(cat "$T/sudo.log" 2>/dev/null)"
touch "$T/sudo.deny"
spl_rotate_handoff master "$ID" rid-4 "$T/handoff4.md" >/dev/null 2>&1 || true
sec="$(sed -n '/^## 10\. Open takes/,$p' "$T/handoff4.md" 2>/dev/null)"
seed="$(spl_rotate_open_takes_seed 2>/dev/null)"
[[ "$(grep -c '^- topic ' <<<"$sec")" == 0 ]] &&
  [[ "$(grep -c "^- outboxes unreadable as $(id -un): takes unverified (1 take(s)" <<<"$sec")" == 1 ]] &&
  grep -q '^Open takes: unverified' <<<"$seed" && ! grep -q 'They are yours now' <<<"$seed" &&
  pass "(g) unreadable outboxes: one warning line, no take rows, the seed says unverified" ||
  fail "(g) section 10: $sec; seed: $seed"

# (h) SPL-5704: the topic rows of the unanswered sweep. 2026-11-15 the c-002
# seed listed two takes (ledger rows 1794641518, 1794662030) as "workspace ?"
# for 48 h: both archived, one answered by c-003. Row columns: ws name
# channel topic msg epoch from to kind topic-state channel-state files body
# anchor-epoch anchor-msg.
# Row G is the archived case only: its last post precedes the take, so the
# agent-answer rule alone cannot drop it (R7 W1).
rm -f "$T/sudo.deny"
ROTATE_TAKES_OUTBOXES=""
G=99999999-0000-4000-8000-000000000007 H=88888888-0000-4000-8000-000000000008
K=77777777-0000-4000-8000-000000000009 L=66666666-0000-4000-8000-00000000000a
: > "$LEASE_DIR/take.log"
take $((now - 400)) "$G" "$ID@$BOX" "I close the issue"
take $((now - 300)) "$H" "$ID@$BOX" "I raise the cutoff"
take $((now - 200)) "$K" "$ID@$BOX" "I queue the lanes"
take $((now - 100)) "$L" "$ID@$BOX" "I check the relay"
row() { printf 't1\tspool-hub\tops\t%s\tm-%s\t%s\t%s\t%s\t%s\t%s\tlive\t-\t\t\t\n' "$1" "$2" "$2" "$3" "$4" "$5" "$6"; }
{ row "${G^^}" $((now - 410)) "$ID" HUM-10 agent archived
  row "$H" $((now - 250)) c-903 HUM-10 agent open
  row "$K" $((now - 200)) "$ID" HUM-10 take open
  row "$L" $((now - 50)) "$ID" c-001 agent open; } > "$LEASE_DIR/unanswered.rows"
spl_rotate_handoff master "$ID" rid-5 "$T/handoff5.md" >/dev/null 2>&1 || true
sec="$(sed -n '/^## 10\. Open takes/,$p' "$T/handoff5.md" 2>/dev/null)"
! grep -q "$G" <<<"$sec" && pass "(h) an archived topic is not listed" || fail "(h) archived $G listed: $sec"
! grep -q "$H" <<<"$sec" && pass "(h) another agent's later post to a person answers the take" || fail "(h) answered $H listed: $sec"
grep -q "^- topic $K, workspace ?, ?, " <<<"$sec" && grep -q "^- topic $L, workspace ?, ?, " <<<"$sec" &&
  pass "(h) a topic whose last line is the take, or an agent relay, stays listed" || fail "(h) want $K and $L: $sec"
rm -f "$LEASE_DIR/unanswered.rows"

# (i) SPL-5737: <lease dir>/unanswered.acks, do_spl_unanswered_ack's rows
# "<epoch>\t<topic or prefix>\t<by>\t<reason>". The 2026-11-16 c-002 seed
# listed a6d4d910 although c-002 had acked it 10 s before the take
# (acks 1794834423, take.log 1794834433).
M=55555555-0000-4000-8000-00000000000b P=44444444-0000-4000-8000-00000000000c
Q=33333333-0000-4000-8000-00000000000d S=22222222-0000-4000-8000-00000000000e
: > "$LEASE_DIR/take.log"
take $((now - 1000)) "$M" "$ID@$BOX" "I read your post now"
take $((now - 900)) "$P" "$ID@$BOX" "I check the status"
take $((now - 800)) "$Q" "$ID@$BOX" "I answer the comment"
take $((now - 700)) "$S" "$ID@$BOX" "I read the issue"
{ printf '%s\t%s\tc-002\tstatus comment, no agent reply\n' $((now - 1010)) "$M"
  printf '%s\t%s\tc-002\tan old ack\n' $((now - 1300)) "$P"
  printf '%s\t%s\tc-001\tno reply needed\n' $((now - 600)) "${Q:0:8}"; } > "$LEASE_DIR/unanswered.acks"
spl_rotate_handoff master "$ID" rid-6 "$T/handoff6.md" >/dev/null 2>&1 || true
sec="$(sed -n '/^## 10\. Open takes/,$p' "$T/handoff6.md" 2>/dev/null)"
! grep -q "$M" <<<"$sec" && pass "(i) an ack 10 s before the take drops it (a6d4d910)" || fail "(i) acked $M listed: $sec"
grep -q "^- topic $P, " <<<"$sec" && pass "(i) an ack 400 s before the take does not drop it" || fail "(i) want $P listed: $sec"
! grep -q "$Q" <<<"$sec" && pass "(i) an ack after the take (by topic prefix) drops it" || fail "(i) acked $Q listed: $sec"
grep -q "^- topic $S, " <<<"$sec" && pass "(i) a take with no ack stays listed" || fail "(i) want $S listed: $sec"
rm -f "$LEASE_DIR/unanswered.acks"

echo
(( fails == 0 )) && { echo "rotate-open-takes: all passed"; exit 0; }
echo "rotate-open-takes: $fails failed"; exit 1
