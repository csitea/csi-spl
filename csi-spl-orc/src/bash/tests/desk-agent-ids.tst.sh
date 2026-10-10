#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the non-AI desks run on ids spool-env accepts (specs/061 follow-up).
# From the legacy cutoff (2026-10-03T20:59:59Z) on, RSP-01 and OPS-01 were
# refused, so every prd do_spl_desk_up_boxes and do_spl_responder_sweep tick
# failed and prd had no responder and no ops desk.
#   1. SPL_RSP_AGENT and SPL_OPS_AGENT (lib/bash/funcs/spl-desk-agents.func.sh)
#      are agent ids on a clock PAST the cutoff
#   2. every desk default reads them: the responder run and sweep, the ops
#      alarm cron, the weekly full scan. RED CONTROL: a default that is a
#      legacy id (RSP-01 before this change) is refused on that clock, and a
#      literal legacy default anywhere in the desk code fails the sweep
#   3. do_spl_desk_agent_rename: the dry run touches nothing; DRY_RUN=0 moves
#      spool/<old> to spool/<new> with an <old> link, keeps the inbox and the
#      mute, and writes ONE alias row per (old, box); a re-run is a no-op;
#      a held <new> is a FAIL and moves nothing; a <new> that is only an
#      empty SKELETON (what a seat of <new> lays down, n=6 on one prd box,
#      2026-10-09) is removed and the move goes on, the mute of <old> carrying
#   4. after the move, do_spl_desk_up_boxes seats the new id, never the link
#   5. the hub's copy, Go agentid.Responder (the rsp_count of the cross-box
#      Seen guard, c-082), equals SPL_RSP_AGENT
# No cloud call, no real spool root: everything under $T.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ORC="${DESK_IDS_ORC:-$PROJ_ROOT}"
IAC="${DESK_IDS_IAC:-$PROJ_ROOT/../csi-spl-iac}"
LIB="$ORC/lib/bash/funcs/spl-desk-agents.func.sh"
ENVINC="$PROJ_ROOT/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
PAST=2026-10-10T00:00:00Z

# id_ok <id>: 0 when spool-env takes it as an agent id past the cutoff.
# shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
id_ok() { ( export SPOOL_NOW="$PAST"; . "$ENVINC"; spl_is_agent_id "$1" ) 2>/dev/null; }

# --- 1. the two ids ------------------------------------------------------------------
if [[ -r "$LIB" ]]; then
  # shellcheck source=../../../lib/bash/funcs/spl-desk-agents.func.sh
  . "$LIB"
else
  SPL_RSP_AGENT="" SPL_OPS_AGENT=""
fi
id_ok "$SPL_RSP_AGENT" && pass "1. the responder's id ($SPL_RSP_AGENT) is an agent id past the cutoff" || fail "1. responder id '$SPL_RSP_AGENT' ($LIB)"
id_ok "$SPL_OPS_AGENT" && pass "1. the ops desk's id ($SPL_OPS_AGENT) is an agent id past the cutoff" || fail "1. ops id '$SPL_OPS_AGENT' ($LIB)"
[[ -n "$SPL_RSP_AGENT" && "$SPL_RSP_AGENT" != "$SPL_OPS_AGENT" ]] && pass "1. the two desks have two ids" || fail "1. one id for two desks"
! id_ok RSP-01 && ! id_ok OPS-01 && pass "1. CONTROL RSP-01 and OPS-01 are refused past the cutoff" || fail "1. CONTROL a legacy id passed"

# --- 2. every default site reads them ------------------------------------------------
# default <file> <ERE with one group>: the default value, expanded through the lib.
default() {
  local v
  v="$(sed -nE "s/.*$2.*/\\1/p" "$1")"; v="${v%%$'\n'*}"
  [[ -n "$v" ]] || return 1
  eval "printf '%s' \"$v\""
}
for site in \
  "$ORC/src/bash/run/spl-responder-run.func.sh|agent=\"\\\$\\{DESK_AGENT:-([^}]+)\\}\"|$SPL_RSP_AGENT" \
  "$ORC/src/bash/run/spl-responder-sweep.func.sh|agent=\"\\\$\\{DESK_AGENT:-([^}]+)\\}\"|$SPL_RSP_AGENT" \
  "$ORC/src/bash/scripts/spl-ops-alarm-cron.sh| AGENT=\"([^\"]+)\"|$SPL_OPS_AGENT" \
  "$IAC/src/bash/scripts/weekly-full-scan-cron.sh| AGENT=\"([^\"]+)\"|$SPL_OPS_AGENT"; do
  f="${site%%|*}"; rest="${site#*|}"; rx="${rest%|*}"; want="${rest##*|}"
  got="$(default "$f" "$rx")"
  if id_ok "$got" && [[ "$got" == "$want" ]]; then
    pass "2. ${f##*/} defaults to $got"
  else
    fail "2. ${f##*/} defaults to '$got' (want $want, an agent id past the cutoff)"
  fi
