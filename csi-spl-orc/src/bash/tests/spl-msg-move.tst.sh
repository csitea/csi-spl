#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_msg_move (SPL-1988, owner HUM-10, t1 69fd5022) - move one
#          message to another topic from a desk agent. No cloud call, no
#          spool binary.
#   1. MSG_ID and TO_TASK fail fast when missing, before anything runs
#   2. a bad MSG_ID / TO_TASK / ACT_FOR / agent / tenant is refused, and
#      CONTROL: no refused run reached spool
#   3. the dry run says what it would do and sends nothing
#   4. DRY_RUN=0 runs `spool move --msg --to-task --as` (+ --acting-for)
#      and prints the hub's answer
#   5. the hub's refusals are named
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux

MSG=0f8fad5b-d9cb-469f-a165-70867728950e
TASK=e2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f
cat >"$T/fakemove" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
[ -n "${FAKE_REFUSE:-}" ] && { echo "spool: hub refused: $FAKE_REFUSE (refused)" >&2; exit 78; }
echo '{"kind":"message","msg_id":"0f8fad5b-d9cb-469f-a165-70867728950e","task_id":"e2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f","from_task":"7c9e6679-7425-40de-944b-e07fc1f90ae7","channel":"dev","moved":true,"moved_by":"CLE-00"}'
FAKE
chmod +x "$T/fakemove"; : >"$T/move.log"
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
MV='spl_host_spool() { SPL_SPOOL="$FAKE"; }; do_spl_msg_move'
run_mv() { SNIPPET="$MV" in_orc FAKE="$T/fakemove" FAKE_LOG="$T/move.log" TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BOX=box-desk "$@"; }

# --- 1. fail fast on a missing required var --------------------------------------
for miss in MSG_ID TO_TASK; do
  if [[ $miss == MSG_ID ]]; then out=$(run_mv TO_TASK=$TASK DRY_RUN=0 2>&1); else out=$(run_mv MSG_ID=$MSG DRY_RUN=0 2>&1); fi; rc=$?
  [[ $rc -ne 0 && "$out" == *"$miss must be set"* ]] && pass "a missing $miss fails fast" || fail "missing $miss (rc=$rc): $out"
done

# --- 2. bad values are refused -----------------------------------------------------
for bad in "MSG_ID=NOT-A-UUID" "MSG_ID=0F8FAD5B-D9CB-469F-A165-70867728950E" "TO_TASK=nope" \
           "TO_TASK=E2C3FBAD-C8DF-42D3-8233-2D7E8D5A0C2F" "ACT_FOR=CLE-01" "ACT_FOR=hum-1" "DESK_AGENT=box-desk" "TENANT_ID=T1"; do
  if run_mv MSG_ID=$MSG TO_TASK=$TASK DRY_RUN=0 "$bad" >"$T/o" 2>&1; then
    fail "do_spl_msg_move refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "do_spl_msg_move refuses $bad" || fail "do_spl_msg_move refuses $bad without saying why: $(cat "$T/o")"
  fi
done
[[ ! -s "$T/move.log" ]] && pass "CONTROL no refused move reached spool" || fail "a refused move ran spool: $(cat "$T/move.log")"

# --- 3. the dry run ------------------------------------------------------------------
out=$(run_mv MSG_ID=$MSG TO_TASK=$TASK 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *DRY_RUN*"move message $MSG to topic $TASK as CLE-00"* && ! -s "$T/move.log" ]] &&
  pass "the dry run says what it would do and sends nothing" || fail "dry run (rc=$rc): $out"

# --- 4. the real run -----------------------------------------------------------------
out=$(run_mv MSG_ID=$MSG TO_TASK=$TASK DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"moved_by": "CLE-00"'* && "$out" == *"\"to_task\": \"$TASK\""* ]] &&
  tail -1 "$T/move.log" | grep -x "move|--msg|$MSG|--to-task|$TASK|--as|CLE-00|" >/dev/null &&
  pass "runs spool move --msg --to-task --as, prints the hub's answer" ||
  fail "move (rc=$rc): $out / $(tail -1 "$T/move.log")"
out=$(run_mv MSG_ID=$MSG TO_TASK=$TASK ACT_FOR=HUM-1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/move.log" | grep -x "move|--msg|$MSG|--to-task|$TASK|--as|CLE-00|--acting-for|HUM-1|" >/dev/null &&
  pass "ACT_FOR rides as --acting-for" || fail "acting-for (rc=$rc): $out / $(tail -1 "$T/move.log")"

# --- 5. the hub's refusals are named --------------------------------------------------
for tok in "not_allowed:moves only for a bound owner" "not_found:never delivered" "unknown_channel:may not post in" \
           "is_card:do_spl_topic_move instead" "bad_frame:predates the box message move"; do
  out=$(run_mv FAKE_REFUSE="${tok%%:*}" MSG_ID=$MSG TO_TASK=$TASK DRY_RUN=0 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"${tok#*:}"* ]] && pass "a ${tok%%:*} refusal is named" || fail "${tok%%:*} refusal (rc=$rc): $out"
done

echo "fails=$fails"
exit $(( fails > 0 ))
