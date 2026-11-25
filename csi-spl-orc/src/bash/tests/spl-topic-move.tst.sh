#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_move (owner HUM-10, t1 b316397f) - move a topic to
#          another channel from a desk agent. No cloud call, no spool binary.
#   1. TOPIC_ID and CHANNEL fail fast when missing, before anything runs
#   2. a bad TOPIC_ID / CHANNEL / ACT_FOR / agent / tenant is refused, and
#      CONTROL: no refused run reached spool
#   3. the dry run says what it would do and sends nothing
#   4. DRY_RUN=0 runs `spool move --task --channel --as` (+ --acting-for),
#      drops a leading # and prints the hub's answer
#   5. the hub's not_allowed / not_found / unknown_channel refusals are named
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux

TOPIC=e2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f
cat >"$T/fakemove" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
[ -n "${FAKE_REFUSE:-}" ] && { echo "spool: hub refused: $FAKE_REFUSE (refused)" >&2; exit 78; }
echo '{"kind":"topic","msg_id":"0f8fad5b-d9cb-469f-a165-70867728950e","task_id":"e2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f","channel":"dev","from_channel":"general","moved":true,"moved_by":"CLE-00"}'
FAKE
chmod +x "$T/fakemove"; : >"$T/move.log"
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
MV='spl_host_spool() { SPL_SPOOL="$FAKE"; }; do_spl_topic_move'
run_mv() { SNIPPET="$MV" in_orc FAKE="$T/fakemove" FAKE_LOG="$T/move.log" TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BOX=box-desk "$@"; }

# --- 1. fail fast on a missing required var --------------------------------------
for miss in TOPIC_ID CHANNEL; do
  if [[ $miss == TOPIC_ID ]]; then out=$(run_mv CHANNEL=dev DRY_RUN=0 2>&1); else out=$(run_mv TOPIC_ID=$TOPIC DRY_RUN=0 2>&1); fi; rc=$?
  [[ $rc -ne 0 && "$out" == *"$miss must be set"* ]] && pass "a missing $miss fails fast" || fail "missing $miss (rc=$rc): $out"
done

# --- 2. bad values are refused -----------------------------------------------------
for bad in "TOPIC_ID=NOT-A-UUID" "TOPIC_ID=E2C3FBAD-C8DF-42D3-8233-2D7E8D5A0C2F" "CHANNEL=Dev" "CHANNEL=a b" "CHANNEL=#" \
           "ACT_FOR=CLE-01" "ACT_FOR=hum-1" "DESK_AGENT=box-desk" "TENANT_ID=T1"; do
  if run_mv TOPIC_ID=$TOPIC CHANNEL=dev DRY_RUN=0 "$bad" >"$T/o" 2>&1; then
    fail "do_spl_topic_move refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "do_spl_topic_move refuses $bad" || fail "do_spl_topic_move refuses $bad without saying why: $(cat "$T/o")"
  fi
done
[[ ! -s "$T/move.log" ]] && pass "CONTROL no refused move reached spool" || fail "a refused move ran spool: $(cat "$T/move.log")"

# --- 3. the dry run ------------------------------------------------------------------
out=$(run_mv TOPIC_ID=$TOPIC CHANNEL=dev 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *DRY_RUN*"move topic $TOPIC to #dev as CLE-00"* && ! -s "$T/move.log" ]] &&
  pass "the dry run says what it would do and sends nothing" || fail "dry run (rc=$rc): $out"

# --- 4. the real run -----------------------------------------------------------------
out=$(run_mv TOPIC_ID=$TOPIC CHANNEL='#dev' DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"moved_by": "CLE-00"'* && "$out" == *'"channel": "dev"'* ]] &&
  tail -1 "$T/move.log" | grep -x "move|--task|$TOPIC|--channel|dev|--as|CLE-00|" >/dev/null &&
  pass "runs spool move --task --channel --as, drops the #, prints the hub's answer" ||
  fail "move (rc=$rc): $out / $(tail -1 "$T/move.log")"
out=$(run_mv TOPIC_ID=$TOPIC CHANNEL=dev ACT_FOR=HUM-1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/move.log" | grep -x "move|--task|$TOPIC|--channel|dev|--as|CLE-00|--acting-for|HUM-1|" >/dev/null &&
  pass "ACT_FOR rides as --acting-for" || fail "acting-for (rc=$rc): $out / $(tail -1 "$T/move.log")"

# --- 5. the hub's refusals are named --------------------------------------------------
for tok in "not_allowed:only the agent that started it" "not_found:never delivered to the desk" "unknown_channel:is not a channel"; do
  out=$(run_mv FAKE_REFUSE="${tok%%:*}" TOPIC_ID=$TOPIC CHANNEL=dev DRY_RUN=0 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"${tok#*:}"* ]] && pass "a ${tok%%:*} refusal is named" || fail "${tok%%:*} refusal (rc=$rc): $out"
done

# --- 6. r02-01 one copy and standalone lazy-source -----------------------------
jline="$(run_mv TOPIC_ID=$TOPIC CHANNEL='#dev' DRY_RUN=0 2>&1 | grep '^{')"
python3 -c 'import json, sys; d = json.loads(sys.argv[1]); assert d.get("channel") == "dev" and "to_task" not in d' "$jline" \
  && pass "6. topic move emits top-level channel key (not to_task)" || fail "6. topic json key: $jline"
tm_f="$PROJ_ROOT/src/bash/run/spl-topic-move.func.sh"
own="$(grep -nE "OK DRY_RUN nothing was sent\. Re-run with DRY_RUN=0 to move\.|EOF_PY" "$tm_f" || true)"
[[ -z "$own" ]] && grep -q "_spl_desk_move_prep " "$tm_f" && grep -q "_spl_desk_move_json " "$tm_f" \
  && pass "6. one copy: spl-topic-move.func.sh delegates prep and JSON output to shared helpers" || fail "6. topic one copy: own=[$own]"
out=$(env PROJ_ROOT="$PROJ_ROOT" T="$T" ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BOX=box-desk TOPIC_ID="$TOPIC" CHANNEL=dev bash -c '
  set -uo pipefail; do_log(){ echo "$*"; }; do_require_bin(){ return 0; }
  do_spl_desk_cnf(){ SPL_HUB_URL="https://hub.test"; }; spl_dry_run(){ return 0; }
  spl_desk_box_default(){ echo box-desk; }; spl_desk_validate(){ return 0; }
  spl_desk_dir(){ echo "$T/state/dev/desk/$1/$2"; }
  source "$PROJ_ROOT/src/bash/run/spl-topic-move.func.sh"
  do_spl_topic_move' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"INFO DRY_RUN would: move topic $TOPIC to #dev as CLE-00 on box-desk in t1 (https://hub.test)"* && "$out" != *"command not found"* ]] \
  && pass "6. lazy load: spl-topic-move.func.sh loads _spl_desk_move_prep standalone" || fail "6. lazy topic: rc=$rc $out"

echo "fails=$fails"
exit $(( fails > 0 ))