done
hits="$(grep -rnE '(DESK_AGENT:-|AGENT=")[A-Z]{2,4}-[0-9]+' "$ORC/src/bash/run" "$ORC/src/bash/scripts" "$IAC/src/bash/scripts" 2>/dev/null)"
[[ -z "$hits" ]] && pass "2. no desk default is a literal legacy id" || fail "2. legacy defaults: $hits"
out="$(bash "$ORC/src/bash/scripts/spl-ops-alarm-cron.sh" --print-crontab 2>&1)"
[[ "$out" == *"--agent $SPL_OPS_AGENT "* ]] && pass "2. the ops alarm crontab line names $SPL_OPS_AGENT" || fail "2. ops crontab: $out"

# --- 3. do_spl_desk_agent_rename --------------------------------------------------------
S="$T/state/prd"; R="$T/root"; mkdir -p "$R"
mkdir -p "$S/desk/t1/box-rsp/spool/RSP-01/inbox" "$S/desk/t1/box-ci/spool/OPS-01/inbox" \
  "$S/desk/csi-x/box-rsp/spool/RSP-01/inbox" "$S/desk/t1/box-desk/spool/c-010/inbox"
echo m1 >"$S/desk/t1/box-rsp/spool/RSP-01/inbox/m1.json"
touch "$S/desk/t1/box-rsp/spool/RSP-01/.no-poke"
ren() { SNIPPET='do_spl_desk_agent_rename' in_orc SPL_STATE_DIR="$S" SPOOL_ROOT="$R" ENV=prd "$@" 2>&1; }
out="$(ren)"; rc=$?
[[ $rc -eq 0 && "$out" == *"3 desk seat(s) of 4 desk(s) would move"* && "$out" == *"box-rsp of csi-x: spool/RSP-01 -> spool/$SPL_RSP_AGENT"* ]] &&
  pass "3. the dry run plans the three seats" || fail "3. dry run (rc=$rc): $out"
[[ -d "$S/desk/t1/box-rsp/spool/RSP-01" && ! -L "$S/desk/t1/box-rsp/spool/RSP-01" && ! -e "$R/agent-id-aliases.tsv" ]] &&
  pass "3. ...and moves nothing, writes no alias row" || fail "3. the dry run touched something"
out="$(ren DRY_RUN=0)"; rc=$?
d="$S/desk/t1/box-rsp/spool"
[[ $rc -eq 0 && -d "$d/$SPL_RSP_AGENT" && ! -L "$d/$SPL_RSP_AGENT" && "$(readlink "$d/RSP-01")" == "$SPL_RSP_AGENT" ]] &&
  pass "3. DRY_RUN=0 moves spool/RSP-01 to spool/$SPL_RSP_AGENT and leaves the link" || fail "3. apply (rc=$rc): $out"
[[ "$(cat "$d/$SPL_RSP_AGENT/inbox/m1.json" 2>/dev/null)" == m1 && -e "$d/$SPL_RSP_AGENT/.no-poke" ]] &&
  pass "3. ...the inbox and the mute move with it" || fail "3. inbox / mute lost"
[[ "$(readlink "$S/desk/t1/box-ci/spool/OPS-01")" == "$SPL_OPS_AGENT" && -d "$S/desk/t1/box-ci/spool/$SPL_OPS_AGENT" ]] &&
  pass "3. ...and OPS-01 on box-ci to $SPL_OPS_AGENT" || fail "3. box-ci: $out"
[[ -d "$S/desk/t1/box-desk/spool/c-010" && ! -e "$S/desk/t1/box-desk/spool/$SPL_RSP_AGENT" ]] &&
  pass "3. CONTROL a desk without a legacy seat is left alone" || fail "3. box-desk touched"
rows="$(awk -F'\t' '{ print $1, $2, $3, $4 }' "$R/agent-id-aliases.tsv" 2>/dev/null | sort | uniq -c | awk '{ $1 = $1; print }' | tr '\n' ';')"
[[ "$rows" == "1 OPS-01 $SPL_OPS_AGENT claude box-ci;1 RSP-01 $SPL_RSP_AGENT claude box-rsp;" ]] &&
  pass "3. one alias row per (old, box), though two tenants seat RSP-01 on box-rsp" || fail "3. alias rows: $rows"
out="$(ren DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *"0 desk seat(s)"* && "$out" == *"RSP-01 already moved to $SPL_RSP_AGENT"* ]] &&
  pass "3. a re-run moves nothing" || fail "3. re-run (rc=$rc): $out"
n1="$(wc -l <"$R/agent-id-aliases.tsv")"; ren DRY_RUN=0 >/dev/null
[[ "$(wc -l <"$R/agent-id-aliases.tsv")" == "$n1" ]] && pass "3. ...and adds no alias row" || fail "3. a re-run added alias rows"
mkdir -p "$S/desk/t2/box-rsp/spool/RSP-01/inbox" "$S/desk/t2/box-rsp/spool/$SPL_RSP_AGENT/inbox"
echo m2 >"$S/desk/t2/box-rsp/spool/$SPL_RSP_AGENT/inbox/m2.json"
out="$(ren DRY_RUN=0 TENANT_ID=t2)"; rc=$?
[[ $rc -ne 0 && "$out" == *"FAIL box-rsp of t2: "*"is held; RSP-01 was not moved"* && ! -L "$S/desk/t2/box-rsp/spool/RSP-01" &&
   -s "$S/desk/t2/box-rsp/spool/$SPL_RSP_AGENT/inbox/m2.json" ]] &&
  pass "3. a new id holding a message is a FAIL and moves nothing" || fail "3. held (rc=$rc): $out"
