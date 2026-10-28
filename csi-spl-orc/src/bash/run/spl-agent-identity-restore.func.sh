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
# @description belongs to another agent. Two exceptions to "session unknown":
# @description an m- lane continues its worktree's last vibe session, and a role
# @description seat (c-001..g-003, any vendor) with its <id>/handoff.md starts
# @description a NEW session kicked to that handoff (session '-', SPL-2638).
# @description Each started agent gets a fresh row
# @description in the spool registry (and IDENTITY_LEGACY_REGISTRY, if set);
# @description then the windows are named from the map (reconcile) and the
# @description map is checked. Each window and claude --name is "<ID>@<tag>"
# @description (specs/058): the tag from SPOOL_BOX_TAG, BOX_TAG, else box.env.
# @description Each start holds the agent's id lock (spec 102 4.2,
# @description <spool root>/<id>/lifetime/restart.lock) until the run ends:
# @description an id another actor holds is REFUSED; a start and its outcome
# @description are logged to rotate.log (run id <ts>-restore-<id>).
# @description Under that lock each id is read again right before its start
# @description (SPL-3771: two boot passes started one id twice): started
# @description already by this run, or a live window or process carrying it,
# @description is a SKIP; a worktree gone since the plan is a REFUSE naming the
# @description path - never a start in another directory.
# @description A window named for the id whose pane runs no harness (each process
# @description under tmux's `sh -c` wrapper a bare shell: the session ended,
# @description SPL-3979) is not live: the agent starts IN it (respawn-pane -k,
# @description the same pane, renamed), so its tmux window never disappears.
# @description A grok seat (its session read from grok's own store at record
# @description time, SPL-2507) comes back on grok only when grok can start: no
# @description grok cli, no sign-in or its weekly limit is ONE "FALLBACK <id>"
# @description line naming why; the seat is not started and its role falls to
# @description claude (lease failover, the rotation's successor rule).
# @description IDENTITY_RESTORE_IDS is a restore by hand, the admin's act that
# @description clears a 6.1 hold (<id>/lifetime/heldout, restore-core.inc.sh);
# @description without it the adapters run with RESTORE_KEEP_HOLD=1.
# @description Dry run unless DRY_RUN=0: prints the plan (RESTORE / REFUSE / SKIP / FALLBACK).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param IDENTITY_RESTORE_IDS (optional) - only these ids ("CLE-07 CLE-12"); the since rule is not applied, and each id not started is named with why (SKIP: no record on this box, already running (pid N); REFUSE ...)
# @param IDENTITY_RESTORE_SINCE (optional) - UTC (2026-10-01T03:33:00Z); default the boot time
# @param IDENTITY_RESTORE_WINDOW (optional) - minutes after SINCE a death still counts as the restart's, default 15
# @param IDENTITY_RESTORE_SESSION (optional) - the tmux session for a record without one, default main
# @param IDENTITY_RESTORE_PAUSE (optional) - seconds between starts, default 5
# @param IDENTITY_LEGACY_REGISTRY (optional) - a second registry.tsv to append the new rows to
# @param IDENTITY_RESTORE_ADAPTER_DIR (optional) - where restore-<kind>.sh live (tests only)
# @param IDENTITY_RESTORE_USER (optional) - the user to start agents as, default the box's SPOOL_AGENT_USER
# @param IDENTITY_COPY_OWNER (optional) - the owner a copied transcript gets, default that user (tests only)
# @param IDENTITY_COPY_SUDO (optional) - the prefix that runs the copy, default "sudo -n" unless root (tests only)
# @param GROK_BIN (optional) - the grok cli a grok seat restarts with, default grok on the agent user's login PATH
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_identity_restore
# @example DRY_RUN=0 ./run -a do_spl_agent_identity_restore
# @example IDENTITY_RESTORE_IDS="CLE-07" DRY_RUN=0 ./run -a do_spl_agent_identity_restore
#------------------------------------------------------------------------------
declare -F spl_agent_id_lock >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

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
  local plan line kind id user sid wt sess title from adapter brief pane dead rid why reg="${SPOOL_ROOT:-/var/spool-hub}/registry.tsv"
  local n=0 refused=0 failed=0 now started=() tag keep=1
  # Ids named by hand are the admin's restart (spec 102 6.1): the adapter
  # clears their hold. The automatic pass (the boot) keeps every hold.
  [[ -n "${IDENTITY_RESTORE_IDS:-}" ]] && keep=""
  # The box tag, resolved ONCE before any window exists: each agent comes back
  # as "<ID>@<tag>" (specs/058), its window and its CLI --name alike. An
  # @reboot job reads no profile, so ai_tag falls back to box.env.
  tag="$(ai_tag)"
  plan="$(ai_panes | ai_py restore-plan --since "$since" --until "$until" --ids "${IDENTITY_RESTORE_IDS:-}" --agent-user "$agent_user")" || return 1
  _ai_restore_head "$since" "$until" "$agent_user" "${tag:-none}"
  while IFS= read -r line; do
    case "$line" in
      SKIP$'\t'*)   echo "SKIP    ${line#SKIP$'\t'}" | sed 's/\t/: /' ;;
      REFUSE$'\t'*) echo "REFUSE  ${line#REFUSE$'\t'}" | sed 's/\t/: /'; refused=$((refused + 1)) ;;
      RESTORE$'\t'*)
        IFS=$'\t' read -r _ id kind user sid wt sess title from <<< "$line"
        [[ "$user" == - ]] && user=""; [[ "$sess" == - ]] && sess=""; [[ "$title" == - ]] && title=""; [[ "$from" == - ]] && from=""
        sess="${sess:-${IDENTITY_RESTORE_SESSION:-main}}"
        adapter="${IDENTITY_RESTORE_ADAPTER_DIR:-$feat/scripts}/restore-$kind.sh"
        brief="${SPOOL_ROOT:-/var/spool-hub}/$id/brief.md"; [[ -f "$brief" ]] || brief=""; rid="$(date -u +%Y%m%dT%H%M%SZ)-restore-$id"
        if ! spl_agent_id_lock "$id" do_spl_agent_identity_restore "$rid"; then
          echo "REFUSE  $id: $SPL_ID_LOCK_WHY"; refused=$((refused + 1)); continue
        fi
        why="$(_ai_restore_recheck "$id" "$wt" "${started[*]}")"; [[ -z "$why" ]] || { _ai_restore_skip "$id" "$wt" "$why" || refused=$((refused + 1)); continue; }
        if [[ "$kind" == grok ]] && _ai_grok_fallback "$id" "${user:-$agent_user}" "$dry" "$rid"; then refused=$((refused + 1)); continue; fi
        dead="$(_ai_dead_pane "$id")"
        if [[ "$dry" == 1 ]]; then
          [[ -n "$from" ]] && echo "COPY    $id: transcript $sid from $from's home to $user's"
          echo "RESTORE $id: $kind session $sid in $wt, as ${user:-the agent user}, ${dead:+in place of its dead pane $dead, }window '$(SPOOL_BOX_TAG="$tag" spool_decorate "$id")${title:+ $title}'${dead:- new in '$sess'}"
          continue
        fi
        if [[ -n "$from" ]] && ! _ai_copy_transcript "$from" "$user" "$wt" "$sid"; then
          echo "FAILED  $id: cannot copy transcript $sid from $from's home to $user's"; failed=$((failed + 1)); continue
        fi
        [[ -x "$adapter" || -r "$adapter" ]] || { echo "FAILED  $id: no adapter $adapter"; failed=$((failed + 1)); continue; }
        _ai_rlog "$rid" RESTORE START "$kind session $sid in $wt"
        pane="$(_ai_restore_window "$sess" "$(SPOOL_BOX_TAG="$tag" spool_decorate "$id")${title:+ $title}" "$dead" \
          "env ${user:+SPOOL_AGENT_USER=$user }${tag:+SPOOL_BOX_TAG=$tag }${keep:+RESTORE_KEEP_HOLD=1 }bash '$adapter' '$id' '$wt' '$sid'${brief:+ '$brief'}")"
        [[ -n "$pane" ]] || { echo "FAILED  $id: tmux printed no pane"; failed=$((failed + 1)); _ai_rlog "$rid" FAIL FAIL "tmux printed no pane"; continue; }
        now="$(date -u +%Y%m%dT%H%M%SZ)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$pane" "$wt" "$now" >> "$reg" 2>/dev/null
        [[ -n "${IDENTITY_LEGACY_REGISTRY:-}" ]] && printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$pane" "$wt" "$now" >> "$IDENTITY_LEGACY_REGISTRY" 2>/dev/null
        echo "STARTED $id: $kind session $sid in $wt [$pane]${dead:+ in place}"; started+=("$id")
        _ai_rlog "$rid" DONE OK "$kind session $sid in $wt [$pane]"
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

