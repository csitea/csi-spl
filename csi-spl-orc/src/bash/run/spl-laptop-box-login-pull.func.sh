#!/bin/bash
#------------------------------------------------------------------------------
# @description On a laptop box: pull the fleet's Claude login from the move
# @description box, newer only (SPL-6680, spec 037 "Laptop box"; owner Q1 =
# @description PUL). It is do_spl_agent_cred_sync, source = the move box
# @description (LAPTOP_MOVE_BOX), target = this box, its peer reached by
# @description laptop-login-peer.sh with the laptop's own key, which the move
# @description box serves read-only (do_spl_laptop_box_login_grant). Every
# @description guard of the sync holds: newer only, the account label, the
# @description backup, the headless proof after a copy. Run by the
# @description spl-laptop-box-login.timer as the agents' user.
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param LAPTOP_ENV_FILE (optional) - her config, default /etc/spl-laptop-box/laptop-box.env (root's)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param LAPTOP_SYNC_CMD (tests) - the sync, default do_spl_agent_cred_sync
# @example ./run -a do_spl_laptop_box_login_pull
# @example DRY_RUN=0 ./run -a do_spl_laptop_box_login_pull
#------------------------------------------------------------------------------
do_spl_laptop_box_login_pull() {
  local envf="${LAPTOP_ENV_FILE:-/etc/spl-laptop-box/laptop-box.env}" tag to dest
  [[ -r "$envf" ]] || { do_log "FATAL $envf is missing: not a laptop box"; return 3; }
  tag="$(spl_laptop_env_get "$envf" LAPTOP_BOX_TAG)"; to="$(spl_laptop_env_get "$envf" LAPTOP_MOVE_BOX)"
  dest="$(spl_laptop_env_get "$envf" LAPTOP_MOVE_SSH)"
  spl_laptop_box_tag_ok "$tag" && spl_laptop_box_tag_ok "$to" || { do_log "FATAL LAPTOP_BOX_TAG / LAPTOP_MOVE_BOX in $envf are not box tags"; return 3; }
  [[ "$dest" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] || { do_log "FATAL LAPTOP_MOVE_SSH in $envf must be <user>@<host> (install --move-ssh), got '$dest'"; return 3; }
  CRED_VENDOR=claude CRED_SRC_BOX="$to" CRED_DST_BOX="$tag" CRED_PEERS="$to=$dest" SPOOL_BOX_TAG="$tag" \
    CRED_PEER_CMD="bash $PROJ_PATH/src/bash/features/laptop-box/laptop-login-peer.sh" \
    ${LAPTOP_SYNC_CMD:-do_spl_agent_cred_sync}
}
