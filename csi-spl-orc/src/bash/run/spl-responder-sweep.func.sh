#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1265 / epic SPL-1238, the reboot-proof driver of the non-AI
# @description responder. One sweep over EVERY tenant that has an RSP desk
# @description seated on this box (a box-rsp spool under SPL_STATE_DIR/desk/*):
# @description for each, run do_spl_responder_run, which answers each unheard
# @description post with a "Seen: routed to the team" reply + a FILE to the
# @description orchestrator. This is the target of the every-3-min cron (the
# @description watchdog), so the responder is permanent and survives a reboot
# @description without a human - no systemd/root: a crontab line the box user
# @description already owns, exactly like do_spl_desk_install_service chose for
# @description the desk reconcile (box user Linger=no, no user bus over sudo).
# @description The always-on service reacts in seconds; this cron is the belt.
# @description It never seats a desk: the desk reconcile does that. A tenant
# @description whose RSP desk is not seated is logged and skipped, not an error.
# @description ONE machine answers (specs/064 L2): when the fleet's dispatch
# @description lease is held on ANOTHER machine (do_spl_dispatch_lease, the
# @description same gate as do_spl_unanswered_sweep), this machine's sweep
# @description sends nothing and logs one INFO line - two machines with a
# @description box-rsp desk would otherwise post two "Seen" replies per post.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param DESK_BOX (optional) - the responder box, default box-rsp
# @param DESK_AGENT (optional) - the responder agent, default RSP-01
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_responder_sweep
#------------------------------------------------------------------------------
do_spl_responder_sweep() {
  do_require_bin python3 || return 1
  do_spl_cloud_cnf || return 1
  local box="${DESK_BOX:-box-rsp}" agent="${DESK_AGENT:-RSP-01}"
  local deskroot="$SPL_STATE_DIR/desk"
  # fleet mode: the lease holder's machine answers; a standby sends nothing
  spl_lease_init ro || return 1
  spl_lease_conf
  if spl_lease_read && spl_lease_remote; then
    do_log "INFO the fleet's dispatch lease is held by $LH: this machine's responder sends nothing"
    return 0
  fi
  [[ -d "$deskroot" ]] || { do_log "OK responder sweep ($ENV): no desks on this box ($deskroot)"; return 0; }

  # Every tenant with a seated box-rsp spool is in scope. The reconcile seats
  # them; we only drain and answer.
  local seated=0 swept=0 fails=0 tdir tenant
  for tdir in "$deskroot"/*/; do
    tenant="$(basename "$tdir")"
    [[ -d "$tdir$box/spool" ]] || continue
    seated=$((seated + 1))
    if TENANT_ID="$tenant" DESK_BOX="$box" DESK_AGENT="$agent" do_spl_responder_run; then
      swept=$((swept + 1))
    else
      do_log "FAIL responder run for $agent in $tenant ($box)"
      fails=$((fails + 1))
    fi
  done

  if (( seated == 0 )); then
    do_log "OK responder sweep ($ENV): no $box desk seated on this box yet (the reconcile seats it)"
    return 0
  fi
  do_log "OK responder sweep ($ENV): $swept/$seated tenant(s) handled, $fails failed"
  (( fails == 0 ))
}
