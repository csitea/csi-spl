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

# --- 6. _spl_desk_move_prep / _spl_desk_move_json (r02-01 one copy) -----------
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" SPL_HUB_URL="https://hub.test" bash -c '
  do_log(){ echo "$*"; }
  spl_desk_dir(){ echo "$T/state/dev/desk/$1/$2"; }
  spl_host_spool(){ echo "SPOOL-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_prep 1 t1 box-desk CLE-00 HUM-1 "message m1 to topic t2" || exit 1
  printf "DONE=%s DIR=%s\n" "$SPL_MOVE_DRY_DONE" "$SPL_MOVE_DIR"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"INFO DRY_RUN would: move message m1 to topic t2 as CLE-00 for HUM-1 on box-desk in t1 (https://hub.test)"* && "$out" == *"DONE=1 DIR="* && "$out" != *"there is no desk"* && "$out" != *"SPOOL-CALLED"* ]] \
  && pass "6. _spl_desk_move_prep dry run with existing desk sets SPL_MOVE_DRY_DONE=1 and skips spool" || fail "6. prep dry ok: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" SPL_HUB_URL="https://hub.test" bash -c '
  do_log(){ echo "$*"; }
  spl_desk_dir(){ echo "$T/no-desk"; }
  spl_host_spool(){ echo "SPOOL-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_prep 1 t1 box-desk CLE-00 "" "message m1 to topic t2" || exit 1
  printf "DONE=%s\n" "$SPL_MOVE_DRY_DONE"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"INFO DRY_RUN there is no desk for CLE-00 on box-desk in t1 yet ($T/no-desk)"* && "$out" == *"DONE=1"* ]] \
  && pass "6. _spl_desk_move_prep dry run notes missing desk" || fail "6. prep dry nodesk: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" SPL_HUB_URL="https://hub.test" bash -c '
  do_log(){ echo "$*"; }
  spl_desk_dir(){ echo "$T/no-desk"; }
  spl_host_spool(){ echo "SPOOL-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_prep 0 t1 box-desk CLE-00 "" "message m1 to topic t2"' 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL no desk for CLE-00 on box-desk in t1: run do_spl_desk_up first ($T/no-desk)"* && "$out" != *"SPOOL-CALLED"* ]] \
  && pass "6. _spl_desk_move_prep refuses missing desk on DRY_RUN=0 before host spool" || fail "6. prep nodesk: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" SPL_HUB_URL="https://hub.test" bash -c '
  do_log(){ echo "$*"; }
  spl_desk_dir(){ echo "$T/state/dev/desk/$1/$2"; }
  spl_host_spool(){ echo "SPOOL-CALLED"; }
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_prep 0 t1 box-desk CLE-00 "" "message m1 to topic t2" || exit 1
  printf "DONE=%s DIR=%s\n" "$SPL_MOVE_DRY_DONE" "$SPL_MOVE_DIR"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"SPOOL-CALLED"* && "$out" == *"DONE=0 DIR=$T/state/dev/desk/t1/box-desk"* ]] \
  && pass "6. _spl_desk_move_prep sets SPL_MOVE_DIR and calls spl_host_spool on DRY_RUN=0" || fail "6. prep live: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" ENV=dev PAYLOAD='{"ok":true}' bash -c '
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_json t1 box-desk CLE-00 to_task t2 "$PAYLOAD"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == '{"agent": "CLE-00", "box": "box-desk", "env": "dev", "move": {"ok": true}, "tenant": "t1", "to_task": "t2"}' ]] \
  && pass "6. _spl_desk_move_json embeds parsed JSON move payload" || fail "6. json obj: rc=$rc $out"
out=$(env PROJ_ROOT="$PROJ_ROOT" ENV=prd bash -c '
  source "$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
  _spl_desk_move_json t1 box-desk CLE-00 channel dev "plain-text"' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == '{"agent": "CLE-00", "box": "box-desk", "channel": "dev", "env": "prd", "move": "plain-text", "tenant": "t1"}' ]] \
  && pass "6. _spl_desk_move_json falls back to raw string when move output is non-JSON" || fail "6. json str: rc=$rc $out"
mm_f="$PROJ_ROOT/src/bash/run/spl-msg-move.func.sh"
[[ "$(grep -c "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to move." "$mm_f")" -eq 1 && "$(grep -c "EOF_PY" "$mm_f")" -eq 2 && "$(grep -c "_spl_desk_move_prep " "$mm_f")" -ge 1 && "$(grep -c "_spl_desk_move_json " "$mm_f")" -ge 1 ]] \
  && pass "6. one copy: spl-msg-move.func.sh defines and calls _spl_desk_move_prep and _spl_desk_move_json once" || fail "6. msg one copy"

echo "fails=$fails"
exit $(( fails > 0 ))
