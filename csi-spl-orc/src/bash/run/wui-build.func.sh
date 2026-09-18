#!/bin/bash
#------------------------------------------------------------------------------
# @description Generate the static WUI into csi-spl-wui/.output/public for
# @description Firebase Hosting (`pnpm generate`). Does not deploy. Does not
# @description mutate GCP. NUXT_PUBLIC_API_BASE should be the same-origin
# @description prefix the Hosting rewrite will serve (/v1 on the site).
# @example ./run -a do_wui_build
# @example NUXT_PUBLIC_API_BASE= ./run -a do_wui_build
#------------------------------------------------------------------------------
do_wui_build() {
  do_require_bin pnpm || return 1
  local wui="$APP_PATH/csi-spl-wui"
  [[ -d "$wui" ]] || { do_log "FATAL missing $wui"; return 1; }
  if [[ ! -d "$wui/node_modules" ]]; then
    do_log "INFO pnpm install in $wui"
    ( cd "$wui" && pnpm install ) || return 1
  fi
  do_log "INFO pnpm generate in $wui"
  ( cd "$wui" && pnpm generate ) || return 1
  [[ -d "$wui/.output/public" ]] || { do_log "FATAL generate did not write .output/public"; return 1; }
  do_log "INFO generated $wui/.output/public"
}
