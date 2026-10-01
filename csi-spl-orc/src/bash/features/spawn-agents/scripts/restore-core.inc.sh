#!/usr/bin/env bash
# restore-core.inc.sh — the ONE resume launcher behind restore-claude.sh,
# restore-claude-plain.sh, restore-grok.sh, restore-agy.sh and restore-qwen.sh
# (ported from the frozen box engine, specs/048 SPL-1160).
#
# It RESUMES an interrupted agent session in a tmux window, in the directory it
# ran in: no new worktree, no fresh brief. Use it after the box or the tmux
# server restarted and the fleet died mid-flight. Like a spawn, the pane runs as
# the box user and the CLI as the agent user (spool_agent_exec), through
# spool-harness.sh, so the restored agent has its spool id and env again.
#
# An adapter declares, then calls restore_main "$@":
#   RESTORE_KIND        claude | grok | agy | qwen
#   RESTORE_ID_PREFIX   CLE | GRK | AGY | QWN (the <PREFIX>_TMUX_PANE it exports)
#   RESTORE_BIN_VAR     CLAUDE_BIN | GROK_BIN | AGY_BIN | QWEN_BIN
#   RESTORE_ARGS        a function: SESSION_ID -> the CLI args that resume it
#   RESTORE_KICK_FLAG   the flag before the kick prompt, or "" (positional)
#   RESTORE_KICK_MODE   brief (arg 4 is a brief file; the kick is composed:
#                       worker or neutral) | prompt (arg 4 is the kick itself)
#
# Usage (every adapter): restore-<kind>.sh <TITLE> <RUNDIR> <SESSION_ID> [BRIEF_FILE|KICK]
# RESTORE_PRINT=1 prints the command instead of running it.
set -uo pipefail
_RS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_RS_DIR/../lib/spool-env.inc.sh"
# shellcheck source=../lib/agent-state.inc.sh
. "$_RS_DIR/../lib/agent-state.inc.sh"

_rs_fail() { echo "ERROR: $*" >&2; [ "${RESTORE_PRINT:-0}" = 1 ] && exit 1; exec bash; }

# The kick for a claude restore with RESTORE_KICK_MODE=brief. Only an agent in
# its own lane worktree gets the integration steps; an orchestrator (xxx-00,
# ORC) or a session outside a lane worktree (not a git work tree, or a main
# checkout on its trunk) is told nothing about git - the worker kick would be
# destructive there.
_rs_kick() {  # TITLE RUNDIR BRANCH BRIEF
  local title="$1" rundir="$2" branch="$3" brief="$4" gd cd kind=worker clause=""
  [ -n "$brief" ] && [ -f "$brief" ] && clause="Re-read your task brief at ${brief} to reload the full scope. "
  if agent_is_orc "$title" || [ "${title#ORC}" != "$title" ]; then kind=neutral
  else
    gd="$(git -C "$rundir" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    cd="$(git -C "$rundir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -z "$gd" ]; then kind=neutral
    elif [ "$gd" = "$cd" ]; then case "$branch" in ""|HEAD|master|main) kind=neutral ;; esac
    fi
  fi
  if [ "$kind" = worker ]; then
    printf '%s' "SESSION RESTORED: this session was killed mid-flight when the box tmux server restarted, and has just been resumed in the same worktree (${rundir}, branch ${branch}). Before doing anything else, re-establish ground truth, because your last in-context belief about the tree may be one step ahead of what actually landed on disk: run git status and git log --oneline -12 here, and re-check any file you were in the middle of editing. ${clause}Then read your spool inbox (spool recv). Then state a 3-line status (what is committed, what is still open, next step) and continue the work from there, all the way through the integration and closing steps you were originally given: rebase onto the trunk, re-run the module tests, fast-forward push, leak-gate the commit identity, then tear down this worktree. Keep working autonomously; do not ask for confirmation to continue."
  else
    printf '%s' "SESSION RESTORED: this session was killed when the box tmux server restarted, and has just been resumed in ${rundir}. This is not an agent worktree, so this restore implies NO git step: no rebase, no push, no worktree teardown. Before acting, re-check the state you were working with (your spool inbox, anything you were waiting on, the files you last touched) because your last in-context belief may be ahead of what actually happened. State a 3-line status (what is done, what is open, what you are waiting for), then continue only what was already in progress."
  fi
}