mkdir -p "$S/desk/t4/box-rsp/spool/RSP-01/inbox" "$T/elsewhere"; ln -s "$T/elsewhere" "$S/desk/t4/box-rsp/spool/$SPL_RSP_AGENT"
out="$(ren DRY_RUN=0 TENANT_ID=t4)"; rc=$?
[[ $rc -ne 0 && "$out" == *"is held; RSP-01 was not moved"* && -d "$T/elsewhere" && -L "$S/desk/t4/box-rsp/spool/$SPL_RSP_AGENT" ]] &&
  pass "3. ...and so is a new id that is a link" || fail "3. held link (rc=$rc): $out"
k="$S/desk/t3/box-rsp/spool"
mkdir -p "$k/RSP-01/inbox" "$k/RSP-01/outbox" "$k/$SPL_RSP_AGENT/inbox" "$k/$SPL_RSP_AGENT/outbox" "$k/$SPL_RSP_AGENT/archive"
echo h1 >"$k/RSP-01/outbox/h1.json"; touch "$k/$SPL_RSP_AGENT/.no-poke"
out="$(ren TENANT_ID=t3)"; rc=$?
[[ $rc -eq 0 && "$out" == *"would: box-rsp of t3: remove the empty skeleton spool/$SPL_RSP_AGENT"* && "$out" == *"1 desk seat(s) of 1 desk(s) would move"* &&
   -e "$k/$SPL_RSP_AGENT/.no-poke" && ! -L "$k/RSP-01" ]] &&
  pass "3. the dry run plans a move over an empty skeleton and touches nothing" || fail "3. skeleton dry run (rc=$rc): $out"
out="$(ren DRY_RUN=0 TENANT_ID=t3)"; rc=$?
[[ $rc -eq 0 && "$(cat "$k/$SPL_RSP_AGENT/outbox/h1.json" 2>/dev/null)" == h1 && "$(readlink "$k/RSP-01")" == "$SPL_RSP_AGENT" ]] &&
  pass "3. an empty skeleton at the new id is removed and RSP-01 moves in with its history" || fail "3. skeleton apply (rc=$rc): $out"
[[ ! -e "$k/$SPL_RSP_AGENT/.no-poke" ]] && pass "3. ...the mute state of RSP-01 (none) carries, not the skeleton's" || fail "3. the skeleton's .no-poke survived"
out="$(ren DESK_RENAME=RSP-01:CLE-9)"; rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL DESK_RENAME takes"* ]] && pass "3. a pair whose new id is not c-NNN is refused" || fail "3. bad pair (rc=$rc): $out"
out="$(ren DESK_RENAME=RSP-01:c-002)"; rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL DESK_RENAME takes"* ]] && pass "3. ...and a role number (001-003)" || fail "3. role pair (rc=$rc): $out"

# --- 4. the reconcile seats the new id ------------------------------------------------------
bash -c 'exit 0' & DEAD=$!; wait "$DEAD"
mkdir -p "$d/.hub"; echo "$DEAD" >"$d/.hub/hub-run.pid"
BSTUB='do_spl_desk_up() { echo "CALL up $TENANT_ID $DESK_BOX $DESK_AGENT"; }'
out="$(SNIPPET="$BSTUB; spl_desk_box_agents $S/desk/t1/box-rsp" in_orc 2>&1)"
[[ "$out" == "$SPL_RSP_AGENT" ]] && pass "4. spl_desk_box_agents lists $SPL_RSP_AGENT, not the RSP-01 link" || fail "4. box agents: $out"
out="$(SNIPPET="$BSTUB; do_spl_desk_up_boxes" in_orc SPL_STATE_DIR="$S" DESK_BOX=box-desk DRY_RUN=0 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"CALL up t1 box-rsp $SPL_RSP_AGENT"* && "$out" != *"RSP-01"* ]] &&
  pass "4. do_spl_desk_up_boxes re-seats the dead box-rsp sidecar as $SPL_RSP_AGENT" || fail "4. up_boxes (rc=$rc): $out"

# --- 5. the hub knows the same responder ------------------------------------------------
GO="$PROJ_ROOT/../csi-spl-api/src/go/spool-hub-api/internal/agentid/agentid.go"
goid="$(sed -nE 's/^const Responder = "([^"]+)"$/\1/p' "$GO" 2>/dev/null)"
[[ -n "$goid" && "$goid" == "$SPL_RSP_AGENT" ]] && pass "5. Go agentid.Responder ($goid) is SPL_RSP_AGENT" ||
  fail "5. Go agentid.Responder '$goid' != SPL_RSP_AGENT '$SPL_RSP_AGENT' ($GO)"

echo "desk-agent-ids: ${fails} failure(s)"
[ "$fails" -eq 0 ]
