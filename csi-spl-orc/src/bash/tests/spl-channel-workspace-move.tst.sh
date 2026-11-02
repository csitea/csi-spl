#!/usr/bin/env bash
#------------------------------------------------------------------------------
# do_spl_channel_workspace_move (spec 169 T9, cases C11, C12, C17), against a
# STUBBED hub endpoint (T7 is not built: CHANNEL_MOVE_HUB_CMD is the seam; the
# stub keeps the journal of section 8.3 in a JSON file):
#   1. bad input is refused before any hub call; no seam = FATAL naming T7
#   2. plan (the default) asks the hub for the plan only and changes nothing;
#      a seat with no <DST> desk makes it refuse, exit 3, naming it (C11)
#   3. run, DRY_RUN=1: reads the plan and the journal, prints the steps it
#      would run, makes no step call; DRY_RUN=0 without the owner's GO msg
#      id is refused, exit 3, before any hub call
#   4. run, DRY_RUN=0: P1 P2 P2b P3 P4 P5 P6 P7 in that order, the GO msg id
#      on every step; P2b probes each seat's <DST> desk; P5 rewrites the box
#      rule row and sends each lane one note old -> new key (C12)
#   5. C11: a failed P2b probe stops the move before P3/P4
#   6. C17: a crash in P5 -> the re-run resumes at P5 and finishes, no step
#      before it again, one note per lane in all; MOVE_FROM=P1 after P4
#      committed is refused, exit 3; a finished move re-run does nothing
#   7. copy: P1 P2 P3 P4 P7 only, no probe, no box step
#   8. MOVE_CMD=probe (P2b's send): the recipient must be an agent, never a
#      HUM-; DRY_RUN=1 checks only; DRY_RUN=0 sends agent -> agent through the
#      seat's <TO> desk on this machine, and a seat with no desk here fails;
#      on a box claimed by the <DST> workspace (spec 108) the desk cnf's guard
#      gets TENANT_ID=<DST> and the probe uses that workspace's desk
#   9. C24 (T9b, R4): plan prints the Cloud SQL backup retention and each log
#      bucket's retention, read as the pinned account (project and instance
#      from the real cnf, gcloud stubbed); a value it cannot read prints as
#      "not read: <reason>" and the plan keeps its exit code; run reads neither
#  10. C25, C26 (T9c, W2, F14): the box rule row's desk agent with no <DST> desk
#      on this box refuses plan and run, exit 3, naming it and the box; an
#      unreadable map or a malformed row refuses too. No row, no map, a row of
#      another env and a copy pass; plan says which box and file it read and
#      names the seats' other boxes; the rule file stays byte-equal
# Every hub op, probe and send is recorded (CONTROL: an absent call means
# "not made", not "not recorded").
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }

MOVE=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
GO=12345678-9abc-4def-8123-456789abcdef
DOC=11111111-2222-4333-8444-555555555555

cat >"$T/plan.json" <<'EOF'
{"counts":{"messages":42,"issues":2},"shared":[],"mentions":[],"missing_desks":[],
 "members_lost":[],"kept":[{"store":"daily DB dumps","gone_by":"2026-11-29"}],"refuse":[],
 "seats":[{"agent":"c-101","box":"box-desk"},{"agent":"c-102","box":"box-desk"}]}
EOF
printf '[{"agent":"c-201","topic":"dispatch-11112222","old_key":"SRC-7","new_key":"DST-1"}]\n' >"$T/lanes.json"
printf '{"settings":{"backupConfiguration":{"enabled":true,"transactionLogRetentionDays":6,"backupRetentionSettings":{"retainedBackups":7,"retentionUnit":"COUNT"}}}}\n' >"$T/sql.json"
printf '[{"name":"projects/p/locations/global/buckets/_Default","retentionDays":30},{"name":"projects/p/locations/global/buckets/_Required","retentionDays":400}]\n' >"$T/log.json"

