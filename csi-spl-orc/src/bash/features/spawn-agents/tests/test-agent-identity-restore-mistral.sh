#!/usr/bin/env bash
# test-agent-identity-restore-mistral.sh — a fresh m- lane has no session id
# yet; a reboot restore still brings it back: the plan hands restore-mistral.sh
# '-' (it continues the worktree's latest vibe session). Every other vendor
# keeps the rule: no session, no restore.
#
#   1. an m- record with no session plans RESTORE with session '-'
#   2. control: the same record as c- (claude) is still refused
#   3. an m- record WITH a session still plans that session, unchanged
#   4. an m- record with no session and a gone worktree is refused
#   5. DRY_RUN=0 starts restore-mistral.sh ID WORKTREE - for the fresh lane and
#      restore-mistral.sh ID WORKTREE SID for the one with a session
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_AGENT_ID MCP_BOT_AGENT_ID
H="$T_TMP/home"; W="$T_TMP/wt"; A="$T_TMP/adapters"
mkdir -p "$H/.claude/sessions" "$W" "$A" "$SPOOL_ROOT/agents" "$SPOOL_ROOT/dispatch"
export AI_TRANSCRIPT_HOME="$H" AI_OWNER_HOP=0 IDENTITY_RESTORE_ADAPTER_DIR="$A" IDENTITY_RESTORE_PAUSE=0 IDENTITY_RESTORE_SETTLE=0
export IDENTITY_RESTORE_SINCE=2026-10-01T03:00:00Z IDENTITY_RESTORE_WINDOW=15 IDENTITY_RESTORE_SESSION=t
. "$T_FEAT/lib/agent-identity.inc.sh"

# The fake adapter: restore-mistral.sh ID RUNDIR SID [BRIEF] records its arguments.
cat > "$A/restore-mistral.sh" <<EOS
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$1" "\$2" "\$3" >> "$T_TMP/started"
EOS
chmod +x "$A/restore-mistral.sh"

record() {  # ID KIND SID WORKTREE
  python3 - "$SPOOL_ROOT/agents/$1.json" "$@" <<'PY'
import json, sys
f, i, kind, sid, wt = sys.argv[1:6]
json.dump({"v": 1, "id": i, "kind": kind, "session_id": sid or None, "worktree": wt, "title": "lane " + i[-2:],
           "user": None, "pid": 4000000, "proc_start": "1", "tmux_session": "t", "window_id": "@9", "pane_id": "%9",
           "alive": True, "updated_at": "2026-10-01T02:00:00Z"}, open(f, "w"), indent=1, sort_keys=True)
PY
}

t_tmux
mkdir -p "$W/m-901" "$W/c-902" "$W/m-903"
record m-901 mistral ""    "$W/m-901"     # fresh m- lane: no session id yet
record c-902 claude  ""    "$W/c-902"     # control: the same, as claude
record m-903 mistral s-903 "$W/m-903"     # m- lane with a session
record m-904 mistral ""    "$W/gone"      # fresh m- lane, worktree gone

plan="$(ai_panes | ai_py restore-plan --since "$IDENTITY_RESTORE_SINCE" --agent-user "$(id -un)")"
has "1. m- with no session plans RESTORE with session '-'" "RESTORE	m-901	mistral	$(id -un)	-	$W/m-901	" "$plan"
has "2. control: c- with no session is still refused" "REFUSE	c-902	its session is unknown; not guessing one" "$plan"
has "3. m- with a session plans that session" "RESTORE	m-903	mistral	$(id -un)	s-903	$W/m-903	" "$plan"
has "4. m- with no session and a gone worktree is refused" "REFUSE	m-904	its worktree $W/gone is gone" "$plan"

act() {
  env PROJ_PATH="$T_REPO/csi-spl-orc" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-agent-identity-restore.func.sh"; do_spl_agent_identity_restore'
}
act DRY_RUN=0 >/dev/null
sleep 1
eq "5. restore-mistral.sh got '-' for the fresh lane and the session for the other" \
  "m-901|$W/m-901|- m-903|$W/m-903|s-903" "$(sort "$T_TMP/started" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

t_done
