#!/bin/bash
#------------------------------------------------------------------------------
# @description The orchestrator outcome check (SPL-1717; lesson
# @description lesson-grok-od-roles-2026-10-13.md 1.5 and 5 row 9: "judge a
# @description role by its output, not its activity"). One box-level call of
# @description the watchdog tick (spl_wd_tick), like the fence: it runs on the
# @description box whose agent holds the orch role (<LEASE_DIR>/lease.orch),
# @description at most once per WD_ORCH_OUTCOME_EVERY s across the instances.
# @description It sends ONE blocker to the dispatch lease holder when, for
# @description WD_ORCH_OUTCOME_HOURS (2) hours, the orchestrator role (seat
# @description 001 in any vendor letter) produced
# @description   - no lane brief: no new <x>001*.md in WD_ORCH_BRIEF_DIRS,
# @description   - no round brief: no kind=task message in a role outbox
# @description     (<spool root>/<x>-001/outbox),
# @description   - and closed no ask: no done/decline line by the role in
# @description     <spool root>/asks/journal.log,
# @description while an ask to the orchestrator (a spawn request is one) waits:
# @description open or acked in the ask book and created before the window.
# @description The alert is sent once per episode; the episode ends (and the
# @description alert re-arms) when the role shows an outcome or nothing waits.
# @description Every check writes one ORCH-OUTCOME line to wd.log.
# @param WD_ORCH_OUTCOME_HOURS (optional) - hours without an outcome before the alert, default 2; 0 = off
# @param WD_ORCH_OUTCOME_EVERY (optional) - seconds between two checks, default 300
# @param WD_ORCH_BRIEF_DIRS (optional) - space-separated brief dirs, default "<spool root>/dispatch/briefs /var/tmp/c-parent-level/dispatch/briefs"
# @param WD_ORCH_HOLDER (optional, tests) - the orch holder as <ID>@<box>, instead of <LEASE_DIR>/lease.orch
#------------------------------------------------------------------------------

# spl_wd_orch_outcome NOW: the tick's one call. Never fails the tick.
spl_wd_orch_outcome() {
  local now="$1" hours="${WD_ORCH_OUTCOME_HOURS:-2}" every="${WD_ORCH_OUTCOME_EVERY:-300}"
  [[ "$hours" =~ ^[0-9]+$ && "$every" =~ ^[0-9]+$ ]] || { spl_wd_log "ORCH-OUTCOME bad WD_ORCH_OUTCOME_HOURS/EVERY: '$hours' '$every'"; return 0; }
  (( hours > 0 )) || return 0
  local holder
  holder="$(spl_wdo_holder)"
  [[ -n "$holder" && "${holder##*@}" == "${WD_BOX:-}" ]] || return 0
  # one check per period across the 3 instances (10.4.1)
  ( exec 5>>"$WD_DIR/orch-outcome.lock"
    flock -n 5 || exit 0
    last="$(cat "$WD_DIR/orch-outcome.last" 2>/dev/null || true)"
    [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < every )) && exit 0
    echo "$now" > "$WD_DIR/orch-outcome.last"
    spl_wdo_check "$now" "$holder" "$(( now - hours * 3600 ))" "$hours"
  ) 6>&- 7>&- 8>&- 9>&- || true
  return 0
}

# spl_wdo_check NOW HOLDER SINCE HOURS: judge, log, and alert once.
spl_wdo_check() {
  local now="$1" holder="$2" since="$3" hours="$4" briefs tasks closed waiting why
  briefs="$(spl_wdo_briefs "$since")"
  tasks="$(spl_wdo_tasks "$since")"
  closed="$(spl_wdo_closed "$since")"
  waiting="$(spl_wdo_waiting "$since")"
  why="role $holder in ${hours}h: briefs=$briefs round_tasks=$tasks asks_closed=$closed; waiting>${hours}h=$waiting"
  if (( briefs + tasks + closed > 0 || waiting == 0 )); then
    [[ -e "$WD_DIR/orch-outcome.alerted" ]] && spl_wd_log "ORCH-OUTCOME cleared: $why"
    rm -f "$WD_DIR/orch-outcome.alerted"
    spl_wd_log "ORCH-OUTCOME ok: $why"
    return 0
  fi
  if [[ -e "$WD_DIR/orch-outcome.alerted" ]]; then
    spl_wd_log "ORCH-OUTCOME still none (alerted at $(cat "$WD_DIR/orch-outcome.alerted")): $why"
    return 0
  fi
  local to body
  to="$(spl_wd_dispatcher)"
  body="WATCHDOG (SPL-1717): the orchestrator role ($holder) has produced no outcome for ${hours} h: no lane brief, no round brief and no ask closed, while $waiting ask(s) to it wait longer than that ($(spl_wdo_waiting_ids "$since")). Check its pane and its queue (do_spl_orch_inbox); the role may need a rotation."
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    spl_wd_log "ORCH-OUTCOME-DRY would send $to a blocker: $why"
    return 0
  fi
  if spl_wd_send "$to" blocker orch-outcome "$body"; then
    echo "$now" > "$WD_DIR/orch-outcome.alerted"
    spl_wd_log "ORCH-OUTCOME ALERT sent $to a blocker: $why"
  else
    spl_wd_log "ORCH-OUTCOME ALERT to $to NOT delivered (retried next check): $why"
  fi
  return 0
}