# The run's first line: what it restores. A restore by id applies no since
# window (SPL-3378), so it names the ids, not the window.
_ai_restore_head() {  # SINCE UNTIL AGENT-USER TAG
  if [[ -n "${IDENTITY_RESTORE_IDS:-}" ]]; then
    echo "restore: by id ($IDENTITY_RESTORE_IDS), from $(ai_dir), as $3, box tag $4"
  else
    echo "restore: agents the restart at $1 killed (dead by $2), from $(ai_dir), as $3, box tag $4"
  fi
}

# Why ID must not start NOW, read again under its id lock right before the
# start; nothing when it may. The plan is read once, before any start: a box's
# reboot 2026-10-26 ran two boot passes (the agent-boot-restore cron and the
# box-sessions boot), both planned m-799, and the second started it again 13 s
# after the first ended and freed the lock - two live sessions, one id
# (SPL-3771). "gone" = its worktree is not a directory any more: the adapter
# would run it in another cwd. Else a line: already started by this run, a
# window named for it whose pane is not an idle shell (a start still coming
# up), or a live process that carries the id. A window whose pane runs no
# harness (_ai_pane_gone) is not live: the start reuses it (_ai_dead_pane).
_ai_restore_recheck() {  # ID WORKTREE STARTED-IDS
  local id="$1" wid name pane ppid
  [[ -d "$2" ]] || { echo gone; return 0; }
  [[ " $3 " == *" $id "* ]] && { echo "already started by this run"; return 0; }
  while IFS=$'\t' read -r _ _ pane ppid name; do
    spool_id_of_window_var wid "$name"
    [[ "$wid" == "$id" ]] || continue
    _ai_pane_gone "$ppid" && continue
    echo "a live window already carries it ($name, $pane)"; return 0
  done < <(ai_panes)
  ai_panes | ai_py restore-plan --ids "$id" 2>/dev/null | awk -F'\t' -v i="$id" '$1 == "SKIP" && $2 == i && $3 ~ /^already running/ { print $3; exit }'
}

