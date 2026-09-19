#!/bin/bash
#------------------------------------------------------------------------------
# @description Run the WUI in docker compose against THIS tree's lde hub: the
# @description `wui` service (src/docker/docker-compose-wui.yaml) is the Nuxt
# @description dev server with NUXT_PUBLIC_USE_MOCK=0 and NUXT_PUBLIC_API_BASE
# @description http://{tenant}.localhost:<hub port>. It mounts the WHOLE
# @description csi-spl-wui dir. The hub is (re)applied too, so a WUI port off
# @description the cnf default lands in the hub's CORS allow-list.
# @description Needs the stack from do_setup_app_inf (the hub image, pg, gcs).
# @description Waits until GET http://localhost:<wui port>/ answers 200.
# @description Stop it with do_wui_down, or everything with do_teardown_app_inf.
# @param LDE_WUI_PORT (optional) - host port, default cnf env.lde.wui.host_port
# @param LDE_HUB_PORT (optional) - must match the port do_setup_app_inf used
# @param LDE_WUI_READY_TIMEOUT (optional) - seconds to wait, default 300 (the
# @param   first run installs node_modules inside the container)
# @example ./run -a do_setup_app_inf && ./run -a do_wui_up
# @example LDE_PG_PORT=55433 LDE_GCS_PORT=54444 LDE_HUB_PORT=58081 LDE_WUI_PORT=3008 ./run -a do_wui_up
#------------------------------------------------------------------------------
do_wui_up() {
  do_require_bin docker curl || return 1
  do_gen_docker_env || return 1
  [[ -d "$LDE_WUI_SRC" ]] || { do_log "FATAL missing $LDE_WUI_SRC"; return 1; }
  docker image inspect "$LDE_HUB_IMAGE" >/dev/null 2>&1 ||
    { do_log "FATAL no hub image $LDE_HUB_IMAGE: run ./run -a do_setup_app_inf first"; return 1; }
  # the shadow-volume mount points: made here as the caller, or docker makes
  # them as root inside the checkout and a host `pnpm install` cannot write
  mkdir -p "$LDE_WUI_SRC/node_modules" "$LDE_WUI_SRC/.nuxt" || return 1
  do_log "INFO compose up hub + wui ($LDE_COMPOSE_PROJECT, wui image $LDE_WUI_IMAGE)"
  lde_compose up -d hub wui || { lde_compose ps; do_log "FATAL compose up hub wui failed"; return 1; }

  local url="http://localhost:$LDE_WUI_PORT/" code="" t
  for t in $(seq 1 "${LDE_WUI_READY_TIMEOUT:-300}"); do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url")
    [[ "$code" == 200 ]] && break
    sleep 1
  done
  [[ "$code" == 200 ]] || {
    lde_compose logs --tail 20 wui
    do_log "FATAL GET $url -> ${code:-none} after ${LDE_WUI_READY_TIMEOUT:-300}s"; return 1; }
  do_log "OK WUI $url (tenant $LDE_SMOKE_TENANT, hub http://$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT, mock off)"
}
