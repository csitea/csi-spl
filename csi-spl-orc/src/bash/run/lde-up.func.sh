#!/bin/bash
#------------------------------------------------------------------------------
# @description lde-up: THIS tree's whole contributor dev stack in one command,
# @description with Docker as the only host tool (spec 072 A46): the hub stack
# @description (do_setup_app_inf: hub built in docker, pg, gcs, migrate, smoke),
# @description then the WUI (do_wui_up, installing node_modules in a one-shot
# @description container on the first run), then the URLs. Native sign-in is ON
# @description by default here (mail `log`, the token comes back in the body),
# @description so a human can register and post on the default stack; it is
# @description exported once, so both steps render the same hub.env.
# @description Exit: 0 hub + WUI up; 1 a step failed. A hub smoke with BLOCKED
# @description checks (exit 3) still brings the WUI up, with a WARN.
# @description Stop it with do_lde_down.
# @param LDE_AUTH_NATIVE (optional) - default 1 here; 0 turns sign-in off
# @param LDE_WUI_INSTALL (optional) - default 1 here; 0 refuses to install node_modules
# @param LDE_PG_PORT / LDE_GCS_PORT / LDE_HUB_PORT / LDE_WUI_PORT (optional) - host ports (two trees at once)
# @example ./run -a do_lde_up
# @example LDE_HUB_PORT=58081 LDE_WUI_PORT=3008 LDE_PG_PORT=55433 LDE_GCS_PORT=54444 ./run -a do_lde_up
#------------------------------------------------------------------------------
do_lde_up() {
  export LDE_AUTH_NATIVE="${LDE_AUTH_NATIVE:-1}" LDE_WUI_INSTALL="${LDE_WUI_INSTALL:-1}"
  local rc=0
  do_setup_app_inf || rc=$?
  case "$rc" in
    0) ;;
    3) do_log "WARN lde-up: the hub smoke has BLOCKED checks; bringing the WUI up anyway" ;;
    *) do_log "FATAL lde-up: do_setup_app_inf exit $rc"; return 1 ;;
  esac
  do_wui_up || { do_log "FATAL lde-up: do_wui_up failed"; return 1; }
  local signin=off
  [[ "$LDE_AUTH_NATIVE" == 1 ]] && signin="on (email + password; mail log: the token is in the response body)"
  printf '\n  wui      http://localhost:%s/\n  hub      http://%s.localhost:%s/healthz\n  sign-in  %s\n  stop     ./run -a do_lde_down   (LDE_PURGE=1: also the data volumes)\n\n' \
    "$LDE_WUI_PORT" "$LDE_SMOKE_TENANT" "$LDE_HUB_PORT" "$signin"
  do_log "OK lde-up: $LDE_COMPOSE_PROJECT is up"
}
