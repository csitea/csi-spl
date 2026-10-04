#!/usr/bin/env bash
# Only a role seat (c-001, c-002, c-003) or a shell with no agent id may
# spawn. A lane is exit 9, one line naming it. SPAWN_ALLOW_LANE=1 needs a
# reason and is logged. The registry row's last column is the requester;
# retiring that row keeps retired-utc in column 6.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_tmux
SW="$T_SCRIPTS/spawn-window.sh"
RET="$T_SCRIPTS/agent-id-retire.sh"
WD="$T_TMP/plain"
mkdir -p "$WD"
export SPOOL_BIN=/opt/x/spool

# A dry-run spawn. Extra env is the caller's. stdout in $OUT, stderr in
# $T_TMP/err, status in $RC.
run() {  # [env assignments via the caller] KIND TITLE
  OUT="$(SPAWN_DRY_RUN=1 bash "$SW" "$@" 2>"$T_TMP/err")"; RC=$?
}

# --- a lane is refused -------------------------------------------------------
SPOOL_AGENT_ID=g-213 run grok g-214 "$WD"
eq "a lane is exit 9" 9 "$RC"
eq "the refusal is one line" 1 "$(grep -c . "$T_TMP/err")"
has "the line names the requester" "requester g-213 is a lane" "$(cat "$T_TMP/err")"
check "nothing was claimed" test ! -e "$SPOOL_ROOT/g-214"
hasnt "the plan never starts" "PLAN claim" "$OUT"

SPOOL_AGENT_ID=c-004 run claude c-050 "$WD"
eq "c-004 is a lane, not a seat" 9 "$RC"
has "it names c-004" "requester c-004 is a lane" "$(cat "$T_TMP/err")"

MCP_BOT_AGENT_ID=g-216 run grok g-217 "$WD"
eq "MCP_BOT_AGENT_ID is the requester when SPOOL_AGENT_ID is unset" 9 "$RC"
has "it names g-216" "requester g-216" "$(cat "$T_TMP/err")"
unset MCP_BOT_AGENT_ID

# --- seats and a human shell are allowed -------------------------------------
for seat in c-001 c-002 c-003; do
  SPOOL_AGENT_ID="$seat" run claude c-060 "$WD"
  eq "$seat is allowed" 0 "$RC"
  has "$seat is the requester in the registry plan" "requester=$seat" "$OUT"
done
SPOOL_AGENT_ID=c-001@sat run claude c-061 "$WD"
eq "a seat on another box is the bare id" 0 "$RC"
has "the @box is not part of the requester" "requester=c-001" "$OUT"
unset SPOOL_AGENT_ID

env -u SPOOL_AGENT_ID -u MCP_BOT_AGENT_ID -u SPAWN_REQUESTER SPAWN_DRY_RUN=1 \
  bash "$SW" claude c-062 "$WD" >"$T_TMP/human" 2>"$T_TMP/err"; RC=$?
eq "a shell with no agent id is allowed" 0 "$RC"
has "the requester column is -" "requester=-" "$(cat "$T_TMP/human")"

# --- the calling pane: window name, then the registry row --------------------
P="$(t_window 'g-220 lane' 'sleep 600')"
TMUX_PANE="$P" run grok g-223 "$WD"
eq "the window name of TMUX_PANE is the requester" 9 "$RC"
has "it names g-220" "requester g-220" "$(cat "$T_TMP/err")"
unset TMUX_PANE

P="$(t_window scratch 'sleep 600')"
printf 'c-001\tclaude\t%s\t/old\t20260101T000000Z\ng-221\tgrok\t%s\t/x\t20260101T000001Z\n' "$P" "$P" >"$SPOOL_ROOT/registry.tsv"
TMUX_PANE="$P" run grok g-224 "$WD"
eq "the newest registry row of the pane wins" 9 "$RC"
has "it names g-221, not the older seat row" "requester g-221" "$(cat "$T_TMP/err")"
unset TMUX_PANE

