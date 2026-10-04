#!/bin/bash
#------------------------------------------------------------------------------
# @description Run the WUI in docker compose against THIS tree's lde hub: the
# @description `wui` service (src/docker/docker-compose-wui.yaml) is the Nuxt
# @description dev server, run offline from the tree's own node_modules as the
# @description tree's owner, with NUXT_PUBLIC_USE_MOCK=0 and NUXT_PUBLIC_API_BASE
# @description http://{tenant}.localhost:<hub port>. It mounts the WHOLE
# @description csi-spl-wui dir. The hub is (re)applied too, so a WUI port off
# @description the cnf default lands in the hub's CORS allow-list.
# @description Needs the stack from do_setup_app_inf (the hub image, pg, gcs).
# @description Waits until GET http://localhost:<wui port>/ answers 200.
# @description Stop it with do_wui_down, or everything with do_teardown_app_inf.
# @param LDE_WUI_PORT (optional) - host port, default cnf env.lde.wui.host_port
# @param LDE_HUB_PORT (optional) - must match the port do_setup_app_inf used
# @param LDE_WUI_READY_TIMEOUT (optional) - seconds to wait, default 300
# @param LDE_WUI_INSTALL (optional) - 1: when the tree has no node_modules,
# @param   pnpm install it in a one-shot container first (needs the registry;
# @param   the service itself never does)
# @param LDE_WUI_EXTRA_ORIGINS (optional) - more hub CORS origins (see do_gen_docker_env)
# @example ./run -a do_setup_app_inf && ./run -a do_wui_up
# @example LDE_PG_PORT=55433 LDE_GCS_PORT=54444 LDE_HUB_PORT=58081 LDE_WUI_PORT=3008 ./run -a do_wui_up
#------------------------------------------------------------------------------
do_wui_up() {
  do_require_bin docker curl || return 1
  do_gen_docker_env || return 1
  [[ -d "$LDE_WUI_SRC" ]] || { do_log "FATAL missing $LDE_WUI_SRC"; return 1; }
  docker image inspect "$LDE_HUB_IMAGE" >/dev/null 2>&1 ||
    { do_log "FATAL no hub image $LDE_HUB_IMAGE: run ./run -a do_setup_app_inf first"; return 1; }
  # The service starts the tree's own nuxt, offline. No node_modules: install
  # it once in a container (the only step that needs the registry) when asked.
  if [[ ! -f "$LDE_WUI_SRC/node_modules/nuxt/bin/nuxt.mjs" ]]; then
    [[ "${LDE_WUI_INSTALL:-0}" == 1 ]] || {
      do_log "FATAL $LDE_WUI_SRC has no node_modules: pnpm install there, or re-run with LDE_WUI_INSTALL=1"; return 1; }
    do_log "INFO LDE_WUI_INSTALL=1: pnpm install --frozen-lockfile in a one-shot container (needs the registry)"
    lde_compose --profile install run --rm --no-deps wui-install ||
      { do_log "FATAL the one-shot WUI install failed"; return 1; }
  fi
  [[ "$LDE_WUI_UID" != 0 ]] || { do_log "FATAL $LDE_WUI_SRC is owned by root: the wui container never runs as root"; return 1; }
  # a host listener on the WUI port (e.g. a leftover `nuxi dev`) makes the
  # container fail to bind with a bare "compose up failed": name it instead
  local holder
  if ! docker ps --filter "name=^${LDE_COMPOSE_PROJECT}-wui-1$" --filter status=running -q | grep . >/dev/null &&
     holder="$(ss -Hltnp "sport = :$LDE_WUI_PORT" 2>/dev/null)" && [[ -n "$holder" ]]; then
    do_log "FATAL 127.0.0.1:$LDE_WUI_PORT is already taken: $(tr -s ' ' <<<"$holder" | cut -d' ' -f4,6-) -- stop it, or pick another port with LDE_WUI_PORT"
    return 1
  fi
  do_log "INFO compose up hub + wui ($LDE_COMPOSE_PROJECT, wui image $LDE_WUI_IMAGE)"
  lde_compose up -d hub wui || { lde_compose ps; do_log "FATAL compose up hub wui failed"; return 1; }

  # volumes of the pre-offline service (node_modules/.nuxt/pnpm store shadows)
  local v
  for v in wui-node-modules wui-nuxt wui-output wui-pnpm-store; do
    docker volume rm "${LDE_COMPOSE_PROJECT}_$v" >/dev/null 2>&1 && do_log "INFO removed legacy volume ${LDE_COMPOSE_PROJECT}_$v"
  done

  local url="http://localhost:$LDE_WUI_PORT/" code=""
  # `seq 1 <non-integer>` ran 0 tries; a bare name in (( )) would instead abort
  # ./run under set -u, so a non-integer still means 0 tries (base 10, as seq)
  local tries="${LDE_WUI_READY_TIMEOUT:-300}" i
  [[ "$tries" =~ ^[0-9]+$ ]] || tries=0
  for ((i = 1; i <= 10#$tries; i++)); do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url")
    [[ "$code" == 200 ]] && break
    sleep 1
  done
  [[ "$code" == 200 ]] || {
    lde_compose logs --tail 20 wui
    do_log "FATAL GET $url -> ${code:-none} after ${LDE_WUI_READY_TIMEOUT:-300}s"; return 1; }
  do_log "OK WUI $url (tenant $LDE_SMOKE_TENANT, hub http://$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT, mock off)"
}
