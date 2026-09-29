#!/usr/bin/env bash
# test-restore.sh — the five restore adapters (specs/048, SPL-1160), rendered
# with RESTORE_PRINT=1 so nothing is launched.
#
#   1. each kind resumes with its own flags, through spool-harness --as <ID>,
#      exporting its <PREFIX>_TMUX_PANE, SPOOL_ROOT and the agent id
#   2. claude's kick: a lane worktree gets the worker kick (closing steps), a
#      main checkout on its trunk, an orchestrator id and a non-git dir get the
#      neutral one (no git step); restore-claude-plain adds no kick
#   3. agy / qwen pass a kick after --prompt-interactive, grok positionally
#   4. refusals: a non-id title, a missing dir, no session id
#   5. agent-top counts a restored pane (restore-<kind>.sh <ID> in its argv) as
#      a live agent of that kind, not as ended
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE
export RESTORE_PRINT=1 CLAUDE_BIN=claude GROK_BIN=grok AGY_BIN=agy QWEN_BIN=qwen
r() { bash "$T_SCRIPTS/restore-$1.sh" "${@:2}" 2>&1; }
D="$T_TMP/plain"; mkdir -p "$D"

# --- 1 + 3 ---------------------------------------------------------------------
out="$(r grok GRK-07 "$D" s-1 'go on')"
has "1. grok resumes by session with both permission flags" "'grok' --dangerously-skip-permissions --permission-mode bypassPermissions --resume s-1" "$out"
has "1. through spool-harness --as the id" "spool-harness.sh' --as 'GRK-07' --" "$out"
has "1. exports its pane var, SPOOL_ROOT and the id" "export GRK_TMUX_PANE='' GRK_TMUX_SOCK='' SPOOL_ROOT='$SPOOL_ROOT' SPOOL_AGENT_ID='GRK-07'" "$out"
has "3. grok takes the kick positionally" 's-1 "go on"' "$out"
has "1+3. agy resumes by conversation, kick after --prompt-interactive" "'agy' --dangerously-skip-permissions --conversation c-2 --prompt-interactive \"hi\"" "$(r agy AGY-08 "$D" c-2 hi)"
has "1+3. qwen: --yolo --resume, kick after --prompt-interactive" "'qwen' --yolo --resume q-3 --prompt-interactive \"hi\"" "$(r qwen QWN-09 "$D" q-3 hi)"
hasnt "3. no kick given, none passed" "prompt-interactive" "$(r qwen QWN-09 "$D" q-3)"

# --- 2. claude kicks ------------------------------------------------------------------
git init -q --bare "$T_TMP/o.git"
git init -q "$T_TMP/main" && git -C "$T_TMP/main" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/main" branch -M master
git -C "$T_TMP/main" worktree add -q -b CLE-10-x "$T_TMP/wt" master
echo brief >"$T_TMP/brief.md"
out="$(r claude CLE-10 "$T_TMP/wt" sid-a "$T_TMP/brief.md")"
has "2. claude resumes by session, named after the id" "'claude' --name 'CLE-10' --resume sid-a --permission-mode auto" "$out"
has "2. a lane worktree gets the worker kick" "tear down this worktree" "$out"
has "2. ... re-pointing at the brief" "Re-read your task brief at $T_TMP/brief.md" "$out"
has "2. a main checkout on master gets the neutral kick" "implies NO git step" "$(r claude CLE-11 "$T_TMP/main" sid-b)"
has "2. an orchestrator id gets the neutral kick" "implies NO git step" "$(r claude CLE-00 "$T_TMP/wt" sid-c)"
has "2. a non-git dir gets the neutral kick" "implies NO git step" "$(r claude CLE-12 "$D" sid-d)"
out="$(r claude-plain CLE-13 "$D" sid-e)"
hasnt "2. restore-claude-plain adds no kick" "SESSION RESTORED" "$out"
has "2. ... and still resumes the session" "--resume sid-e" "$out"
SPOOL_BOX_TAG=tbx has "2. the claude session name carries the box tag" "--name 'tbx: CLE-13'" "$(SPOOL_BOX_TAG=tbx r claude-plain CLE-13 "$D" sid-e)"

# --- 4. refusals --------------------------------------------------------------------------
r grok "not an id" "$D" s >/dev/null; eq "4. a non-id title is refused" 1 "$?"
r grok GRK-07 "$T_TMP/nope" s >/dev/null; eq "4. a missing dir is refused" 1 "$?"
r grok GRK-07 "$D" >/dev/null; eq "4. no session id is refused" 1 "$?"

# --- 5. agent-top sees a restored agent ---------------------------------------------------------
t_tmux
t_window 'tbx: CLE-14 restored' "bash -c \"printf '%s\\\\n' 'esc to interrupt'; exec -a 'restore-claude.sh CLE-14' sleep 600\"" >/dev/null
sleep 0.4
row="$(XDG_CONFIG_HOME="$T_TMP/cfg" bash "$T_SCRIPTS/agent-top.sh" | awk '$1=="CLE-14"{print $2, $3}')"
eq "5. agent-top reads a restored pane as a live claude agent" "claude busy" "$row"
# a session restorer that runs no restore-*.sh: the id the run-as hop exports
t_window 'tbx: CLE-15 other' "bash -c \"printf '%s\\\\n' 'esc to interrupt'; exec -a 'su - agent -c export MCP_BOT_AGENT_ID=\\\"CLE-15\\\"; exec /opt/x/bin/claude --resume s' sleep 600\"" >/dev/null
sleep 0.4
row="$(XDG_CONFIG_HOME="$T_TMP/cfg" bash "$T_SCRIPTS/agent-top.sh" | awk '$1=="CLE-15"{print $2, $3}')"
eq "5. ... and one whose hop exports MCP_BOT_AGENT_ID, kind from the CLI binary" "claude busy" "$row"
t_done