# The hub stub: request JSON on stdin, answer JSON on stdout; a journal file.
cat >"$T/hub" <<'EOF'
#!/usr/bin/env bash
req="$(cat)"; op="$(jq -r .op <<<"$req")"; step="$(jq -r '.step // ""' <<<"$req")"
echo "hub $op${step:+ $step} go=$(jq -r '.go_msg_id // ""' <<<"$req")" >>"$STUB_LOG"
J="$STUB_DIR/journal.json"
mark() { jq --arg s "$1" '.steps[$s] = "done"' "$J" >"$J.n" && mv "$J.n" "$J"; }
case "$op" in
  plan) cat "$STUB_DIR/plan.json" ;;
  journal) if [ -f "$J" ]; then cat "$J"; else echo '{"move_id":null,"steps":{}}'; fi ;;
  step)
    [ "${STUB_FAIL_STEP:-}" = "$step" ] && { echo '{"error":"injected"}'; exit 1; }
    if [ "$step" = P1 ]; then
      jq -n --arg m "$STUB_MOVE" --slurpfile p "$STUB_DIR/plan.json" '{move_id:$m, steps:{}, seats:$p[0].seats, lanes:[]}' >"$J"
    fi
    [ "$step" = P4 ] && jq --slurpfile l "$STUB_DIR/lanes.json" '.lanes = $l[0]' "$J" >"$J.n" && mv "$J.n" "$J"
    mark "$step"
    if [ "$step" = P7 ]; then echo '{"ok":true,"proofs":[{"name":"messages","count":0},{"name":"channels","count":0}]}'
    else jq -c '{ok:true, move_id}' "$J"; fi ;;
  mark) mark "$step"; jq -c '{ok:true, move_id}' "$J" ;;
  *) echo '{"error":"unknown op"}'; exit 1 ;;
esac
EOF
cat >"$T/probe" <<'EOF'
#!/usr/bin/env bash
echo "probe $CMB_TENANT $CMB_AGENT $CMB_TO $CMB_TASK" >>"$STUB_LOG"
[ "${CMB_PROBE_FAIL:-}" = "$CMB_AGENT" ] && exit 4
h="$(printf '%s' "$CMB_AGENT" | md5sum)"
printf '{"msg_id":"%s-%s-4%s-8%s-%s"}\n' "${h:0:8}" "${h:8:4}" "${h:12:3}" "${h:15:3}" "${h:18:12}"
EOF
cat >"$T/send" <<'EOF'
#!/usr/bin/env bash
printf 'send' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[ -e "$STUB_DIR/send-fail" ] && { rm -f "$STUB_DIR/send-fail"; exit 1; }
exit 0
EOF
# gcloud: every call is recorded; never the real one, in any case of this file.
mkdir -p "$T/stub" "$T/home"
# c-101, the desk agent of reset_state's rule row, has its dst1 desk on this box
DESK="$T/home/.local/share/csi-spl/cloud/prd/desk/dst1/box-desk"
mkdir -p "$DESK/spool/c-101"
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_DIR/gcloud.log"
[ -n "${STUB_GCLOUD_HANG:-}" ] && exec sleep 30
case "$*" in
  "sql instances describe "*)
    [ -n "${STUB_SQL_DENY:-}" ] && { echo "WARNING: first line"; echo "ERROR: (gcloud.sql.instances.describe) HTTPError 403: not authorized"; } >&2 && exit 1
    echo "WARNING: a line on stderr must not break the JSON" >&2
    if [ -n "${STUB_SQL_JSON:-}" ]; then echo "$STUB_SQL_JSON"; else cat "$STUB_DIR/sql.json"; fi ;;
  "logging buckets list "*)
    [ -n "${STUB_LOG_DENY:-}" ] && { echo "ERROR: (gcloud.logging.buckets.list) PERMISSION_DENIED: logging.buckets.list" >&2; exit 1; }
    if [ -n "${STUB_LOG_JSON:-}" ]; then echo "$STUB_LOG_JSON"; else cat "$STUB_DIR/log.json"; fi ;;
  *) echo "ERROR: unexpected gcloud call" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/hub" "$T/probe" "$T/send" "$T/stub/gcloud"

