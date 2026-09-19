#!/bin/bash
#------------------------------------------------------------------------------
# @description Stop and remove THIS tree's `wui` compose service only; the hub,
# @description Postgres and the GCS emulator keep running. The service keeps
# @description no volume: node_modules and .nuxt are the tree's own files.
# @example ./run -a do_wui_down
#------------------------------------------------------------------------------
do_wui_down() {
  do_gen_docker_env || return 1
  lde_compose rm -s -f wui || return 1
  do_log "OK stopped the wui service of $LDE_COMPOSE_PROJECT"
}