# The orch holder <ID>@<box>: WD_ORCH_HOLDER, else lease.orch "<ID>@<box> <epoch>".
spl_wdo_holder() {
  local h="${WD_ORCH_HOLDER:-}"
  [[ -n "$h" || ! -r "$LEASE_DIR/lease.orch" ]] || read -r h _ < "$LEASE_DIR/lease.orch" || true
  if [[ "$h" =~ ^[A-Za-z0-9][A-Za-z0-9-]*@[A-Za-z0-9][A-Za-z0-9._-]*$ && "${h%@*}" != none ]]; then echo "$h"; fi
  return 0
}

# 0 when ID (an "@<box>" allowed) is the orchestrator seat in any vendor letter.
spl_wdo_is_orch() {
  if declare -F spl_role_seat_num >/dev/null; then [[ "$(spl_role_seat_num "$1")" == 001 ]]; return; fi
  [[ "$1" =~ ^([acgmq]|CLE|GRK|AGY|QWN)-001(@[A-Za-z0-9._-]+)?$ ]]
}

# Lane briefs the role wrote since SINCE: <x>001*.md files ("c001tnk-<slug>.md",
# "g001-<slug>.md") in the brief dirs, by mtime.
spl_wdo_briefs() {
  local d n=0 dirs="${WD_ORCH_BRIEF_DIRS:-$SPOOL_ROOT/dispatch/briefs /var/tmp/c-parent-level/dispatch/briefs}"
  for d in $dirs; do
    [[ -d "$d" ]] || continue
    n=$(( n + $(find "$d" -maxdepth 1 -type f -regex '.*/[acgmq]001[^/]*\.md' -newermt "@$1" 2>/dev/null | wc -l) ))
  done
  echo "$n"
}

# Round briefs (and any other task) the role sent since SINCE: kind=task
# messages in a role seat's outbox; only files newer than SINCE are read.
# Each real outbox once: a-/g-/m-/q-001 are often symlinks to c-001. One grep
# picks the files that can be a task, jq confirms each: one jq per file read
# 830 files (166 x 5 links), 17-23 s of a 20 s pre-flight tick (SPL-2510).
spl_wdo_tasks() {
  local d r f n=0 seen=" "
  for d in "$SPOOL_ROOT"/[acgmq]-001/outbox; do
    [[ -d "$d" ]] || continue
    r="$(readlink -f "$d")"
    [[ "$seen" == *" $r "* ]] && continue
    seen+="$r "
    while IFS= read -r -d '' f; do
      [[ "$(jq -r '.kind // empty' "$f" 2>/dev/null)" == task ]] && n=$((n + 1))
    done < <(find "$d" -maxdepth 1 -type f -name '*.json' -newermt "@$1" -print0 2>/dev/null |
      xargs -0 -r grep -lZF '"task"' 2>/dev/null)
  done
  echo "$n"
}

# Asks the role closed since SINCE: journal.log "<utc> done|decline <id> <by> <state>".
spl_wdo_closed() {
  local f="$SPOOL_ROOT/asks/journal.log" ts op by n=0 from
  from="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)"
  [[ -f "$f" ]] || { echo 0; return 0; }
  while read -r ts op _ by _; do
    [[ "$ts" > "$from" || "$ts" == "$from" ]] || continue
    [[ "$op" == "done" || "$op" == "decline" ]] || continue
    if spl_wdo_is_orch "$by"; then n=$((n + 1)); fi
  done < <(tail -n "${WD_ORCH_JOURNAL_TAIL:-5000}" "$f")
  echo "$n"
}

# Asks to the orchestrator still open or acked that were created before SINCE.
spl_wdo_waiting_rows() {
  local d="$SPOOL_ROOT/asks" from
  from="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)"
  compgen -G "$d/*.json" >/dev/null || return 0
  jq -r --arg from "$from" 'select((.role // "orch") == "orch" and (.state == "open" or .state == "acked")
    and (.created_at // "") != "" and .created_at <= $from) | .ask_id[0:8]' "$d"/*.json 2>/dev/null
  return 0
}
spl_wdo_waiting() { spl_wdo_waiting_rows "$1" | grep -c . || true; }
spl_wdo_waiting_ids() { spl_wdo_waiting_rows "$1" | sed -n '1,5p' | tr '\n' ' ' | sed 's/ $//'; }