reset_state() {
  rm -rf "$T/journal.json" "$T/state" "$T/spool"; mkdir -p "$T/spool"
  printf 'src1\tproj\t%s\tprd\tc-101\n' "$DOC" >"$T/spool/channel-rules.tsv"
}

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/gcloud.log"
  env PATH="$T/stub:$PATH" HOME="$T/home" APP_PATH="$(dirname "$PROJ_ROOT")" SPL_PRIVATE_WARN=0 \
    GCP_ACCOUNT=pinned@example.com SPOOL_TEST=1 SPOOL_ROOT="$T/spool" CHANNEL_MOVE_STATE="$T/state" SPOOL_CHANNEL_RULES_MAP="$T/spool/channel-rules.tsv" \
    CHANNEL_MOVE_HUB_CMD="$T/hub" CMB_PROBE_CMD="$T/probe" CMB_SEND_CMD="$T/send" \
    STUB_LOG="$T/calls.log" STUB_DIR="$T" STUB_MOVE="$MOVE" PROJ_PATH="$PROJ_ROOT" ENV=prd SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}
ops() { grep -oE '^hub (step|mark) P[0-9b]+' "$T/calls.log" | awk '{print $3}' | paste -sd' ' -; }

G=(CHANNEL=src1/proj TO=dst1)
R=(MOVE_CMD=run DRY_RUN=0 MOVE_GO_MSG="$GO" MOVE_CALLER=c-007@boxb AGENT_ID=c-001)

# --- 1. input -------------------------------------------------------------------------
reset_state
for bad in 'CHANNEL=proj' 'CHANNEL=SRC/proj' "CHANNEL=src1/proj' or '1" 'TO=src1' 'TO=' 'MOVE_MODE=swap' \
  'MOVE_CMD=apply' 'DRY_RUN=yes' 'ENV=stg' 'TO_NAME=Bad Name' 'MOVE_FROM=P9'; do
  in_orc do_spl_channel_workspace_move "${G[@]}" "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. $bad refused before any call" || fail "1. $bad: rc=$rc $(cat "$T/out")"
done
in_orc do_spl_channel_workspace_move "${G[@]}" CHANNEL_MOVE_HUB_CMD=; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'T7' "$T/out" && pass "1. no hub seam: FATAL naming the T7 endpoint" || fail "1. no seam: rc=$rc $(cat "$T/out")"

# --- 2. plan --------------------------------------------------------------------------
in_orc do_spl_channel_workspace_move "${G[@]}"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/calls.log")" == "hub plan go=" && ! -e "$T/journal.json" ]] && grep -q 'messages 42' "$T/out" \
  && grep -q 'daily DB dumps' "$T/out" && pass "2. plan: one read-only plan call, counts and the kept list" || fail "2. plan: rc=$rc $(cat "$T/out" "$T/calls.log")"
jq '.missing_desks = [{"agent":"c-102","box":"box-desk"}]' "$T/plan.json" >"$T/plan.miss"
cp "$T/plan.json" "$T/plan.ok"; cp "$T/plan.miss" "$T/plan.json"
in_orc do_spl_channel_workspace_move "${G[@]}"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'c-102' "$T/out" && pass "2. C11 a seat with no dst1 desk: plan refuses, exit 3, names it" || fail "2. C11 plan: rc=$rc $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}"; rc=$?
[[ $rc -eq 3 && -z "$(ops)" ]] && pass "2. C11 run with a missing desk: refused before P1, no step" || fail "2. C11 run: rc=$rc $(ops)"
cp "$T/plan.ok" "$T/plan.json"

# --- 3. dry run, GO -------------------------------------------------------------------
in_orc do_spl_channel_workspace_move "${G[@]}" MOVE_CMD=run; rc=$?
[[ $rc -eq 0 && -z "$(ops)" && ! -e "$T/journal.json" ]] && grep -q 'would run P1 P2 P2b P3 P4 P5 P6 P7' "$T/out" \
  && pass "3. run DRY_RUN=1: no step call, prints the steps" || fail "3. dry: rc=$rc $(cat "$T/out" "$T/calls.log")"
