#!/bin/bash
#------------------------------------------------------------------------------
# @description Start the spool WUI local-dev server (Nuxt 3, port from cnf
# @description env.lde.wui.host_port, default 3000). Points NUXT_PUBLIC_API_BASE
# @description at the lde hub unless the caller already set it. Uses the mock
# @description roster/feed until the hub grows the WUI session API (M3).
# @example ./run -a do_wui_dev
# @example NUXT_PUBLIC_USE_MOCK=0 ./run -a do_wui_dev
#------------------------------------------------------------------------------
do_wui_dev() {
  do_lde_cnf || return 1
  do_require_bin pnpm || return 1
  local wui="$APP_PATH/csi-spl-wui"
  [[ -d "$wui" ]] || { do_log "FATAL missing $wui"; return 1; }
  if [[ ! -d "$wui/node_modules" ]]; then
    do_log "INFO pnpm install in $wui"
    ( cd "$wui" && pnpm install ) || return 1
  fi
  # a {tenant} template: the hub answers 404 unknown_tenant on a bare host
  : "${NUXT_PUBLIC_API_BASE:=http://{tenant}.localhost:${LDE_HUB_PORT}}"
  : "${NUXT_PUBLIC_USE_MOCK:=1}"
  export NUXT_PUBLIC_API_BASE NUXT_PUBLIC_USE_MOCK
  do_log "INFO WUI lde on 0.0.0.0:${LDE_WUI_PORT} api=$NUXT_PUBLIC_API_BASE mock=$NUXT_PUBLIC_USE_MOCK"
  ( cd "$wui" && pnpm dev --host 0.0.0.0 --port "$LDE_WUI_PORT" )
}
