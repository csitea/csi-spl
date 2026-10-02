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
# @description adapter, as the box's AGENT user (SPOOL_AGENT_USER; owner rule
# @description 2026-10-01: every programmatic start runs as the agent user),
# @description never as the user the record says it ran as. A claude transcript
# @description that is only in that recorded user's home is copied into the
# @description agent user's ~/.claude/projects first (the jsonl and its <sid>/
# @description dir, owned by the agent user; an existing copy is never
# @description overwritten). After the starts, any agent CLI (one carrying an
# @description agent id) that runs as the BOX user is an ALERT and the exit is
# @description non-zero. A record is REFUSED,
# @description named and skipped - never guessed - when its session is unknown
# @description or on two records, already running, its worktree is gone, or
# @description its transcript is not under its worktree's project dir or
# @description belongs to another agent. Each started agent gets a fresh row
# @description in the spool registry (and IDENTITY_LEGACY_REGISTRY, if set);
# @description then the windows are named from the map (reconcile) and the
# @description map is checked. Each window and claude --name is "<ID>@<tag>"
# @description (specs/058): the tag from SPOOL_BOX_TAG, BOX_TAG, else box.env.
# @description Dry run unless DRY_RUN=0: prints the plan (RESTORE / REFUSE / SKIP).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param IDENTITY_RESTORE_IDS (optional) - only these ids ("CLE-07 CLE-12"); the since rule is not applied
# @param IDENTITY_RESTORE_SINCE (optional) - UTC (2026-10-01T03:33:00Z); default the boot time
# @param IDENTITY_RESTORE_WINDOW (optional) - minutes after SINCE a death still counts as the restart's, default 15
# @param IDENTITY_RESTORE_SESSION (optional) - the tmux session for a record without one, default main
# @param IDENTITY_RESTORE_PAUSE (optional) - seconds between starts, default 5
# @param IDENTITY_LEGACY_REGISTRY (optional) - a second registry.tsv to append the new rows to
# @param IDENTITY_RESTORE_ADAPTER_DIR (optional) - where restore-<kind>.sh live (tests only)
# @param IDENTITY_RESTORE_USER (optional) - the user to start agents as, default the box's SPOOL_AGENT_USER
# @param IDENTITY_COPY_OWNER (optional) - the owner a copied transcript gets, default that user (tests only)
# @param IDENTITY_COPY_SUDO (optional) - the prefix that runs the copy, default "sudo -n" unless root (tests only)
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
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$feat/lib/spool-env.inc.sh" || return 1
  local agent_user box_user
  read -r box_user agent_user < <(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s %s\n' "$SPOOL_BOX_USER" "$SPOOL_AGENT_USER")
  agent_user="${IDENTITY_RESTORE_USER:-$agent_user}"
  [[ -n "$agent_user" ]] || { do_log "FATAL no agent user: set SPOOL_AGENT_USER in \$SPOOL_ROOT/box.env (or IDENTITY_RESTORE_USER)"; return 1; }
  local win="${IDENTITY_RESTORE_WINDOW:-15}" until
  [[ "$win" =~ ^[0-9]+$ ]] || { do_log "FATAL IDENTITY_RESTORE_WINDOW must be minutes, got: '$win'"; return 1; }
  if [[ -z "$since" ]]; then
    since="$(date -u -d "@$(awk '/^btime/{print $2}' /proc/stat)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  fi
  until="$(date -u -d "$since + $win minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  local plan line kind id user sid wt sess title from adapter brief pane reg="${SPOOL_ROOT:-/var/spool-hub}/registry.tsv"
  local n=0 refused=0 failed=0 now started=() tag
  # The box tag, resolved ONCE before any window exists: each agent comes back
  # as "<ID>@<tag>" (specs/058), its window and its CLI --name alike. An
  # @reboot job reads no profile, so ai_tag falls back to box.env.
  tag="$(ai_tag)"
  plan="$(ai_panes | ai_py restore-plan --since "$since" --until "$until" --ids "${IDENTITY_RESTORE_IDS:-}" --agent-user "$agent_user")" || return 1
  echo "restore: agents the restart at $since killed (dead by $until), from $(ai_dir), as $agent_user, box tag ${tag:-none}"
  while IFS= read -r line; do
    case "$line" in
      SKIP$'\t'*)   echo "SKIP    ${line#SKIP$'\t'}" | tr '\t' ' ' ;;
      REFUSE$'\t'*) echo "REFUSE  ${line#REFUSE$'\t'}" | sed 's/\t/: /'; refused=$((refused + 1)) ;;
      RESTORE$'\t'*)
        IFS=$'\t' read -r _ id kind user sid wt sess title from <<< "$line"
        [[ "$user" == - ]] && user=""; [[ "$sess" == - ]] && sess=""; [[ "$title" == - ]] && title=""
        [[ "$from" == - ]] && from=""
        sess="${sess:-${IDENTITY_RESTORE_SESSION:-main}}"
        adapter="${IDENTITY_RESTORE_ADAPTER_DIR:-$feat/scripts}/restore-$kind.sh"
        brief="${SPOOL_ROOT:-/var/spool-hub}/$id/brief.md"; [[ -f "$brief" ]] || brief=""
        if [[ "$dry" == 1 ]]; then
          [[ -n "$from" ]] && echo "COPY    $id: transcript $sid from $from's home to $user's"
          echo "RESTORE $id: $kind session $sid in $wt, as ${user:-the agent user}, new window '$(SPOOL_BOX_TAG="$tag" spool_decorate "$id")${title:+ $title}' in '$sess'"
          continue
        fi
        if [[ -n "$from" ]] && ! _ai_copy_transcript "$from" "$user" "$wt" "$sid"; then
          echo "FAILED  $id: cannot copy transcript $sid from $from's home to $user's"; failed=$((failed + 1)); continue
        fi
        [[ -x "$adapter" || -r "$adapter" ]] || { echo "FAILED  $id: no adapter $adapter"; failed=$((failed + 1)); continue; }
        ai_tmux has-session -t "=$sess" 2>/dev/null || ai_tmux new-session -d -s "$sess" 2>/dev/null
        pane="$(ai_tmux new-window -d -t "=$sess:" -n "$(SPOOL_BOX_TAG="$tag" spool_decorate "$id")${title:+ $title}" -P -F '#{pane_id}' \
          "env ${user:+SPOOL_AGENT_USER=$user }${tag:+SPOOL_BOX_TAG=$tag }bash '$adapter' '$id' '$wt' '$sid'${brief:+ '$brief'}" 2>/dev/null | grep -m1 -xE '%[0-9]+')"
        if [[ -z "$pane" ]]; then echo "FAILED  $id: tmux new-window printed no pane"; failed=$((failed + 1)); continue; fi
        now="$(date -u +%Y%m%dT%H%M%SZ)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$pane" "$wt" "$now" >> "$reg" 2>/dev/null
        [[ -n "${IDENTITY_LEGACY_REGISTRY:-}" ]] && printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$pane" "$wt" "$now" >> "$IDENTITY_LEGACY_REGISTRY" 2>/dev/null
        echo "STARTED $id: $kind session $sid in $wt [$pane]"; started+=("$id")
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
  if [[ "$dry" == 0 && "$n" -gt 0 && "$box_user" != "$agent_user" ]] && ! _ai_runas_check "$box_user" "${started[@]}"; then
    failed=$((failed + 1))
  fi
  (( failed == 0 ))
}