in_orc do_spl_channel_workspace_move "${G[@]}" MOVE_CMD=run DRY_RUN=0 MOVE_CALLER=c-007 AGENT_ID=c-001; rc=$?
[[ $rc -eq 3 && ! -s "$T/calls.log" ]] && grep -q 'MOVE_GO_MSG' "$T/out" && pass "3. DRY_RUN=0 without the owner's GO msg id: exit 3, no call" || fail "3. no GO: rc=$rc $(cat "$T/out")"

for who in HUM-10 '' 'c-007@Box B'; do
  in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}" "MOVE_CALLER=$who"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'MOVE_CALLER must be the dst1 orchestrator seat' "$T/out" \
    && pass "3. MOVE_CALLER='$who' refused before any call (an agent seat only)" || fail "3. caller '$who': rc=$rc $(cat "$T/out")"
done

# --- 4. the whole move ----------------------------------------------------------------
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}"; rc=$?
[[ $rc -eq 0 && "$(ops)" == "P1 P2 P2b P3 P4 P5 P6 P7" ]] && pass "4. P1..P7 in order" || fail "4. order: rc=$rc '$(ops)' $(cat "$T/out")"
n_step="$(grep -c '^hub step' "$T/calls.log")"
[[ "$n_step" -eq 6 && "$n_step" -eq "$(grep -c "^hub step P[0-9b]* go=$GO\$" "$T/calls.log")" ]] \
  && pass "4. the GO msg id rides on every step" || fail "4. go: $(cat "$T/calls.log")"
grep -qx "probe dst1 c-101 c-007@boxb $MOVE" "$T/calls.log" && grep -qx "probe dst1 c-102 c-007@boxb $MOVE" "$T/calls.log" \
  && pass "4. P2b probes each seat's dst1 desk on the move's task" || fail "4. probes: $(cat "$T/calls.log")"
grep -q "^dst1	proj	$DOC	" "$T/spool/channel-rules.tsv" && pass "4. P5 rewrote the box rule row to dst1" || fail "4. rule row: $(cat "$T/spool/channel-rules.tsv")"
[[ "$(grep -c '^send' "$T/calls.log")" -eq 1 ]] && grep -q 'SRC-7 -> DST-1' "$T/calls.log" \
  && pass "4. C12 the lane gets one note old -> new" || fail "4. notes: $(cat "$T/calls.log")"
grep -q 'proof messages 0' "$T/out" && pass "4. P7 prints the proofs" || fail "4. proofs: $(cat "$T/out")"

# --- 5. C11 a failed probe ------------------------------------------------------------
reset_state
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}" CMB_PROBE_FAIL=c-102; rc=$?
[[ $rc -ne 0 && "$(ops)" == "P1 P2" ]] && grep -q 'c-102' "$T/out" && grep -q "^src1	proj	" "$T/spool/channel-rules.tsv" \
  && pass "5. C11 a dead dst1 desk stops the move before P3/P4" || fail "5. C11: rc=$rc '$(ops)' $(cat "$T/out")"

# --- 6. C17 crash in P5, resume -------------------------------------------------------
reset_state; touch "$T/send-fail"
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}"; rc=$?
[[ $rc -ne 0 && "$(ops)" == "P1 P2 P2b P3 P4" ]] && jq -e '.steps.P4 == "done" and .steps.P5 == null' "$T/journal.json" >/dev/null \
  && pass "6. C17 a crash in P5: P4 committed, P5 not marked" || fail "6. crash: rc=$rc '$(ops)' $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}" MOVE_FROM=P1; rc=$?
[[ $rc -eq 3 && -z "$(ops)" ]] && grep -q 'P4' "$T/out" && pass "6. C17 MOVE_FROM=P1 after P4 committed: refused, exit 3" || fail "6. from P1: rc=$rc '$(ops)' $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" MOVE_CMD=run; rc=$?
[[ $rc -eq 0 ]] && grep -q 'would run P5 P6 P7' "$T/out" && pass "6. C17 a dry run shows the resume point P5" || fail "6. dry resume: $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}"; rc=$?
[[ $rc -eq 0 && "$(ops)" == "P5 P6 P7" ]] && ! grep -q '^probe' "$T/calls.log" \
  && pass "6. C17 the re-run resumes at P5 and finishes" || fail "6. resume: rc=$rc '$(ops)' $(cat "$T/out")"
