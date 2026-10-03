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
# @description A tenant whose RSP desk is not seated is logged and skipped.
# @description ONE machine answers (specs/064 L2). The hub keeps one socket
# @description per (tenant, box), so only the machine holding the fleet's
# @description dispatch lease (do_spl_dispatch_lease) keeps an RSP sidecar up:
# @description   holder  - an RSP desk whose sidecar is down is seated again
# @description             (only a desk already pinned: never needs a root
# @description             key), then answered;
# @description   standby - its own RSP sidecars are taken down with
# @description             do_spl_desk_down (so the reconcile leaves them
# @description             down) and nothing is sent: one INFO line;
# @description   unknown - the lease reads none@unreachable or is older than
# @description             LEASE_STALE: a WARN, no sidecar is touched, and a
# @description             live local desk is still answered (a wrong "I am
# @description             standby" must never kill the only "Seen");
# @description   one machine - no lease, or a bare holder id: as before.
# @description Dry run unless DRY_RUN=0 (the seat/down steps too).
# @param ENV - required: dev or prd
# @param DESK_BOX (optional) - the responder box, default SPOOL_RSP_BOX
# @param   from the box config ($SPOOL_BOX_ENV, default <spool root>/box.env), else box-rsp
# @param DESK_AGENT (optional) - the responder agent, default RSP-01
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_responder_sweep
#------------------------------------------------------------------------------
do_spl_responder_sweep() {
  do_require_bin python3 || return 1
  do_spl_cloud_cnf || return 1
  local box="${DESK_BOX:-$(spl_rsp_box_default)}" agent="${DESK_AGENT:-RSP-01}"
  local deskroot="$SPL_STATE_DIR/desk" role dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_lease_init ro || return 1
  spl_lease_conf
  spl_lease_read
  role="$(spl_rsp_role)"
  case "$role" in
    unknown) do_log "WARN the dispatch lease reads '$LH' (unreachable or stale): no $box sidecar is seated or taken down this tick" ;;
    standby) do_log "INFO the fleet's dispatch lease is held by $LH: this machine's responder sends nothing" ;;
  esac
  [[ -d "$deskroot" ]] || { do_log "OK responder sweep ($ENV): no desks on this box ($deskroot)"; return 0; }

  # Every tenant with a seated box-rsp spool is in scope. The reconcile seats
  # them; we only drain and answer (and, in fleet mode, keep the sidecar on
  # the lease holder only).
  local seated=0 swept=0 fails=0 tdir tenant d
  for tdir in "$deskroot"/*/; do
    tenant="$(basename "$tdir")"
    d="$tdir$box"
    [[ -d "$d/spool" ]] || continue
    seated=$((seated + 1))
    if [[ "$role" == standby ]]; then
      spl_rsp_down "$d" "$tenant" "$box" "$agent" "$dry" || fails=$((fails + 1))
      continue
    fi
    if [[ "$role" == holder ]] && ! spl_desk_alive "$d/spool/.hub/hub-run.pid"; then
      spl_rsp_seat "$d" "$tenant" "$box" "$agent" "$dry" || { fails=$((fails + 1)); continue; }
    fi
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
  do_log "OK responder sweep ($ENV, $role): $swept/$seated tenant(s) handled, $fails failed"
  (( fails == 0 ))
}

# This machine's RSP box id: SPOOL_RSP_BOX in the box config, else box-rsp.
# The hub pins one key per (tenant, box), so a second machine answers from
# its own box id rather than a copy of another machine's key.
spl_rsp_box_default() {
  local f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}" k v r=""
  [[ "${SPOOL_TEST:-}" == 1 && -z "${SPOOL_BOX_ENV:-}" ]] && f=""
  if [[ -n "$f" && -r "$f" ]]; then
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
      [[ "$k" == SPOOL_RSP_BOX ]] || continue
      v="${v%$'\r'}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"; r="$v"
    done <"$f"
  fi
  [[ "$r" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || r="box-rsp"
  printf '%s' "$r"
}

# The role of this machine for the responder, from the dispatch lease (after
# spl_lease_init, spl_lease_conf, spl_lease_read): single | holder | standby | unknown.
spl_rsp_role() {
  if [[ "$LH" == none || "$LH" != *@* ]]; then echo single; return 0; fi
  if [[ "${LH##*@}" == unreachable || "${LH%@*}" == none ]] ||
     (( $(spl_lease_now) - LT > LEASE_STALE )); then echo unknown; return 0; fi
  if spl_lease_remote; then echo standby; else echo holder; fi
}

# spl_rsp_down <desk dir> <tenant> <box> <agent> <dry>: stop a standby's live
# RSP sidecar (do_spl_desk_down removes its pid file, so the desk reconcile
# leaves it down). A sidecar already down is left alone.
spl_rsp_down() {
  local d="$1" t="$2" b="$3" a="$4" dry="$5"
  spl_desk_alive "$d/spool/.hub/hub-run.pid" || return 0
  if (( dry )); then do_log "INFO DRY_RUN would: take down the $b sidecar of $t (standby)"; return 0; fi
  if TENANT_ID="$t" DESK_BOX="$b" DESK_AGENT="$a" DESK_ALL=1 DRY_RUN=0 do_spl_desk_down >/dev/null; then
    do_log "INFO $b sidecar of $t taken down: the lease holder $LH answers"
  else
    do_log "FAIL could not take down the $b sidecar of $t"; return 1
  fi
}

# spl_rsp_seat <desk dir> <tenant> <box> <agent> <dry>: the holder seats its
# RSP desk again. Only a desk already pinned (<desk>/pinned): the first pin
# needs the tenant root key, which is never fetched here.
spl_rsp_seat() {
  local d="$1" t="$2" b="$3" a="$4" dry="$5" rc=0
  [[ -s "$d/pinned" ]] || { do_log "FAIL $b of $t is not pinned: pin it first (do_spl_desk_pin)"; return 1; }
  if (( dry )); then do_log "INFO DRY_RUN would: seat $a on $b of $t (lease holder)"; return 0; fi
  exec 7>"$d/up-all.lock" || { do_log "FATAL cannot open $d/up-all.lock"; return 1; }
  if ! flock -n 7; then
    exec 7>&-; do_log "OK another reconcile holds $d/up-all.lock: it seats $b of $t"; return 0
  fi
  TENANT_ID="$t" DESK_BOX="$b" DESK_AGENT="$a" DESK_POKE=0 DESK_NOTIFY_CMD=off \
    DESK_WAIT_SECS="${DESK_WAIT_SECS:-30}" DRY_RUN=0 do_spl_desk_up >/dev/null || rc=1
  flock -u 7; exec 7>&-
  if (( rc )); then do_log "FAIL seating $a on $b of $t: see $d/spool/.hub/hub-run.log"; return 1; fi
  do_log "INFO $b sidecar of $t seated: this machine holds the lease"
}
