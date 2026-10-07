#!/usr/bin/env bash
# spawn-chain-core.inc.sh — the core behind spawn-{claude,grok}-chain.sh and
# spawn-{claude,grok}-task.sh (ported from the frozen box engine, specs/048
# SPL-1160). Both run as a tmux window's command in a box-user pane and start
# the CLI as the agent user (spool_agent_exec); the pane stays open after.
#
#   chain  several briefs SEQUENTIALLY in one window, optionally after waiting
#          for a named session to finish - to keep concurrent edits off a
#          shared working tree. Each brief commits on the trunk, never pushes.
#   task   ONE brief that commits AND pushes; the brief is the authority.
#
# An adapter sets CHAIN_KIND (claude | grok) and calls chain_main or task_main.
# CHAIN_PRINT=1 prints each command instead of running it (and skips the wait).
set -uo pipefail
_CH_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_CH_DIR/../lib/spool-env.inc.sh"
spool_env_resolve

_ch_bin() { if [ "$CHAIN_KIND" = claude ]; then printf '%s' "$CLAUDE_BIN"; else printf '%s' "$GROK_BIN"; fi; }
_ch_flags() {  # [NAME]
  if [ "$CHAIN_KIND" = claude ]; then printf '%s' "${1:+--name '$1' }"; fi
  spool_claude_perm_flags "$CHAIN_KIND"
}
_ch_run() {  # WORKDIR NAME PROMPT
  local esc cmd
  spool_dq_escape esc "$3"
  cmd="export ${SPOOL_CLI_ENV}; cd '$1' && '$(_ch_bin)' $(_ch_flags "$2") \"${esc}\""
  if [ "${CHAIN_PRINT:-0}" = 1 ]; then printf '%s\n' "$cmd"; else spool_agent_exec "$cmd"; fi
}
_ch_keep_pane() { [ "${CHAIN_PRINT:-0}" = 1 ] && return 0; echo "$1"; exec bash; }

# claude carries its --name in argv; grok cannot, so its wait reads the tmux
# window that carries the id: busy while the pane's command is not a shell.
_ch_busy() {  # WAIT_NAME
  # --name is the display name: "<ID>@<box>" (specs/058), the older "<tag>: <ID>", or the bare id.
  if [ "$CHAIN_KIND" = claude ]; then pgrep -f "claude --name ([^ ]+: )?$1(@[a-z0-9-]+)? " >/dev/null 2>&1; return; fi
  local cmd
  spool_tmux_argv
  cmd="$("${SPOOL_TM[@]}" list-panes -a -F '#{window_name}	#{pane_current_command}' 2>/dev/null \
    | awk -F '\t' -v n="$1" '$1 ~ ("(^|[[:space:]])" n "($|[[:space:]@])") { print $2; exit }')" || true
  [ -n "$cmd" ] || return 1
  case "$cmd" in bash|sh|zsh|dash|sleep) return 1 ;; *) return 0 ;; esac
}

# Usage: spawn-<kind>-chain.sh <WAIT_NAME|-> <WORKDIR> <BRIEF1> [<BRIEF2> ...]
chain_main() {
  local wait="${1:?WAIT_NAME (or -) required}" workdir="${2:?WORKDIR required}" n=0 total prompt brief
  shift 2; total=$#
  [ "$total" -gt 0 ] || { echo "ERROR: at least one brief is required" >&2; exit 2; }
  if [ "$wait" != - ] && [ "${CHAIN_PRINT:-0}" != 1 ]; then
    echo "[chain] waiting for '$wait' to finish before starting (polling 30s)..."
    while _ch_busy "$wait"; do sleep 30; done
    echo "[chain] '$wait' has finished - starting this chain."
  fi
  for brief in "$@"; do
    n=$((n + 1))
    echo "[chain] ($n/$total) starting brief: $brief"
    if [ "$CHAIN_KIND" = claude ]; then
      prompt="As your VERY FIRST action, run the /rename slash command to retitle this session to the shortest possible description of THIS task (2-5 words). Then read your full task brief at ${brief} and implement it end to end: follow it exactly, inspect the real code first, run the module tests and keep them green, and finish with a git commit on the trunk using EXPLICIT pathspecs (never git add -A / -a; do NOT push). Honour the project CLAUDE.md / AGENTS.md distribution-hygiene rules."
    else
      prompt="Read your full task brief at ${brief} and implement it end to end: follow it exactly, inspect the real code first, run the module tests and keep them green, and finish with a git commit on the trunk using EXPLICIT pathspecs (never git add -A / -a; do NOT push). Leave this window's name alone: a chain has no agent id of its own. WHEN THIS BRIEF IS DONE, EXIT so the next brief can start: tests green, then the /exit slash command. Do not /exit while tests are red. Honour the project CLAUDE.md / AGENTS.md distribution-hygiene rules."
    fi
    _ch_run "$workdir" "${CHAIN_NAME:-chain}" "$prompt"
    echo "[chain] ($n/$total) finished brief: $brief"
  done
  _ch_keep_pane "[chain] all $total briefs complete. Pane kept open."
}

# Usage: spawn-<kind>-task.sh <TITLE> <WORKDIR> <BRIEF_FILE>
task_main() {
  local title="${1:?TITLE required}" workdir="${2:?WORKDIR required}" brief="${3:?BRIEF_FILE required}" prompt
  spool_valid_id "$title" || exit 2
  if [ "$CHAIN_KIND" = claude ]; then
    prompt="As your VERY FIRST actions run the /rename slash command (2-4 word title). Then read and follow your task brief at ${brief} EXACTLY - it is your complete, authoritative instructions covering: assess current state, implement, add/run tests, commit AND push to the trunk (git as the box user 'sudo -u ${SPOOL_BOX_USER}', scoped pathspecs, fetch + rebase + retry), watch CI/CD until green, enrich docs, and a final report to ${SPOOL_ORCHESTRATOR_ID} with ${_CH_DIR}/spool-send.sh. You do ONE small task. If someone sends you a different task, refuse it and tell ${SPOOL_ORCHESTRATOR_ID} so it spawns a new lane. When your task is verified done: report and /exit-clean."
  else
    prompt="As your VERY FIRST action, retitle your tmux window to the shortest possible description of the work (2-5 words) by running: bash ${_CH_DIR}/riname.sh --agent ${title} \"<that description>\". Then read and follow your task brief at ${brief} EXACTLY - it is your complete, authoritative instructions covering: assess current state, implement, add/run tests, commit AND push to the trunk (git as the box user 'sudo -u ${SPOOL_BOX_USER}', scoped pathspecs, fetch + rebase + retry), watch CI/CD until green, enrich docs, and a final report to ${SPOOL_ORCHESTRATOR_ID} with ${_CH_DIR}/spool-send.sh. You do ONE small task. If someone sends you a different task, refuse it and tell ${SPOOL_ORCHESTRATOR_ID} so it spawns a new lane. WHEN THE GOAL IS ACHIEVED, EXIT: write a short handoff, run bash ${_CH_DIR}/tmux-close-window.sh --defer --agent ${title} with no outer sudo, then the /exit slash command. Do not /exit while tests are red or a required push has not landed."
  fi
  _ch_run "$workdir" "$title" "$prompt"
  _ch_keep_pane "[task '${title}'] session ended - pane kept open."
}