[[ "$(grep -c '^send' "$T/calls.log")" -eq 1 ]] && grep -q "^dst1	proj	" "$T/spool/channel-rules.tsv" \
  && pass "6. C17 the resumed P5 sends the note once and the row is moved once" || fail "6. resume P5: $(cat "$T/calls.log")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}"; rc=$?
[[ $rc -eq 0 && -z "$(ops)" ]] && grep -q 'nothing to do' "$T/out" && pass "6. a finished move re-run does nothing" || fail "6. done: rc=$rc '$(ops)' $(cat "$T/out")"

# --- 7. copy --------------------------------------------------------------------------
reset_state
in_orc do_spl_channel_workspace_move "${G[@]}" "${R[@]}" MOVE_MODE=copy MOVE_CALLER= AGENT_ID=; rc=$?
[[ $rc -eq 0 && "$(ops)" == "P1 P2 P3 P4 P7" ]] && ! grep -qE '^(probe|send)' "$T/calls.log" && grep -q "^src1	proj	" "$T/spool/channel-rules.tsv" \
  && pass "7. copy: P1 P2 P3 P4 P7, no probe, no box step" || fail "7. copy: rc=$rc '$(ops)' $(cat "$T/out")"

# --- 8. MOVE_CMD=probe ----------------------------------------------------------------
PR=(MOVE_CMD=probe TO=dst1 PROBE_AGENT=c-101 PROBE_TO=c-007@boxb PROBE_MOVE="$MOVE")
# the desk stubs: cnf, the host spool and the desk's spool send are recorded
DESK_STUBS='do_spl_desk_cnf() { echo desk-cnf >>"$STUB_LOG"; SPL_STATE_DIR="$STUB_DIR/deskstate"; SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { echo host-spool >>"$STUB_LOG"; }
spl_desk_spool() { printf "desk-spool" >>"$STUB_LOG"; printf " [%s]" "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"; echo "{\"msg_id\":\"$STUB_MOVE\"}"; }'
in_orc "$DESK_STUBS; do_spl_channel_workspace_move" "${PR[@]}" PROBE_TO=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'PROBE_TO must be the dst1 orchestrator seat' "$T/out" \
  && pass "8. a HUM- recipient: refused before the desk is read" || fail "8. hum: rc=$rc $(cat "$T/out" "$T/calls.log")"
in_orc "$DESK_STUBS; do_spl_channel_workspace_move" "${PR[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would send the P2b probe c-101 -> c-007@boxb' "$T/out" \
  && pass "8. DRY_RUN=1: the argument check only, no desk call" || fail "8. dry: rc=$rc $(cat "$T/out")"
rm -rf "$T/deskstate"
in_orc "$DESK_STUBS; do_spl_channel_workspace_move" "${PR[@]}" DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no dst1 desk for c-101 on box-desk on this machine' "$T/out" && ! grep -q '^desk-spool' "$T/calls.log" \
  && pass "8. a seat with no dst1 desk on this machine: fails, nothing sent" || fail "8. no desk: rc=$rc $(cat "$T/out")"
mkdir -p "$T/deskstate/desk/dst1/box-desk/spool/c-101"
in_orc "$DESK_STUBS; do_spl_channel_workspace_move" "${PR[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^desk-spool \[$T/deskstate/desk/dst1/box-desk\] \[box-desk\] \[dst1\] \[https://hub.invalid\] \[--\] \[send\] \[--from\] \[c-101\] \[--to\] \[c-007\] \[--to-box\] \[boxb\] \[--task\] \[$MOVE\] \[--kind\] \[note\] \[--body\] \[Channel move $MOVE: desk probe of c-101 in dst1" "$T/calls.log" \
  && grep -q "\"msg_id\":\"$MOVE\"" "$T/out" \
  && pass "8. DRY_RUN=0: agent -> agent through the seat's dst1 desk, the body names the move and the seat" || fail "8. send: rc=$rc $(cat "$T/out" "$T/calls.log")"

