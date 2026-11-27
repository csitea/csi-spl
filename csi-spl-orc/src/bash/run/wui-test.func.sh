#!/bin/bash
#------------------------------------------------------------------------------
# @description Run the WUI unit tests (`pnpm test:unit`) and typecheck.
# @example ./run -a do_wui_test
#------------------------------------------------------------------------------
do_wui_test() {
  local WUI_DIR=""
  # shellcheck source=wui-dev.func.sh
  declare -F _wui_prepare >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/wui-dev.func.sh" || return 1
  _wui_prepare || return 1
  ( cd "$WUI_DIR" && pnpm test:unit ) || return 1
  ( cd "$WUI_DIR" && pnpm typecheck ) || return 1
}