restore_main() {
  local title="${1:-}" rundir="${2:-}" sid="${3:-}" arg4="${4:-}" bin_var bin branch kick="" kick_esc display cur args cmd stub pane sock
  SPOOL_ENV_NO_BINS=0 spool_env_resolve
  spool_valid_id "$title" 2>/dev/null || _rs_fail "TITLE '${title}' is not an agent id (e.g. ${RESTORE_ID_PREFIX}-07)"
  [ -n "$rundir" ] && [ -d "$rundir" ] || _rs_fail "RUNDIR '${rundir}' does not exist - the session cannot be restored in place; spawn it again"
  [ -n "$sid" ] || _rs_fail "a session id is required"
  bin_var="$RESTORE_BIN_VAR"; bin="${!bin_var:-$RESTORE_KIND}"
  branch="$(git -C "$rundir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  case "$RESTORE_KICK_MODE" in
    brief)  kick="$(_rs_kick "$title" "$rundir" "$branch" "$arg4")" ;;
    prompt) kick="$arg4" ;;
  esac
  display="$(an_decorate "$title")"

  # The restorer recreated the window under its SAVED name, which may predate
  # the box tag: give it the tag, keeping the title.
  pane="${TMUX_PANE:-}"; sock="${TMUX:-}"; sock="${sock%%,*}"
  if [ -n "$pane" ] && [ "${RESTORE_PRINT:-0}" != 1 ]; then
    cur="$(tmux -u list-panes -a -F '#{pane_id}	#{window_name}' 2>/dev/null | awk -F'\t' -v p="$pane" '$1 == p { sub(/^[^\t]*\t/, ""); print; exit }')"
    [ -n "$cur" ] && [ "$(an_decorate "$cur")" != "$cur" ] && tmux -u rename-window -t "$pane" "$(an_decorate "$cur")" 2>/dev/null
  fi

  args="$("$RESTORE_ARGS" "$sid")"
  [ "$RESTORE_KIND" = claude ] && args="--name '${display}' ${args}"
  cmd="export ${RESTORE_ID_PREFIX}_TMUX_PANE='${pane}' ${RESTORE_ID_PREFIX}_TMUX_SOCK='${sock}' SPOOL_ROOT='${SPOOL_ROOT}' SPOOL_AGENT_ID='${title}' MCP_BOT_AGENT_ID='${title}'; cd '${rundir}' && exec bash '${_RS_DIR}/spool-harness.sh' --as '${title}' --mirror -- '${bin}' ${args}"
  stub="$(spool_agent_cmd_text) -c 'cd \"${rundir}\" ; ${bin##*/} ${args}'"
  if [ -n "$kick" ]; then spool_dq_escape kick_esc "$kick"; fi
  if [ "${RESTORE_PRINT:-0}" = 1 ]; then
    printf '%s\n' "${cmd}${kick:+ ${RESTORE_KICK_FLAG:+${RESTORE_KICK_FLAG} }\"${kick_esc}\"}"
    return 0
  fi

  history -s "$stub" 2>/dev/null || true
  echo "════════════════════════════════════════════════════════════════════"
  echo " RESTORING ${title} (${RESTORE_KIND})"
  echo "   dir      : ${rundir}${branch:+ (branch ${branch})}"
  echo "   session  : ${sid}"
  echo "   re-resume: ${stub}"
  echo "════════════════════════════════════════════════════════════════════"
  # A kick re-orients the restored session and keeps the TUI up. If this CLI
  # build refuses the kick together with a resume, come back without it rather
  # than let the window die.
  if [ -n "$kick" ]; then
    spool_agent_exec "${cmd} ${RESTORE_KICK_FLAG:+${RESTORE_KICK_FLAG} }\"${kick_esc}\"" || spool_agent_exec "$cmd"
  else
    spool_agent_exec "$cmd"
  fi
  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo " Restored ${RESTORE_KIND} session '${title}' ended. Pane kept open so the"
  echo " window stays visible. Up-arrow recalls: ${stub}"
  echo "════════════════════════════════════════════════════════════════════"
  local hist="${HISTFILE:-$HOME/.bash_history}"
  [ -n "$hist" ] && printf '%s\n' "$stub" >>"$hist" 2>/dev/null
  exec bash
}