# The first pane of a window named for ID that runs no harness; nothing when
# none. The restore starts the agent in it, so its window never disappears.
_ai_dead_pane() {  # ID
  local wid name pane ppid
  while IFS=$'\t' read -r _ _ pane ppid name; do
    spool_id_of_window_var wid "$name"
    [[ "$wid" == "$1" ]] && _ai_pane_gone "$ppid" && { echo "$pane"; return 0; }
  done < <(ai_panes)
  return 0
}

# 0 when the pane whose process is PANE-PID runs no harness: that process is
# a bare shell (or gone), or every process under it is. tmux runs a launcher
# as `sh -c '<launcher>'`, a cmdline that is never a shell's; when the
# session ends the launcher execs `bash --norc` under it (SPL-3979: the dead
# window counted as live and the id was SKIPped until a hand close). A
# wrapper with nothing under it, or with any other process under it (a start
# still coming up), is live.
_ai_pane_gone() {  # PANE-PID
  local p="${AI_PROC_ROOT:-/proc}" k n=0
  _ai_bare_shell "$1" && return 0
  while read -r k; do
    _ai_bare_shell "$k" || return 1; n=$((n + 1))
  done < <(cat "$p"/[0-9]*/stat 2>/dev/null | awk -v r="$1" '{s = $0; sub(/^.*\) /, "", s); split(s, f, " "); kid[f[2]] = kid[f[2]] " " $1}
    END {q[1] = r; n = 1; for (i = 1; i <= n; i++) {c = split(kid[q[i]], a, " "); for (j = 1; j <= c; j++) {print a[j]; q[++n] = a[j]}}}')
  (( n > 0 ))
}

_ai_bare_shell() {  # PID
  local cmd
  cmd="$(tr '\0' ' ' < "${AI_PROC_ROOT:-/proc}/$1/cmdline" 2>/dev/null)"
  [[ -z "$cmd" || "$cmd" =~ ^-?(ba|da|z)?sh(\ --norc)?\ ?$ ]]
}

# The pane a start runs in: DEAD (a dead window of the id) respawned in place
# and renamed, else a new window in SESSION. Prints the pane id.
_ai_restore_window() {  # SESSION NAME DEAD CMD
  if [[ -n "$3" ]]; then
    ai_tmux respawn-pane -k -t "$3" "$4" 2>/dev/null || return 0
    ai_tmux rename-window -t "$3" "$2" 2>/dev/null; echo "$3"; return 0
  fi
  ai_tmux has-session -t "=$1" 2>/dev/null || ai_tmux new-session -d -s "$1" 2>/dev/null
  ai_tmux new-window -d -t "=$1:" -n "$2" -P -F '#{pane_id}' "$4" 2>/dev/null | grep -xE '%[0-9]+' | sed -n 1p
}

# The re-check's one line: a gone worktree is a REFUSE (1, counted), the
# rest a SKIP (0).
_ai_restore_skip() {  # ID WORKTREE WHY
  [[ "$3" == gone ]] || { echo "SKIP    $1: $3"; return 0; }
  echo "REFUSE  $1: its worktree $2 is gone; not started in another directory (the orchestrator decides)"; return 1
}

# A grok seat comes back on grok only when grok can start; else ONE line
# names why and the seat is not started (0 = it fell back). Its role goes to
# claude: the fleet lease fails over and the rotation's successor rule
# (spl_rotate_role_vendor) picks claude for the same reason. The id is never
# restarted on another CLI.
_ai_grok_fallback() {  # ID USER DRY RID
  local why
  why="$(_ai_grok_why "$2")"
  [[ -n "$why" ]] || return 1
  echo "FALLBACK $1: grok cannot start ($why): not restored on grok, its role falls to claude"
  [[ "$3" == 1 ]] || _ai_rlog "$4" RESTORE FALLBACK "grok cannot start ($why): its role falls to claude"
  return 0
}

# Why grok cannot start a restored seat as USER, nothing when it can: no grok
# CLI on the user's login PATH (GROK_BIN, default grok), no sign-in
# (~/.grok/auth.json empty or missing), or its weekly limit: the NEWEST
# watchdog verdict of all grok seats of this box is S2 kind=limit
# (spl_rotate_grok_out, the rotation's own check, SPL-2555). File reads only.
_ai_grok_why() {  # USER
  local u="$1" bin="${GROK_BIN:-grok}" home su=()
  [[ "$(id -un)" == "$u" ]] || su=(sudo -n -u "$u")
  if [[ "$bin" == /* ]]; then
    [[ -x "$bin" ]] || "${su[@]}" test -x "$bin" 2>/dev/null || { echo "no grok cli at $bin"; return 0; }
  else
    "${su[@]}" bash -lc 'command -v "$0"' "$bin" >/dev/null 2>&1 || { echo "no grok cli '$bin' on $u's PATH"; return 0; }
  fi
  home="$(_ai_home "$u")"
  [[ -n "$home" ]] && { [[ -s "$home/.grok/auth.json" ]] || "${su[@]}" test -s "$home/.grok/auth.json" 2>/dev/null; } ||
    { echo "no grok sign-in for $u (${home:-?}/.grok/auth.json)"; return 0; }
  local lim
  lim="$(spl_rotate_grok_out)"
  [[ -z "$lim" ]] || echo "its limit: $lim"
  return 0
}

# One rotate.log line under the restore's run id (<ts>-restore-<id>), so
# spl_wd_rotating sees the start in flight until its DONE / FAIL line.
_ai_rlog() {  # RID PHASE RESULT DETAIL
  echo "$(date -u +%FT%TZ) $1 $2 $3 ${4:-}" >> "${ROTATE_LOG:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/rotate.log}" 2>/dev/null || true
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
# an agent CLI (claude, grok, agy, qwen, mistral's vibe - whose process reads
# "Vibe CLI", specs/110 T007) that runs as the BOX user and carries
# the id of an agent this run started. The box user's own interactive CLI has
# no agent id and is not flagged; the whole-box check is the boot action's.
_ai_runas_check() {  # BOX-USER ID...
  local pid args aid bad=0 box="$1"; shift
  local ids=" $* "
  while read -r pid args; do
    [[ "${args%% *}" =~ (^|/)(claude|grok|agy|qwen|vibe)$ || "$args" == "Vibe CLI" || "$args" == "Vibe CLI "* ]] || continue
    aid="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -nE 's/^(SPOOL_AGENT_ID|MCP_BOT_AGENT_ID)=//p' | sed -n 1p)"
    [[ -n "$aid" && "$ids" == *" $aid "* ]] || continue
    echo "ALERT   pid $pid ($aid) runs as $box, not the agent user: $args"; bad=1
  done < <(ps -u "$box" -o pid=,args= 2>/dev/null)
  return "$bad"
}
