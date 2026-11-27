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
  local WUI_DIR=""
  _wui_prepare || return 1
  # a {tenant} template: the hub answers 404 unknown_tenant on a bare host
  : "${NUXT_PUBLIC_API_BASE:=http://{tenant}.localhost:${LDE_HUB_PORT}}"
  : "${NUXT_PUBLIC_USE_MOCK:=1}"
  export NUXT_PUBLIC_API_BASE NUXT_PUBLIC_USE_MOCK
  do_log "INFO WUI lde on 0.0.0.0:${LDE_WUI_PORT} api=$NUXT_PUBLIC_API_BASE mock=$NUXT_PUBLIC_USE_MOCK"
  ( cd "$WUI_DIR" && pnpm dev --host 0.0.0.0 --port "$LDE_WUI_PORT" )
}

# _wui_prepare: check pnpm and $APP_PATH/csi-spl-wui exist, run pnpm install
# when node_modules is absent, and set WUI_DIR for the caller.
_wui_prepare() {
  do_require_bin pnpm || return 1
  WUI_DIR="$APP_PATH/csi-spl-wui"
  [[ -d "$WUI_DIR" ]] || { do_log "FATAL missing $WUI_DIR"; return 1; }
  if [[ ! -d "$WUI_DIR/node_modules" ]]; then
    do_log "INFO pnpm install in $WUI_DIR"
    ( cd "$WUI_DIR" && pnpm install ) || return 1
  fi
}
