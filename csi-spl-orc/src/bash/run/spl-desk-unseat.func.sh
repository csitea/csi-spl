#!/bin/bash
#------------------------------------------------------------------------------
# @description Take ONE live agent off a desk, leaving the box's sidecar and
# @description every other seat running. Its spool dir moves to the desk's
# @description retired/ (spl_desk_retire, the move DESK_RETIRE makes for a gone
# @description window), so the hub stops listing it on the next rescan (~10s)
# @description and no owner post or unanswered sweep reaches it any more.
# @description Before this, nothing unseated one live agent: do_spl_desk_down
# @description stops the shared sidecar and refuses while others are seated,
# @description DESK_RETIRE only takes agents whose window is gone, DESK_SKIP only
# @description skips NEW seating, and a mute (.no-poke) still lands posts in the
# @description muted inbox. On t1 prd 2026-10-11 review lanes (a-173, a-175)
# @description answered owner posts that way.
# @description Moved, never deleted: the inbox is the record. A lane with no
# @description desk role is not seated again by do_spl_desk_up_all
# @description (DESK_ROLE_ONLY=1, its default).
# @description Refuses an agent not seated on that desk, and an orchestrator or
# @description dispatcher seat (lease.conf): those carry the owner's posts.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the ONE agent id to unseat
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=a-175 ./run -a do_spl_desk_unseat
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=a-175 DRY_RUN=0 ./run -a do_spl_desk_unseat
#------------------------------------------------------------------------------
do_spl_desk_unseat() {
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" a="${DESK_AGENT:-}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_participant_id "$a" || { do_log "FATAL DESK_AGENT '$a' is not an agent id (e.g. a-175): name the ONE agent to unseat"; return 1; }
  local d="$SPL_STATE_DIR/desk/$tenant/$box"
  if [[ ! -d "$d/spool/$a" ]]; then
    do_log "FATAL $a is not seated on $box in $tenant ($ENV): no dir $d/spool/$a. Seated: $(spl_desk_seated "$d" | tr '\n' ' ')"
    return 1
  fi
  if spl_desk_is_od "$a"; then
    do_log "FATAL $a is an orchestrator or dispatcher seat (lease.conf): it carries the owner's posts and is never unseated by this action"
    return 1
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: move $d/spool/$a to $d/retired/, leaving the sidecar and the other seats: $(spl_desk_seated "$d" | grep -vx -- "$a" | tr '\n' ' ')"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_desk_retire "$d" "$a" || return 1
  spl_desk_has_role "$a" && do_log "WARN $a has a desk role: do_spl_desk_up_all seats it again on its next tick"
  do_log "OK unseated $a from $box in $tenant ($ENV); the sidecar and the other seats keep running"
}
