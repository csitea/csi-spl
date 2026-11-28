#!/usr/bin/env bash
#------------------------------------------------------------------------------
# do_spl_channel_move_pickup (spec 169 T16, 8.5.5 items 2 and 3, case C34, the
# shell half) and the detail do_spl_channel_workspace_move sends, against a
# STUBBED hub (CHANNEL_MOVE_HUB_CMD; the stub keeps one journal in a JSON file
# and answers op open from it, a done journal not listed):
#   1. the orch lease: held on another box, or by nobody -> no hub call at all
#   2. DRY_RUN=1 (default): open and the journal are read, no step is sent
#   3. DRY_RUN=0: the open journal runs once, P2..P7, the journal's GO on every
#      step, P1's detail.inputs as the detail of P2 and P4 (with the caller),
#      MOVE_CALLER = the detail's caller, else the <DST> orchestrator seat on
#      this box; the lane notes come from the holder's id; a second pick-up
#      after the move is done sends nothing
#   4. a P1 done with no detail.inputs (R7 c-250 N4): not run, nothing sent as
#      {}, it says why; a P1 not done is not run
#   5. a refused step: the pick-up fails, the next one resumes at that step
#   6. one pick-up at a time: a held pickup.lock runs nothing
#   7. MOVE_DETAIL of do_spl_channel_workspace_move: not an object, or a caller
#      that is not MOVE_CALLER, is refused before any call; set, it rides on
#      plan, P1, P2 and P4 only
# RED CONTROL: drop _spl_cmp_holder_here from do_spl_channel_move_pickup -> 1
# runs the move on a box without the lease (two boxes pick up one move). On
# origin/master before T16 the action does not exist and every case fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
command -v flock >/dev/null || { echo "SKIP: no flock"; exit 0; }

MOVE=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
GO=12345678-9abc-4def-8123-456789abcdef
DOC=11111111-2222-4333-8444-555555555555
INPUTS='{"keep_emails":["kept@example.com"],"leave_hours":["HUM-12"]}'

cat >"$T/plan.json" <<'EOF'
{"counts":{"messages":4},"shared":[],"mentions":[],"missing_desks":[],"members_lost":[],"kept":[],"refuse":[],
 "shared_files":[],"seats":[{"agent":"c-101","box":"box-desk"}]}
EOF
printf '[{"agent":"c-201","topic":"dispatch-11112222","old_key":"SRC-7","new_key":"DST-1"}]\n' >"$T/lanes.json"

# The hub stub: one journal; op open lists it unless done. Every op is logged
# with its GO and its detail.
cat >"$T/hub" <<'EOF'
#!/usr/bin/env bash
req="$(cat)"; op="$(jq -r .op <<<"$req")"; step="$(jq -r '.step // ""' <<<"$req")"
echo "hub $op${step:+ $step} go=$(jq -r '.go_msg_id // ""' <<<"$req") detail=$(jq -c '.detail' <<<"$req")" >>"$STUB_LOG"
J="$STUB_DIR/journal.json"
mark() { jq --arg s "$1" '.steps[$s] = "done" | .done = (.steps.P7 == "done")' "$J" >"$J.n" && mv "$J.n" "$J"; }
case "$op" in
  open) jq -c --argjson in "$STUB_INPUTS" --arg p1 "${STUB_P1:-done}" \
          'if .done then {moves: []} else {moves: [{dst: "dst1", src: "src1", channel: "proj", move_id, go_msg_id: env.STUB_GO,
            steps: (.steps | .P1 = $p1), inputs: $in, orchestrators: ["c-007@boxb", "c-009@box-desk"]}]} end' "$J" ;;
  plan) cat "$STUB_DIR/plan.json" ;;
  journal) cat "$J" ;;
  step)
    [ "${STUB_FAIL_STEP:-}" = "$step" ] && { echo '{"error":"move_refused","detail":"injected"}'; exit 1; }
    [ "$step" = P4 ] && jq --slurpfile l "$STUB_DIR/lanes.json" '.lanes = $l[0]' "$J" >"$J.n" && mv "$J.n" "$J"
    mark "$step"
    if [ "$step" = P7 ]; then echo '{"ok":true,"proofs":[{"name":"messages","count":0}],"report":[],"kept":[]}'
    else jq -c '{ok:true, move_id}' "$J"; fi ;;
  mark) mark "$step"; jq -c '{ok:true, move_id}' "$J" ;;
  *) echo '{"error":"unknown op"}'; exit 1 ;;