# a box claimed by dst1: the real guard (spl_box_ws_guard) in the cnf stub
mkdir -p "$T/ws/dst1/state/prd/desk/dst1/box-desk/spool/c-101"; echo dst1 >"$T/ws/claim"
CLAIM_STUBS='do_spl_desk_cnf() { echo "desk-cnf tenant=${TENANT_ID:-}" >>"$STUB_LOG"; spl_box_ws_guard "${TENANT_ID:-}" || return 1; SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() { printf "desk-spool [%s]\n" "$1" >>"$STUB_LOG"; echo "{\"msg_id\":\"$STUB_MOVE\"}"; }'
in_orc "$CLAIM_STUBS; do_spl_channel_workspace_move" "${PR[@]}" DRY_RUN=0 SPL_WS_BASE="$T/ws"; rc=$?
[[ $rc -eq 0 ]] && grep -qx "desk-cnf tenant=dst1" "$T/calls.log" && grep -qx "desk-spool \[$T/ws/dst1/state/prd/desk/dst1/box-desk\]" "$T/calls.log" \
  && pass "8. a box claimed by dst1: the guard gets TENANT_ID=dst1, the probe uses the workspace's desk" || fail "8. claim: rc=$rc $(cat "$T/out" "$T/calls.log")"

# --- 9. C24 the plan prints the two retentions ----------------------------------------
reset_state
in_orc do_spl_channel_workspace_move "${G[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'PLAN retention Cloud SQL backups: 7 COUNT kept, point-in-time logs 6 days' "$T/out" \
  && pass "9. C24 plan prints the Cloud SQL backup retention" || fail "9. C24 sql: rc=$rc $(cat "$T/out" "$T/gcloud.log")"
grep -q 'PLAN retention log bucket _Default: 30 days' "$T/out" && grep -q 'PLAN retention log bucket _Required: 400 days' "$T/out" \
  && pass "9. C24 plan prints each log bucket's retention" || fail "9. C24 logs: $(cat "$T/out")"
[[ "$(wc -l <"$T/gcloud.log")" -eq 2 && "$(grep -c -- '--project=csi-spl-prd --account=pinned@example.com' "$T/gcloud.log")" -eq 2 ]] \
  && grep -q '^gcloud sql instances describe csi-spl-prd' "$T/gcloud.log" && grep -q '^gcloud logging buckets list ' "$T/gcloud.log" \
  && pass "9. C24 two reads only, project and instance from the cnf, the pinned account on each" || fail "9. C24 calls: $(cat "$T/gcloud.log")"
in_orc do_spl_channel_workspace_move "${G[@]}" STUB_SQL_DENY=1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'PLAN retention Cloud SQL backups: not read: ERROR: (gcloud.sql.instances.describe) HTTPError 403' "$T/out" \
  && grep -q 'log bucket _Default: 30 days' "$T/out" && grep -q 'OK plan of' "$T/out" \
  && pass "9. C24 Cloud SQL unreadable: not read with the reason, the plan finishes" || fail "9. C24 sql deny: rc=$rc $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" STUB_LOG_DENY=1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'PLAN retention log buckets: not read: ERROR: (gcloud.logging.buckets.list) PERMISSION_DENIED' "$T/out" \
  && grep -q 'Cloud SQL backups: 7 COUNT' "$T/out" && grep -q 'OK plan of' "$T/out" \
  && pass "9. C24 log buckets unreadable: not read with the reason, the plan finishes" || fail "9. C24 log deny: rc=$rc $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" GCP_ACCOUNT=; rc=$?
[[ $rc -eq 0 && ! -s "$T/gcloud.log" && "$(grep -c 'not read: .*no gcloud account' "$T/out")" -eq 2 ]] && grep -q 'OK plan of' "$T/out" \
  && pass "9. C24 no per-env key: both not read, no gcloud call, no owner fallback" || fail "9. C24 no key: rc=$rc $(cat "$T/out" "$T/gcloud.log")"
