#!/bin/bash
#------------------------------------------------------------------------------
# @description Stop and remove THIS tree's `wui` compose service only; the hub,
# @description Postgres and the GCS emulator keep running. Its named volumes
# @description (node_modules, .nuxt, pnpm store) are kept for a fast restart;
# @description LDE_PURGE=1 ./run -a do_teardown_app_inf drops them with the rest.
# @example ./run -a do_wui_down
#------------------------------------------------------------------------------
do_wui_down() {
  do_gen_docker_env || return 1
  lde_compose rm -s -f wui || return 1
  do_log "OK stopped the wui service of $LDE_COMPOSE_PROJECT"
}
