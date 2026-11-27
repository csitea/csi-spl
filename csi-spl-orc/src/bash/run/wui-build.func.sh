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
  local WUI_DIR=""
  # shellcheck source=wui-dev.func.sh
  declare -F _wui_prepare >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/wui-dev.func.sh" || return 1
  _wui_prepare || return 1
  do_log "INFO pnpm generate in $WUI_DIR"
  ( cd "$WUI_DIR" && pnpm generate ) || return 1
  [[ -d "$WUI_DIR/.output/public" ]] || { do_log "FATAL generate did not write .output/public"; return 1; }
  do_log "INFO generated $WUI_DIR/.output/public"
}
