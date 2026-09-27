#!/bin/bash
#------------------------------------------------------------------------------
# @description Keep the desk of EVERY tenant on this box up, not only the main
# @description one the reconcile cron names. The cron ran do_spl_desk_up_all
# @description for one tenant (t1), so a customer tenant's sidecar that died
# @description stayed dead: on prd 2026-09-27 the csi-rel sidecar stopped at
# @description 11:47:54Z and a person's post waited queued until a new agent
# @description was seated at 12:28:12Z (SPL-1004; owner answer "a", csi-rel
# @description topic 39e4d87a: the cron covers the sidecars of all tenants).
# @description For each tenant dir under $SPL_STATE_DIR/desk that has DESK_BOX,
# @description except the ones in DESK_SKIP_TENANTS, it runs do_spl_desk_up_all
# @description with DESK_SEATED_ONLY=1 (re-seat the live agents already seated
# @description there, which restarts a dead or stale sidecar; never seat a new
# @description one), DESK_RETIRE=0 (a customer desk keeps its dirs) and
# @description DESK_HUB_CHECK=0 (the roster probe account is a t1 member; a
# @description stranded socket is the sidecar's own session probe's job). A seat
# @description muted by hand (.no-poke) stays muted.
# @description Prints one line per tenant. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param DESK_BOX (optional) - default box-desk
# @param DESK_SKIP_TENANTS (optional) - space-separated tenant slugs to leave
# @param   out, e.g. the main tenant the cron has just reconciled
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd DESK_SKIP_TENANTS=t1 DRY_RUN=0 ./run -a do_spl_desk_up_tenants
#------------------------------------------------------------------------------
do_spl_desk_up_tenants() {
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local box="${DESK_BOX:-box-desk}" skip=" ${DESK_SKIP_TENANTS:-} " t dir rc=0 n=0
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  for dir in "$SPL_STATE_DIR"/desk/*/; do
    t="${dir%/}"; t="${t##*/}"
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && -d "$dir$box/spool" ]] || continue
    [[ "$skip" == *" $t "* ]] && continue
    n=$((n + 1))
    if ( TENANT_ID="$t" DESK_BOX="$box" DESK_SEATED_ONLY=1 DESK_RETIRE=0 DESK_HUB_CHECK=0 \
         DRY_RUN="$( ((dry)) && echo 1 || echo 0)" do_spl_desk_up_all ); then
      do_log "INFO desk of $t: reconciled"
    else
      rc=1; do_log "FAIL desk of $t: do_spl_desk_up_all failed"
    fi
  done
  do_log "OK reconciled the desks of $n tenant(s) other than:${skip% }"
  return "$rc"
}
