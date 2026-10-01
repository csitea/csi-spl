#!/bin/bash
#------------------------------------------------------------------------------
# @description Install what keeps the identity map and the window names in
# @description step, so no step lives in anyone's memory:
# @description   1. a per-minute cron line (tag csi-spl:agent-identity-reconcile,
# @description      matched only as the whole END of a line) in the
# @description      running user's crontab: reconcile --apply
# @description   2. tmux hooks on the box's server: after-new-window[1] and
# @description      pane-exited[1] run a delayed reconcile (index 1: the
# @description      window sorter keeps index 0). tmux-agent-status.conf
# @description      carries the same lines, so re-sourcing it keeps them.
# @description Idempotent: a part already in place is reported OK and left.
# @description Dry run unless DRY_RUN=0. IDENTITY_UNINSTALL=1 removes both
# @description parts instead (the rollback).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param IDENTITY_UNINSTALL (optional) - 1 removes the cron line and the hooks
# @param SPOOL_TMUX_SOCKET (optional) - the box's tmux server
# @param IDENTITY_ALLOW_WORKTREE (optional) - 1 allows DRY_RUN=0 from a linked worktree (tests only)
# @example ./run -a do_spl_agent_identity_install
# @example DRY_RUN=0 ./run -a do_spl_agent_identity_install
# @example DRY_RUN=0 IDENTITY_UNINSTALL=1 ./run -a do_spl_agent_identity_install
#------------------------------------------------------------------------------
do_spl_agent_identity_install() {
  local dry="${DRY_RUN:-1}" un="${IDENTITY_UNINSTALL:-0}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" || return 1
  local script="$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-identity-reconcile.sh"
  local log="${SPOOL_ROOT:-/var/spool-hub}/agents/reconcile.log"
  local want="* * * * * bash $script --apply >> $log 2>&1 # $AI_CRON_TAG"
  local ct="${IDENTITY_CRONTAB:-crontab}" before after hook h cmd rc=0 gd cd
  # The cron line and the hooks name THIS checkout's script: from a linked
  # worktree (torn down when its lane closes) they would point at nothing.
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ -n "$gd" && "$gd" != "$cd" && "${IDENTITY_ALLOW_WORKTREE:-0}" != 1 ]]; then
    if [[ "$dry" == 0 && "$un" != 1 ]]; then
      do_log "FATAL $PROJ_PATH is a linked worktree: run the install from the main checkout - nothing changed"; return 1
    fi
    echo "WARN $PROJ_PATH is a linked worktree: the paths below would vanish with it; install from the main checkout"
  fi
  before="$(mktemp)"; after="$(mktemp)"
  $ct -l 2>/dev/null >"$before"
  # A line whose tag only STARTS with ours is someone else's job that an
  # anchored match would still spare - but it makes the tag ambiguous to a
  # human and to any looser tool. Refuse rather than guess.
  if grep -F "# $AI_CRON_TAG" "$before" | ai_cron_without /dev/stdin | grep -q .; then
    do_log "FATAL the crontab has a line whose tag starts with '# $AI_CRON_TAG' but is not ours - nothing changed:"
    grep -F "# $AI_CRON_TAG" "$before" | ai_cron_without /dev/stdin | sed 's/^/  /'
    rm -f "$before" "$after"; return 1
  fi

  # 0. the map dir: the cron line appends its log there, and a redirection to a
  #    missing dir fails before the script could create it
  if [[ "$un" != 1 && ! -d "${log%/*}" ]]; then
    if [[ "$dry" == 1 ]]; then echo "PLAN dir: mkdir -p ${log%/*}"
    else mkdir -p "${log%/*}" && echo "DONE dir: ${log%/*}" || { do_log "FATAL cannot create ${log%/*}"; rm -f "$before" "$after"; return 1; }; fi
  fi

  # 1. the cron line: the whole crontab, with exactly our line added/removed
  if [[ "$un" == 1 ]]; then ai_cron_without "$before" >"$after"
  else { ai_cron_without "$before"; printf '%s\n' "$want"; } >"$after"; fi
  if cmp -s "$before" "$after"; then
    echo "OK cron: nothing to change"
  else
    if [[ "$dry" == 1 ]]; then echo "PLAN cron: the crontab before -> after"; else echo "DO cron: the crontab before -> after"; fi
    diff -u --label before --label after "$before" "$after" | sed 's/^/  /'
    if [[ "$dry" == 0 ]]; then
      if $ct "$after"; then echo "DONE cron"; else do_log "FATAL crontab refused the new file"; rc=1; fi
    fi
  fi
  rm -f "$before" "$after"

  # 2. the tmux hooks: index [1] only. [0] is the window sorter's; a [1] that
  #    is not ours is reported and left alone, never overwritten.
  cmd="run-shell -b \"bash $script --apply --delay 8 >/dev/null 2>&1\""
  for hook in after-new-window pane-exited; do
    h="$(ai_tmux show-hooks -g "$hook" 2>/dev/null | grep -F "${hook}[1] " | head -1)"
    if [[ "$un" == 1 ]]; then
      if [[ "$h" != *agent-identity-reconcile.sh* ]]; then echo "OK hook ${hook}[1]: none of ours"
      elif [[ "$dry" == 1 ]]; then echo "PLAN hook: set-hook -gu ${hook}[1]   (was: $h)"
      else ai_tmux set-hook -gu "${hook}[1]" && echo "DONE hook: unset ${hook}[1]"; fi
    elif [[ "$h" == *"$script --apply"* ]]; then echo "OK hook ${hook}[1]: $h"
    elif [[ -n "$h" ]]; then echo "REFUSED hook ${hook}[1]: holds someone else's command, left alone: $h"; rc=1
    elif [[ "$dry" == 1 ]]; then echo "PLAN hook: set-hook -g ${hook}[1] '$cmd'"
    else ai_tmux set-hook -g "${hook}[1]" "$cmd" && echo "DONE hook: ${hook}[1] = $cmd"; fi
  done
  return "$rc"
}

# The tag ends our cron line and nothing else on a box: no other job's tag
# starts with it, and it is matched only as the WHOLE last field (" # <tag>"
# at the end of the line), never as a prefix or a substring. 2026-10-01: an
# install that matched its tag as a prefix deleted another job's line.
AI_CRON_TAG="csi-spl:agent-identity-reconcile"

# FILE with our line (and only our line) removed; every other line passes
# through byte-identical, its order kept.
ai_cron_without() {
  awk -v suf=" # $AI_CRON_TAG" '
    { l = length($0); s = length(suf)
      if (l >= s && substr($0, l - s + 1) == suf) next
      print }' "$1"
}