in_orc do_spl_channel_workspace_move "${G[@]}" 'STUB_SQL_JSON={"settings":{}}' 'STUB_LOG_JSON=[]'; rc=$?
[[ $rc -eq 0 ]] && grep -q 'Cloud SQL backups: not read: no backup retention in the answer' "$T/out" \
  && grep -q 'log buckets: not read: no bucket in the answer' "$T/out" \
  && pass "9. C24 an answer without the value: not read, nothing guessed" || fail "9. C24 empty: rc=$rc $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" 'STUB_SQL_JSON={"settings":{"backupConfiguration":{"enabled":false}}}'; rc=$?
[[ $rc -eq 0 ]] && grep -q 'PLAN retention Cloud SQL backups: automated backups off' "$T/out" \
  && pass "9. C24 backups off is said, not read as a retention" || fail "9. C24 off: rc=$rc $(cat "$T/out")"
s=$SECONDS
in_orc do_spl_channel_workspace_move "${G[@]}" STUB_GCLOUD_HANG=1 CWM_GCLOUD_TIMEOUT=1; rc=$?
[[ $rc -eq 0 && $((SECONDS - s)) -lt 25 && "$(grep -c 'not read: gcloud gave no answer in 1 s' "$T/out")" -eq 2 ]] \
  && pass "9. C24 a hung gcloud: not read after the timeout, the plan finishes" || fail "9. C24 hang: rc=$rc $((SECONDS - s)) s $(cat "$T/out")"
cp "$T/plan.miss" "$T/plan.json"
in_orc do_spl_channel_workspace_move "${G[@]}"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'Cloud SQL backups: 7 COUNT' "$T/out" && grep -q 'c-102' "$T/out" \
  && pass "9. C24 a refusing plan still prints them and exits 3" || fail "9. C24 refuse: rc=$rc $(cat "$T/out")"
cp "$T/plan.ok" "$T/plan.json"
in_orc do_spl_channel_workspace_move "${G[@]}" MOVE_CMD=run; rc=$?
[[ $rc -eq 0 && ! -s "$T/gcloud.log" ]] && pass "9. C24 run reads neither (plan only)" || fail "9. C24 run: rc=$rc $(cat "$T/gcloud.log")"

# --- 10. C25, C26 the box rule row ------------------------------------------------------
BX=boxa
Q=(SPOOL_DESK_BOX="$BX")
RULES="$T/spool/channel-rules.tsv"
reset_state; rm -rf "$DESK"; mkdir -p "${DESK%/*}/$BX/spool/c-101"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q "PLAN box rule: read $RULES on box $BX" "$T/out" && grep -q 'other boxes are not read' "$T/out" \
  && grep -q "PLAN box rule: src1/proj desk agent c-101 has its dst1 desk on box $BX" "$T/out" \
  && pass "10. C26 the desk is there: plan passes and says which box and file it read" || fail "10. C26 read: rc=$rc $(cat "$T/out")"
grep -q 'PLAN box rule: run this plan on box box-desk too' "$T/out" \
  && pass "10. C26 the hub's seats on another box are named" || fail "10. C26 other box: $(cat "$T/out")"
printf '# a comment\nsrc1\tother\t%s\tprd\tc-777\n' "$DOC" >>"$RULES"
before="$(sha256sum "$RULES")"; rm -rf "${DESK%/*}/$BX/spool/c-101"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}"; rc=$?
[[ $rc -eq 3 ]] && grep -q "REFUSE box rule: src1/proj desk agent c-101 has no dst1 desk on box $BX" "$T/out" && ! grep -q 'c-777' "$T/out" \
  && pass "10. C25 no dst1 desk: plan refuses, exit 3, names the agent and the box, only that channel's row" || fail "10. C25: rc=$rc $(cat "$T/out")"