esac
EOF
cat >"$T/probe" <<'EOF'
#!/usr/bin/env bash
echo "probe $CMB_TENANT $CMB_AGENT $CMB_TO $CMB_TASK" >>"$STUB_LOG"
printf '{"msg_id":"%s"}\n' "$CMB_TASK"
EOF
cat >"$T/send" <<'EOF'
#!/usr/bin/env bash
printf 'send' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
EOF
mkdir -p "$T/stub" "$T/home/.local/share/csi-spl/cloud/prd/desk/dst1/box-desk/spool/c-101"
printf '#!/usr/bin/env bash\necho "gcloud $*" >>"$STUB_DIR/gcloud.log"\nexit 9\n' >"$T/stub/gcloud"
chmod +x "$T/hub" "$T/probe" "$T/send" "$T/stub/gcloud"

reset_state() {
  rm -rf "$T/state" "$T/spool"; mkdir -p "$T/spool"
  printf 'src1\tproj\t%s\tprd\tc-101\n' "$DOC" >"$T/spool/channel-rules.tsv"
  jq -n --arg m "$MOVE" '{move_id: $m, done: false, steps: {P1: "done"}, seats: [{agent: "c-101", box: "box-desk"}], lanes: []}' >"$T/journal.json"
}

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"
  env PATH="$T/stub:$PATH" HOME="$T/home" APP_PATH="$(dirname "$PROJ_ROOT")" SPL_PRIVATE_WARN=0 \
    GCP_ACCOUNT=pinned@example.com SPOOL_TEST=1 SPOOL_ROOT="$T/spool" CHANNEL_MOVE_STATE="$T/state" SPOOL_CHANNEL_RULES_MAP="$T/spool/channel-rules.tsv" \
    CHANNEL_MOVE_HUB_CMD="$T/hub" CMB_PROBE_CMD="$T/probe" CMB_SEND_CMD="$T/send" CHANNEL_MOVE_PICKUP_HOLDER=c-001@box-desk \
    STUB_LOG="$T/calls.log" STUB_DIR="$T" STUB_GO="$GO" STUB_INPUTS="$INPUTS" PROJ_PATH="$PROJ_ROOT" ENV=prd SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}
ops() { grep -oE '^hub (step|mark) P[0-9b]+' "$T/calls.log" | awk '{print $3}' | paste -sd' ' -; }
detail_of() { sed -n "s/^hub step $1 go=[^ ]* detail=//p" "$T/calls.log"; }
WANT="$(jq -c '. + {caller: "c-009@box-desk"}' <<<"$INPUTS")"

# --- 1. the orch lease ----------------------------------------------------------------
reset_state
for h in c-001@boxb none@unreachable ''; do
  in_orc do_spl_channel_move_pickup DRY_RUN=0 "CHANNEL_MOVE_PICKUP_HOLDER=$h"; rc=$?
  [[ $rc -eq 0 && ! -s "$T/calls.log" ]] && pass "1. holder '$h': no hub call, nothing run" || fail "1. holder '$h': rc=$rc $(cat "$T/out" "$T/calls.log")"
done

# --- 2. dry run -----------------------------------------------------------------------
in_orc do_spl_channel_move_pickup; rc=$?
[[ $rc -eq 0 && -z "$(ops)" ]] && grep -q '^hub open' "$T/calls.log" && grep -q 'would run P2 P2b P3 P4 P5 P6 P7' "$T/out" \
  && pass "2. DRY_RUN=1: open and the journal read, the steps printed, none sent" || fail "2. dry: rc=$rc '$(ops)' $(cat "$T/out")"

# --- 3. the run -----------------------------------------------------------------------
in_orc do_spl_channel_move_pickup DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(ops)" == "P2 P2b P3 P4 P5 P6 P7" ]] && pass "3. the open journal runs P2..P7 once, in order" || fail "3. run: rc=$rc '$(ops)' $(cat "$T/out")"
n="$(grep -c '^hub step' "$T/calls.log")"
[[ "$n" -eq 5 && "$n" -eq "$(grep -c "^hub step P[0-9] go=$GO " "$T/calls.log")" ]] && pass "3. the journal's GO rides on every step" || fail "3. go: $(cat "$T/calls.log")"
[[ "$(detail_of P2)" == "$WANT" && "$(detail_of P4)" == "$WANT" ]] \
  && pass "3. P2 and P4 carry P1's detail.inputs with the caller" || fail "3. detail: P2 '$(detail_of P2)' P4 '$(detail_of P4)', want $WANT"
