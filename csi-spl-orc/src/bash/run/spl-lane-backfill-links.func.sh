#!/bin/bash
#------------------------------------------------------------------------------
# @description Fill the missing discussion and issue of THIS box's live lane
# @description rows (spec 153 3.11, SPL-4457; owner HUM-10, t1 0acd4eaa,
# @description msg 69522885). A row with no topic takes the one its own task
# @description brief names ($SPOOL_ROOT/<ID>/lifetime/brief.md, read as the
# @description spawn path reads it, _spawn_lane_topic); a row with no issue
# @description takes lifetime/issue, else the brief's `Issue:` line. Role
# @description seats (001-003, lease.conf ids) name neither by design and are
# @description left out. Prints every row it looks at before and after, then
# @description the counts. A dry run unless DRY_RUN=0, which writes each
# @description filled row with all its other fields kept (do_spl_lane_put).
# @param DRY_RUN (optional) - 1 (default) prints only; 0 writes the filled rows
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX LANE_BOX LANE_HUB_CMD (optional) - as do_spl_lane_map
# @example ./run -a do_spl_lane_backfill_links
# @example DRY_RUN=0 ./run -a do_spl_lane_backfill_links
#------------------------------------------------------------------------------

declare -F spl_lane_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"
declare -F do_spl_lane_put >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-put.func.sh"

do_spl_lane_backfill_links() {
  local dry="${DRY_RUN:-1}" sa="$PROJ_PATH/src/bash/features/spawn-agents" rows row id topic issue t i life
  local seen=0 before=0 after=0 filled=0 failed=0
  [[ "$dry" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got '$dry'"; return 1; }
  declare -F spl_is_role_seat >/dev/null || source "$sa/lib/spool-env.inc.sh"
  declare -F _spawn_lane_topic >/dev/null || source "$sa/scripts/spawn-core.inc.sh"
  declare -F li_key_from_brief >/dev/null || source "$sa/lib/lane-issue.inc.sh"
  spl_lane_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "FATAL no fleet (LANE_FLEET / LEASE_FLEET in lease.conf): no hub lane rows to fill"; return 1; }
  rows="$(spl_lane_hub --fleet "$LANE_FLEET" 2>&1)" || { do_log "FATAL the hub lane map did not answer: $(tail -1 <<<"$rows")"; return 2; }
  rows="$(jq -c --arg b "$LANE_BOX" '.lanes[]? | select(.agent_box == $b and .state == "live")' <<<"$rows" 2>/dev/null)"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    id="$(jq -r .agent_id <<<"$row")"
    [[ "$id" =~ ^[acgmq]-[0-9]{3}$ ]] || continue
    lane_backfill_role_seat "$id" && continue
    topic="$(jq -r '.topic // ""' <<<"$row")" issue="$(jq -r '.issue_key // ""' <<<"$row")"
    [[ -n "$topic" && -n "$issue" ]] && continue
    seen=$((seen + 1)) before=$((before + 1))
    life="${SPOOL_ROOT:-/var/spool-hub}/$id/lifetime"
    t="${topic:-$(_spawn_lane_topic "$life/brief.md")}"
    i="$issue"
    [[ -n "$i" ]] || i="$(head -1 "$life/issue" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$i" ]] || i="$(li_key_from_brief "$life/brief.md" 2>/dev/null)"
    [[ "$i" =~ ^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$ ]] || i=""
    printf 'BEFORE %s@%s topic=%s issue=%s\n' "$id" "$LANE_BOX" "${topic:--}" "${issue:--}"
    printf 'AFTER  %s@%s topic=%s issue=%s\n' "$id" "$LANE_BOX" "${t:--}" "${i:--}"
    [[ -n "$t" && -n "$i" ]] || after=$((after + 1))
    [[ "$t" == "$topic" && "$i" == "$issue" ]] && continue
    filled=$((filled + 1))
    [[ "$dry" == 1 ]] && continue
    LANE_AGENT="$id" LANE_STATE=live LANE_TOPIC="$t" LANE_ISSUE="$i" \
      LANE_REPO="$(jq -r '.repo // ""' <<<"$row")" LANE_BRANCH="$(jq -r '.branch // ""' <<<"$row")" \
      LANE_SCOPE="$(jq -r '.scope // ""' <<<"$row")" LANE_FILES="$(jq -r '.files // [] | join(",")' <<<"$row")" \
      do_spl_lane_put || failed=$((failed + 1))
  done <<<"$rows"
  do_log "INFO $LANE_BOX: $seen live lane row(s) lacked a topic or an issue; $filled can be filled from their briefs; missing after: $after (was $before)"
  (( failed == 0 )) || do_log "WARN $failed row(s) not written (the hub refused or did not answer)"
  [[ "$dry" == 1 ]] && do_log "INFO DRY_RUN=1: nothing written; DRY_RUN=0 writes the $filled filled row(s)"
  (( failed == 0 )) || return 2
  return 0
}

# lane_backfill_role_seat ID: a role seat (001-003 in any letter, or an id the
# dispatch lease.conf names) carries no discussion and no issue by design.
lane_backfill_role_seat() {
  spl_is_role_seat "$1" && return 0
  grep -qxE "LEASE_(MASTER|FAILOVER|ORCH)=$1" "${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf" 2>/dev/null
}
