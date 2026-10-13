#!/bin/bash
#------------------------------------------------------------------------------
# @description Stop the private local hub (docker compose down on the hub
# @description user's rootless daemon), as the hub user. The data volumes are
# @description KEPT. LOCAL_HUB_PURGE=1 with DRY_RUN=0 also removes them: the
# @description workspace's data is gone, so take a backup first; the
# @description workspace stamp and root key in the state dir go with it.
# @param LOCAL_HUB_PURGE (optional) - 1: also remove the volumes (needs DRY_RUN=0)
# @param DRY_RUN (optional) - with LOCAL_HUB_PURGE=1: 1 (default) only says so
# @example ./run -a do_spl_local_hub_down
# @example LOCAL_HUB_PURGE=1 DRY_RUN=0 ./run -a do_spl_local_hub_down
#------------------------------------------------------------------------------
do_spl_local_hub_down() {
  spl_local_hub_cnf || return 1
  if ! spl_local_hub_is_user; then spl_local_hub_reexec do_spl_local_hub_down; return; fi
  spl_local_hub_env && do_gen_docker_env || return 1
  local args=(down --remove-orphans)
  if [[ "${LOCAL_HUB_PURGE:-0}" == 1 ]]; then
    [[ "${DRY_RUN:-1}" == 0 ]] || {
      do_log "WARN DRY_RUN: LOCAL_HUB_PURGE=1 would REMOVE the workspace's volumes; re-run with DRY_RUN=0"; return 0; }
    args+=(-v)
  fi
  lde_compose "${args[@]}" || return 1
  [[ " ${args[*]} " == *" -v "* ]] && rm -rf "${LDE_STATE_DIR:?}/tenant"
  do_log "OK stopped $LDE_COMPOSE_PROJECT$([[ " ${args[*]} " == *" -v "* ]] && echo ' and REMOVED its volumes')"
}
