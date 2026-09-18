#!/bin/bash
#------------------------------------------------------------------------------
# @description Run the WUI unit tests (`pnpm test:unit`) and typecheck.
# @example ./run -a do_wui_test
#------------------------------------------------------------------------------
do_wui_test() {
  do_require_bin pnpm || return 1
  local wui="$APP_PATH/csi-spl-wui"
  [[ -d "$wui" ]] || { do_log "FATAL missing $wui"; return 1; }
  if [[ ! -d "$wui/node_modules" ]]; then
    do_log "INFO pnpm install in $wui"
    ( cd "$wui" && pnpm install ) || return 1
  fi
  ( cd "$wui" && pnpm test:unit ) || return 1
  ( cd "$wui" && pnpm typecheck ) || return 1
}