[[ "$(sha256sum "$RULES")" == "$before" && -z "$(find "$T/spool" -maxdepth 1 -name 'channel-rules.tsv?*')" ]] \
  && pass "10. C26 read-only: the rule file is byte-equal, no lock or temp file beside it" || fail "10. C26 read-only: $(ls -a "$T/spool")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}" "${R[@]}"; rc=$?
[[ $rc -eq 3 && -z "$(ops)" ]] && grep -q 'REFUSE box rule' "$T/out" && pass "10. C25 run: refused before P1, no step" || fail "10. C25 run: rc=$rc '$(ops)' $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}" MOVE_CMD=run; rc=$?
[[ $rc -eq 3 ]] && grep -q 'REFUSE box rule' "$T/out" && ! grep -q 'PLAN box rule' "$T/out" && pass "10. C25 a dry run refuses too, without the plan's lines" || fail "10. C25 dry: rc=$rc $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}" MOVE_MODE=copy; rc=$?
[[ $rc -eq 0 ]] && grep -q 'PLAN box rule: not checked, a copy moves no seat' "$T/out" && pass "10. C26 copy: the same row does not refuse" || fail "10. C26 copy: rc=$rc $(cat "$T/out")"
mkdir -p "${DESK%/*}/$BX/spool/c-101"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}"; rc=$?
[[ $rc -eq 0 ]] && pass "10. C25 seating the desk clears it" || fail "10. C25 seated: rc=$rc $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}" DESK_BOX=boxb; rc=$?
[[ $rc -eq 3 ]] && grep -q 'has no dst1 desk on box boxa' "$T/out" && grep -q 'desk id boxb' "$T/out" && pass "10. C25 DESK_BOX picks the desk id looked at, and it is named" || fail "10. C25 DESK_BOX: rc=$rc $(cat "$T/out")"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}" DESK_BOX=box-wui; rc=$?
[[ $rc -eq 3 ]] && grep -q 'REFUSE box rule: src1/proj' "$T/out" && grep -q 'box-wui' "$T/out" && pass "10. C25 a bad DESK_BOX: refused, cannot tell" || fail "10. C25 bad box: rc=$rc $(cat "$T/out")"
rm -rf "${DESK%/*}/$BX/spool/c-101"
printf 'src1\tproj\t%s\tdev\tc-101\n' "$DOC" >"$RULES"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'PLAN box rule: src1/proj row is for env dev, not prd: not checked' "$T/out" && pass "10. C26 a row of another env is said, not checked" || fail "10. C26 env: rc=$rc $(cat "$T/out")"
printf 'src1\tother\t%s\tprd\tc-101\n' "$DOC" >"$RULES"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'PLAN box rule: no row for src1/proj on box boxa' "$T/out" && pass "10. C26 no row: no refusal, said" || fail "10. C26 no row: rc=$rc $(cat "$T/out")"
rm -f "$RULES"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'PLAN box rule: no row for src1/proj on box boxa' "$T/out" && [[ ! -e "$RULES" ]] && pass "10. C26 no map: no refusal, none created" || fail "10. C26 no map: rc=$rc $(cat "$T/out")"
printf 'src1\tproj\tnot-a-uuid\tprd\tc-101\n' >"$RULES"
in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'REFUSE box rule: src1/proj cannot tell' "$T/out" && grep -q 'not-a-uuid' "$T/out" && pass "10. C25 a malformed row refuses" || fail "10. C25 malformed: rc=$rc $(cat "$T/out")"
if [[ "$(id -u)" != 0 ]]; then
  printf 'src1\tproj\t%s\tprd\tc-101\n' "$DOC" >"$RULES"; chmod 000 "$RULES"
  in_orc do_spl_channel_workspace_move "${G[@]}" "${Q[@]}"; rc=$?
  chmod 644 "$RULES"
  [[ $rc -eq 3 ]] && grep -q "REFUSE box rule: src1/proj cannot tell: $RULES exists but cannot be read" "$T/out" && pass "10. C25 an unreadable map refuses: unread is not no row" || fail "10. C25 unreadable: rc=$rc $(cat "$T/out")"
fi

echo "spl-channel-workspace-move: $fails failure(s)"
[[ $fails -eq 0 ]]
