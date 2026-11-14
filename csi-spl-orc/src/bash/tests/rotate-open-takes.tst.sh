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
#
# Red control: ROTATE_LIB=<origin/master's spl-rotate-lib.func.sh> lists 0.
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

echo
(( fails == 0 )) && { echo "rotate-open-takes: all passed"; exit 0; }
echo "rotate-open-takes: $fails failed"; exit 1
