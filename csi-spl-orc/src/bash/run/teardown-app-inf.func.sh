#!/bin/bash
#------------------------------------------------------------------------------
# @description Stop THIS tree's local stack (docker compose down). Data
# @description volumes (Postgres, GCS emulator) are kept unless LDE_PURGE=1.
# @description Never touches another tree's project or anything in the cloud.
# @param LDE_PURGE (optional) - 1: also remove the volumes (a clean database)
# @example ./run -a do_teardown_app_inf
# @example LDE_PURGE=1 ./run -a do_teardown_app_inf
#------------------------------------------------------------------------------
do_teardown_app_inf() {
  do_gen_docker_env || return 1
  local args=(down --remove-orphans)
  [[ "${LDE_PURGE:-0}" == 1 ]] && args+=(-v)
  lde_compose "${args[@]}" || return 1
  do_log "OK stopped $LDE_COMPOSE_PROJECT$([[ "${LDE_PURGE:-0}" == 1 ]] && echo ' and removed its volumes')"
}
