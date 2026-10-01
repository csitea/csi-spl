#!/bin/bash
#------------------------------------------------------------------------------
# @description Start again, after a reboot or a tmux server restart, every
# @description agent the identity map ($SPOOL_ROOT/agents) says the restart
# @description killed: each record that still says alive with no live process,
# @description or that the first pass after the restart flipped to dead (gone
# @description between IDENTITY_RESTORE_SINCE, default the boot time, and
# @description IDENTITY_RESTORE_WINDOW minutes later). An agent that exited on
# @description its own is not brought back. Each one resumes ITS OWN session in ITS OWN
# @description worktree, in a NEW window (never a pane id from before the
# @description restart: tmux reuses them), through the restore-<kind>.sh
# @description adapter, as the user the agent ran as. A record is REFUSED,
# @description named and skipped - never guessed - when its session is unknown
# @description or on two records, already running, its worktree is gone, or
# @description its transcript is not under its worktree's project dir or
# @description belongs to another agent. Each started agent gets a fresh row
# @description in the spool registry (and IDENTITY_LEGACY_REGISTRY, if set);
# @description then the windows are named from the map (reconcile) and the
# @description map is checked.
# @description Dry run unless DRY_RUN=0: prints the plan (RESTORE / REFUSE / SKIP).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param IDENTITY_RESTORE_IDS (optional) - only these ids ("CLE-07 CLE-12"); the since rule is not applied
# @param IDENTITY_RESTORE_SINCE (optional) - UTC (2026-10-01T03:33:00Z); default the boot time
# @param IDENTITY_RESTORE_WINDOW (optional) - minutes after SINCE a death still counts as the restart's, default 15
# @param IDENTITY_RESTORE_SESSION (optional) - the tmux session for a record without one, default main
# @param IDENTITY_RESTORE_PAUSE (optional) - seconds between starts, default 5
# @param IDENTITY_LEGACY_REGISTRY (optional) - a second registry.tsv to append the new rows to
# @param IDENTITY_RESTORE_ADAPTER_DIR (optional) - where restore-<kind>.sh live (tests only)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_identity_restore
# @example DRY_RUN=0 ./run -a do_spl_agent_identity_restore
# @example IDENTITY_RESTORE_IDS="CLE-07" DRY_RUN=0 ./run -a do_spl_agent_identity_restore
#------------------------------------------------------------------------------
do_spl_agent_identity_restore() {
  local dry="${DRY_RUN:-1}" since="${IDENTITY_RESTORE_SINCE:-}" pause="${IDENTITY_RESTORE_PAUSE:-5}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$pause" =~ ^[0-9]+$ ]] || { do_log "FATAL IDENTITY_RESTORE_PAUSE must be seconds, got: '$pause'"; return 1; }
  local feat="$PROJ_PATH/src/bash/features/spawn-agents"
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$feat/lib/agent-identity.inc.sh" || return 1
  local win="${IDENTITY_RESTORE_WINDOW:-15}" until
  [[ "$win" =~ ^[0-9]+$ ]] || { do_log "FATAL IDENTITY_RESTORE_WINDOW must be minutes, got: '$win'"; return 1; }
  if [[ -z "$since" ]]; then
    since="$(date -u -d "@$(awk '/^btime/{print $2}' /proc/stat)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  fi
  until="$(date -u -d "$since + $win minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  local plan line kind id user sid wt sess title adapter brief pane reg="${SPOOL_ROOT:-/var/spool-hub}/registry.tsv"
  local n=0 refused=0 failed=0 now
  plan="$(ai_panes | ai_py restore-plan --since "$since" --until "$until" --ids "${IDENTITY_RESTORE_IDS:-}")" || return 1
  echo "restore: agents the restart at $since killed (dead by $until), from $(ai_dir)"
  while IFS= read -r line; do
    case "$line" in
      SKIP$'\t'*)   echo "SKIP    ${line#SKIP$'\t'}" | tr '\t' ' ' ;;
      REFUSE$'\t'*) echo "REFUSE  ${line#REFUSE$'\t'}" | sed 's/\t/: /'; refused=$((refused + 1)) ;;
      RESTORE$'\t'*)
        IFS=$'\t' read -r _ id kind user sid wt sess title <<< "$line"
        [[ "$user" == - ]] && user=""; [[ "$sess" == - ]] && sess=""; [[ "$title" == - ]] && title=""
        sess="${sess:-${IDENTITY_RESTORE_SESSION:-main}}"
        adapter="${IDENTITY_RESTORE_ADAPTER_DIR:-$feat/scripts}/restore-$kind.sh"
        brief="${SPOOL_ROOT:-/var/spool-hub}/$id/brief.md"; [[ -f "$brief" ]] || brief=""
        if [[ "$dry" == 1 ]]; then
          echo "RESTORE $id: $kind session $sid in $wt, as ${user:-the agent user}, new window in '$sess'"
          continue
        fi
        [[ -x "$adapter" || -r "$adapter" ]] || { echo "FAILED  $id: no adapter $adapter"; failed=$((failed + 1)); continue; }
        ai_tmux has-session -t "=$sess" 2>/dev/null || ai_tmux new-session -d -s "$sess" 2>/dev/null
        pane="$(ai_tmux new-window -d -t "=$sess:" -n "$id${title:+ $title}" -P -F '#{pane_id}' \
          "env ${user:+SPOOL_AGENT_USER=$user }bash '$adapter' '$id' '$wt' '$sid'${brief:+ '$brief'}" 2>/dev/null | grep -m1 -xE '%[0-9]+')"
        if [[ -z "$pane" ]]; then echo "FAILED  $id: tmux new-window printed no pane"; failed=$((failed + 1)); continue; fi
        now="$(date -u +%Y%m%dT%H%M%SZ)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$pane" "$wt" "$now" >> "$reg" 2>/dev/null
        [[ -n "${IDENTITY_LEGACY_REGISTRY:-}" ]] && printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$pane" "$wt" "$now" >> "$IDENTITY_LEGACY_REGISTRY" 2>/dev/null
        echo "STARTED $id: $kind session $sid in $wt [$pane]"
        n=$((n + 1))
        (( pause > 0 )) && sleep "$pause"
        ;;
    esac
  done <<< "$plan"
  echo "restore: $n started, $refused refused, $failed failed"
  if [[ "$dry" == 0 && "$n" -gt 0 ]]; then
    sleep "${IDENTITY_RESTORE_SETTLE:-10}"
    ai_reconcile --apply | grep -vE '^SKIP pid' || true
    ai_check
  fi
  (( failed == 0 ))
}