_ai_home() {  # USER
  local kv
  for kv in ${AI_TRANSCRIPT_HOME_MAP:-}; do [[ "${kv%%:*}" == "$1" ]] && { printf '%s' "${kv#*:}"; return 0; }; done
  getent passwd "$1" 2>/dev/null | cut -d: -f6
}

# FROM's transcript of SID (launch cwd WT) into TO's ~/.claude/projects, owned
# by TO: the jsonl plus its <sid>/ dir when present. An existing copy is kept.
_ai_copy_transcript() {  # FROM TO WT SID
  local fh th slug own="${IDENTITY_COPY_OWNER:-$2}" su
  if [[ -n "${IDENTITY_COPY_SUDO+x}" ]]; then su="$IDENTITY_COPY_SUDO"
  elif [[ "$(id -u)" == 0 ]]; then su=""; else su="sudo -n"; fi
  fh="$(_ai_home "$1")"; th="$(_ai_home "$2")"
  [[ -n "$fh" && -n "$th" ]] || return 1
  slug="$(printf '%s' "$3" | sed 's/[^A-Za-z0-9]/-/g')"
  local src="$fh/.claude/projects/$slug" dst="$th/.claude/projects/$slug"
  local d made=()
  # shellcheck disable=SC2086  # su is a command prefix, split on purpose
  for d in "$th/.claude" "$th/.claude/projects" "$dst"; do $su test -d "$d" || made+=("$d"); done
  # shellcheck disable=SC2086
  $su mkdir -p "$dst" && $su cp -an "$src/$4.jsonl" "$dst/" || return 1
  # shellcheck disable=SC2086
  if (( ${#made[@]} )); then $su chown "$own:" "${made[@]}" || return 1; fi
  # shellcheck disable=SC2086
  if $su test -d "$src/$4"; then $su cp -an "$src/$4" "$dst/" || return 1; fi
  # shellcheck disable=SC2086
  $su chown "$own:" "$dst" "$dst/$4.jsonl" || return 1
  # shellcheck disable=SC2086
  if $su test -d "$dst/$4"; then $su chown -R "$own:" "$dst/$4" || return 1; fi
  # shellcheck disable=SC2086
  $su test -s "$dst/$4.jsonl" && echo "COPIED  transcript $4 from $1's home to $2's ($dst)"
}

# The owner rule's own check (2026-10-01), narrowed to what this run started:
# an agent CLI (claude, grok, agy, qwen) that runs as the BOX user and carries
# the id of an agent this run started. The box user's own interactive CLI has
# no agent id and is not flagged; the whole-box check is the boot action's.
_ai_runas_check() {  # BOX-USER ID...
  local pid args aid bad=0 box="$1"; shift
  local ids=" $* "
  while read -r pid args; do
    [[ "${args%% *}" =~ (^|/)(claude|grok|agy|qwen)$ ]] || continue
    aid="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -nE 's/^(SPOOL_AGENT_ID|MCP_BOT_AGENT_ID)=//p' | head -n 1)"
    [[ -n "$aid" && "$ids" == *" $aid "* ]] || continue
    echo "ALERT   pid $pid ($aid) runs as $box, not the agent user: $args"; bad=1
  done < <(ps -u "$box" -o pid=,args= 2>/dev/null)
  return "$bad"
}
