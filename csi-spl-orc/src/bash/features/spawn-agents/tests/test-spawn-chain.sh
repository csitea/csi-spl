#!/usr/bin/env bash
# test-spawn-chain.sh — spawn-{claude,grok}-{chain,task}.sh (specs/048,
# SPL-1160), rendered with CHAIN_PRINT=1 so nothing is launched.
#
#   chain: one command per brief, in order, commit-but-never-push; claude
#   renames its session, grok exits after each brief. task: the id as the
#   name, commit AND push, a final report to the orchestrator; grok retitles
#   through riname and schedules its own window close. Refusals, and grok's
#   wait: a window whose pane runs a non-shell command is busy.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE
export CHAIN_PRINT=1 CLAUDE_BIN=claude GROK_BIN=grok SPOOL_ORCHESTRATOR_ID=CLE-01
s() { bash "$T_SCRIPTS/spawn-$1.sh" "${@:2}" 2>&1; }
D="$T_TMP/wd"; mkdir -p "$D"

out="$(s claude-chain - "$D" /b/one.md /b/two.md)"
eq "claude chain: one command per brief" 2 "$(printf '%s\n' "$out" | grep -c "^cd '$D' && 'claude'")"
has "claude chain: runs the first brief first" "(1/2) starting brief: /b/one.md" "$(printf '%s\n' "$out" | sed -n 1p)"
has "claude chain: named 'chain', auto permission mode" "'claude' --name 'chain' --permission-mode auto" "$out"
has "claude chain: renames its session" "/rename" "$out"
has "claude chain: commits, never pushes" "do NOT push" "$out"
out="$(s grok-chain - "$D" /b/one.md)"
has "grok chain: grok with both permission flags" "'grok' --dangerously-skip-permissions --permission-mode bypassPermissions" "$out"
has "grok chain: exits after the brief so the next can start" "EXIT so the next brief can start" "$out"
out="$(s claude-task CLE-07 "$D" /b/task.md)"
has "claude task: named after the id" "--name 'CLE-07'" "$out"
has "claude task: commits AND pushes" "commit AND push" "$out"
has "claude task: reports to the orchestrator over the spool" "final report to CLE-01 with $T_SCRIPTS/spool-send.sh" "$out"
out="$(s grok-task GRK-08 "$D" /b/task.md)"
has "grok task: retitles through riname --agent" "riname.sh --agent GRK-08" "$out"
has "grok task: schedules its own window close" "tmux-close-window.sh --defer --agent GRK-08" "$out"
s claude-task "bad id" "$D" /b/t.md >/dev/null; eq "a task refuses a non-id title (2)" 2 "$?"
s claude-chain - "$D" >/dev/null; eq "a chain refuses zero briefs (2)" 2 "$?"

t_tmux
t_window 'tbx: GRK-05 x' 'sleep 600' >/dev/null
t_window 'tbx: GRK-06 x' 'cat' >/dev/null
sleep 0.3
busy() { CHAIN_KIND=grok bash -c '. "$1/spawn-chain-core.inc.sh"; _ch_busy "$2"' _ "$T_SCRIPTS" "$1"; }
busy GRK-05; eq "grok wait: a pane back at sleep/shell is done" 1 "$?"
busy GRK-06; eq "grok wait: a pane running a command is busy" 0 "$?"
busy GRK-99; eq "grok wait: no such window is done" 1 "$?"
t_done