[[ "$(detail_of P3)" == null ]] && pass "3. P3 carries no detail" || fail "3. P3 detail: '$(detail_of P3)'"
grep -qx "probe dst1 c-101 c-009@box-desk $MOVE" "$T/calls.log" && pass "3. MOVE_CALLER is the <DST> orchestrator seat on this box" || fail "3. caller: $(grep probe "$T/calls.log")"
grep -q '^send .*\[--from\] \[c-001\]' "$T/calls.log" && pass "3. the lane note comes from the holder's id" || fail "3. note: $(grep send "$T/calls.log")"
in_orc do_spl_channel_move_pickup DRY_RUN=0; rc=$?
[[ $rc -eq 0 && -z "$(ops)" ]] && ! grep -q '^hub journal' "$T/calls.log" && pass "3. a done journal is not listed: the next pick-up sends nothing" || fail "3. again: rc=$rc '$(ops)' $(cat "$T/out")"
reset_state
in_orc do_spl_channel_move_pickup DRY_RUN=0 STUB_INPUTS='{"caller":"c-007@boxb"}'; rc=$?
[[ $rc -eq 0 ]] && grep -qx "probe dst1 c-101 c-007@boxb $MOVE" "$T/calls.log" && [[ "$(detail_of P2)" == '{"caller":"c-007@boxb"}' ]] \
  && pass "3. the detail's own caller wins over the roster" || fail "3. detail caller: rc=$rc $(cat "$T/calls.log")"

# --- 4. a P1 with no inputs, a P1 not done --------------------------------------------
reset_state
in_orc do_spl_channel_move_pickup DRY_RUN=0 STUB_INPUTS=null; rc=$?
[[ $rc -ne 0 && -z "$(ops)" ]] && ! grep -q '^hub journal' "$T/calls.log" && grep -q 'P1 kept no detail.inputs' "$T/out" && grep -q 'MOVE_FROM=P1 MOVE_DETAIL=' "$T/out" \
  && pass "4. N4: a P1 with no detail.inputs is not run, nothing sent as {}, it says how to clear it" || fail "4. no inputs: rc=$rc '$(ops)' $(cat "$T/out")"
in_orc do_spl_channel_move_pickup DRY_RUN=0 STUB_P1=started; rc=$?
[[ $rc -eq 0 && -z "$(ops)" ]] && grep -q 'P1 is not done' "$T/out" && pass "4. a P1 not done is not run" || fail "4. P1 started: rc=$rc '$(ops)' $(cat "$T/out")"

# --- 5. a refusal, then the resume -----------------------------------------------------
reset_state
in_orc do_spl_channel_move_pickup DRY_RUN=0 STUB_FAIL_STEP=P3; rc=$?
[[ $rc -ne 0 && "$(ops)" == "P2 P2b P3" ]] && grep -q 'injected' "$T/out" && grep -q 'the next pick-up resumes it' "$T/out" \
  && pass "5. a refused P3: the pick-up fails with the hub's reason" || fail "5. refused: rc=$rc '$(ops)' $(cat "$T/out")"
in_orc do_spl_channel_move_pickup DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(ops)" == "P3 P4 P5 P6 P7" ]] && pass "5. the next pick-up resumes at P3" || fail "5. resume: rc=$rc '$(ops)' $(cat "$T/out")"

# --- 6. one pick-up at a time ---------------------------------------------------------
reset_state; mkdir -p "$T/state"
exec 8>>"$T/state/pickup.lock"; flock -n 8 || fail "6. the test could not take the lock"
in_orc do_spl_channel_move_pickup DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'another pick-up runs' "$T/out" && pass "6. a held pickup.lock: nothing read, nothing run" || fail "6. lock: rc=$rc $(cat "$T/out" "$T/calls.log")"
exec 8>&-

# --- 7. MOVE_DETAIL of the move action ------------------------------------------------
G=(CHANNEL=src1/proj TO=dst1)
R=(MOVE_CMD=run DRY_RUN=0 MOVE_GO_MSG="$GO" MOVE_CALLER=c-007@boxb AGENT_ID=c-001)
for bad in 'MOVE_DETAIL=[1]' 'MOVE_DETAIL={no' 'MOVE_DETAIL={"caller":"c-008@boxb"}'; do
  reset_state
  in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}" "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'MOVE_DETAIL' "$T/out" && pass "7. $bad refused before any call" || fail "7. $bad: rc=$rc $(cat "$T/out")"
done
reset_state
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}" MOVE_CMD=plan "MOVE_DETAIL=$INPUTS"; rc=$?
[[ $rc -eq 0 ]] && grep -qxF "hub plan go=$GO detail=$(jq -c '. + {caller: "c-007@boxb"}' <<<"$INPUTS")" "$T/calls.log" \
  && pass "7. the plan carries MOVE_DETAIL with MOVE_CALLER as its caller" || fail "7. plan detail: rc=$rc $(cat "$T/calls.log" "$T/out")"
reset_state
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}" MOVE_CALLER= MOVE_MODE=copy; rc=$?
[[ "$(detail_of P2)" == null ]] && pass "7. neither set: the detail stays null, as before" || fail "7. null: rc=$rc '$(detail_of P2)' $(cat "$T/out")"

echo "spl-channel-move-pickup: $fails failure(s)"
[[ $fails -eq 0 ]]
