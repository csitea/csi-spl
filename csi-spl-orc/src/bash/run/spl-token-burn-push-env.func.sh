#!/bin/bash
#------------------------------------------------------------------------------
# @description Resolve the hub settings the token burn push uses (the lane
# @description map's: spl_lane_init) once, into <TOKEN_BURN_STATE_DIR>/push.env,
# @description so the 30 s collector tick does not pay for it. Paths and the
# @description hub URL only, no key. The cron wrapper refreshes it hourly.
# @param TOKEN_BURN_STATE_DIR (optional) - default <SPL_VAR_APP_DIR>/token-burn
# @param   (SPL_VAR_APP_DIR, spl_run_paths)
# @example ./run -a do_spl_token_burn_push_env
#------------------------------------------------------------------------------
declare -F spl_token_burn_state_dir >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-token-burn-collect.func.sh"

do_spl_token_burn_push_env() {
  local dir
  spl_token_burn_state_dir dir || return 1
  declare -F spl_lane_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"
  spl_lane_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "FATAL the token burn lives on the hub: set LANE_FLEET (or LEASE_FLEET in lease.conf)"; return 1; }
  mkdir -p "$dir" || return 1
  ( umask 077
    printf 'SPOOL_ROOT=%s\nSPOOL_KEYS_DIR=%s\nSPOOL_BOX_ID=%s\nSPOOL_HUB_URL=%s\nSPOOL_TENANT=%s\nSPL_SPOOL=%s\n' \
      "$LANE_DESK_DIR/spool" "$LANE_DESK_DIR/keys" "$LANE_DESK_BOX" "$SPL_HUB_URL" "$LANE_TENANT" "$SPL_SPOOL" >"$dir/push.env.$$" ) &&
    mv -f "$dir/push.env.$$" "$dir/push.env" || { rm -f "$dir/push.env.$$"; return 1; }
  do_log "OK wrote $dir/push.env (desk $LANE_DESK_BOX of $LANE_TENANT)"
}