P="$(t_window 'c-002@sat dispatch' 'sleep 600')"
TMUX_PANE="$P" run claude c-063 "$WD"
eq "a seat named by the pane is allowed" 0 "$RC"
has "the requester is c-002" "requester=c-002" "$OUT"
unset TMUX_PANE

# --- sudo strips the env; the parent process still carries the id -----------
# The id-bearing shell must not be the one bash replaces. A bash -c whose
# last command is the spawn is exec'd away, and the walk then reads the
# outer sudo, which still has this agent's id.
SPOOL_AGENT_ID=g-213 bash -c '
  env -u SPOOL_AGENT_ID -u MCP_BOT_AGENT_ID -u TMUX_PANE -u SPAWN_REQUESTER \
    SPAWN_TEST_SANDBOX=0 SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool \
    bash "$1" grok g-218 "$2"
  rc=$?
  exit "$rc"
' _ "$SW" "$WD" >"$T_TMP/walk" 2>"$T_TMP/err"; RC=$?
eq "a stripped child is still the lane in its parent" 9 "$RC"
has "the walk names g-213" "requester g-213" "$(cat "$T_TMP/err")"

# --- the override ------------------------------------------------------------
SPAWN_ALLOW_LANE=1 SPOOL_AGENT_ID=g-213 run grok g-219 "$WD"
eq "the override without a reason is still a refusal" 9 "$RC"
has "it asks for SPAWN_ALLOW_REASON" "SPAWN_ALLOW_REASON" "$(cat "$T_TMP/err")"
check "nothing was logged" test ! -e "$SPOOL_ROOT/spawn-allow.log"

SPAWN_ALLOW_LANE=1 SPAWN_ALLOW_REASON="$(printf 'split the fix\tnow')" SPOOL_AGENT_ID=g-213 \
  run grok g-219 "$WD"
eq "the override with a reason is allowed" 0 "$RC"
has "stderr names the lane and the reason" "ALLOW requester g-213 (SPAWN_ALLOW_LANE=1): split the fix now" "$(cat "$T_TMP/err")"
has "the registry plan carries the lane" "requester=g-213" "$OUT"
has "the log carries the lane and the reason" "g-213	split the fix now" "$(cat "$SPOOL_ROOT/spawn-allow.log")"
unset SPAWN_ALLOW_LANE SPAWN_ALLOW_REASON

# --- the row, and a reader that keeps column 6 as the retire timestamp -------
# shellcheck source=../scripts/spawn-core.inc.sh
. "$T_SCRIPTS/spawn-core.inc.sh"
line="$(spawn_registry_line c-030 claude %9 /x 20261002T080000Z c-001)"
eq "the row is six columns, requester last" "c-030	claude	%9	/x	20261002T080000Z	c-001" "$line"
printf '%s\n' "$line" >"$SPOOL_ROOT/registry.tsv"
bash "$RET" --apply c-030 >"$T_TMP/ret" 2>&1; eq "retire of a six-column row exits 0" 0 "$?"
eq "retired-utc stays column 6" "20261002T120000Z" "$(awk -F'\t' '{ print $6 }' "$SPOOL_ROOT/registry.retired.tsv")"
eq "the requester is kept after it" "c-001" "$(awk -F'\t' '{ print $7 }' "$SPOOL_ROOT/registry.retired.tsv")"
eq "the quarantine still reads column 6" "c-030" "$(awk -F'\t' -v from=20261002T000000Z '$6 >= from { print $1 }' "$SPOOL_ROOT/registry.retired.tsv")"

# --- a direct launcher call gates too ----------------------------------------
out="$(SPAWN_DRY_RUN=1 SPOOL_AGENT_ID=g-010 bash "$T_SCRIPTS/spawn-grok.sh" g-011 "$WD" 2>"$T_TMP/err")"; RC=$?
eq "spawn-grok.sh refuses a lane before a spool dir" 9 "$RC"
has "it names g-010" "requester g-010" "$(cat "$T_TMP/err")"
check "no spool dir" test ! -e "$SPOOL_ROOT/g-011"
hasnt "no plan" "PLAN spooldir" "$out"

t_done
