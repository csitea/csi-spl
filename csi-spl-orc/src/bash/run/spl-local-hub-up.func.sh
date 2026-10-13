#!/bin/bash
#------------------------------------------------------------------------------
# @description Bring the private local hub up: hub + Postgres + GCS emulator +
# @description the generated WUI (+ the backup job and the encrypted pg volume
# @description when their overlays are present), all in docker compose on the
# @description hub user's ROOTLESS daemon, every port on 127.0.0.1. No cloud.
# @description Run by any operator: it re-executes itself as the hub user
# @description (cnf env.lde.local_hub.user) in that user's long-lived tree.
# @description   1. render the env, then the host hardening check
# @description      (do_spl_local_hub_harden_check reads the compose config)
# @description   2. build every overlay image (lde_compose build)
# @description   3. the lde hub stack and its smoke (do_setup_app_inf) against
# @description      the smoke tenant; an encrypted pg is unlocked on the way
# @description      (do_spl_local_hub_unlock: the owner types the passphrase)
# @description   4. the workspace: created once from the private config, its
# @description      root key kept in the state dir (0600)
# @description   5. the WUI: generate (when the tree moved) and serve
# @description   6. the backup job, once its key exists (else a WARN)
# @description Sign-up is closed: the owner's account comes from
# @description do_spl_local_hub_owner_add, which _up only prints.
# @description Exit: 0 up; 1 a step failed.
# @param LOCAL_HUB_* (optional) - see lib/bash/funcs/spl-local-hub.func.sh
# @example ./run -a do_spl_local_hub_up
#------------------------------------------------------------------------------
do_spl_local_hub_up() {
  spl_local_hub_cnf || return 1
  if ! spl_local_hub_is_user; then spl_local_hub_reexec do_spl_local_hub_up; return; fi
  do_require_bin docker curl yq || return 1
  spl_local_hub_env || return 1
  do_gen_docker_env || return 1
  _slh_harden || return 1
  lde_compose build -q || { do_log "FATAL lde_compose build failed"; return 1; }
  do_setup_app_inf || { do_log "FATAL the hub stack is not green (do_setup_app_inf exit $?)"; return 1; }
  _slh_tenant || return 1
  _slh_wui || return 1
  _slh_backup || return 1
  printf '\n  wui     http://localhost:%s/\n  owner   DRY_RUN=0 ./run -a do_spl_local_hub_owner_add   (once, on the owner'"'"'s terminal)\n  status  ./run -a do_spl_local_hub_status\n  stop    ./run -a do_spl_local_hub_down\n\n' "$LDE_WUI_PORT"
  do_log "OK local hub $LDE_COMPOSE_PROJECT is up"
}

# _slh_backup -- start the daily backup job, but only once its key exists
# (do_spl_local_hub_backup_check): without one the job crash-loops, and a
# looping container fails the next hardening check. A WARN says why not.
_slh_backup() {
  if ! _slh_has_service backup; then
    do_log "WARN no backup service (docker-compose-local-hub-backup.yaml): NO daily backup runs"; return 0
  fi
  if declare -F do_spl_local_hub_backup_check >/dev/null && ! do_spl_local_hub_backup_check; then
    lde_compose rm -sf backup >/dev/null
    do_log "WARN no backup key yet: the backup job is NOT started, NO daily backup runs; run ./run -a do_spl_local_hub_backup_keygen once"
    return 0
  fi
  lde_compose up -d backup >/dev/null || { do_log "FATAL the backup job did not start"; return 1; }
}

# _slh_has_service <name> -- an overlay defines the compose service.
_slh_has_service() {
  lde_compose config --services 2>/dev/null | grep -x "$1" >/dev/null
}

# _slh_harden -- L5's host check when it is installed; a FAIL stops _up. The
# e2e on the system daemon (the same escape as spl_local_hub_docker_host: the
# flag AND an ^e2e- workspace) runs as an agent user the check refuses by
# design, so there it is skipped, loudly.
_slh_harden() {
  if [[ "${LOCAL_HUB_ALLOW_SYSTEM_DOCKER:-0}" == 1 && "$LOCAL_HUB_TENANT" == e2e-* ]]; then
    do_log "WARN throwaway e2e workspace on the system daemon: the hardening check is NOT run"; return 0
  fi
  if ! declare -F do_spl_local_hub_harden_check >/dev/null; then
    do_log "WARN do_spl_local_hub_harden_check is not on this tree: the host is NOT checked"; return 0
  fi
  do_spl_local_hub_harden_check || { do_log "FATAL the hardening check failed: nothing was started"; return 1; }
}

# _slh_spool <args...> -- the hub image's `spool`, inside the compose network,
# as the daemon's uid 0 (= the hub user on a rootless daemon), the state dir
# mounted at its own path.
_slh_spool() {
  lde_compose run --rm --no-deps -T -u 0:0 -v "$LDE_STATE_DIR:$LDE_STATE_DIR" \
    --entrypoint /usr/local/bin/spool hub "$@"
}

# _slh_tenant -- the workspace, once: a root key in $LDE_STATE_DIR/tenant
# (0700/0600), then `spool hub-tenant`. A stamp holding the tenant makes it
# idempotent; a different tenant on the same state dir is refused.
_slh_tenant() {
  local d="$LDE_STATE_DIR/tenant" out
  local dsn="postgres://$LDE_PG_USER:$LDE_PG_PASSWORD@pg:5432/$LDE_PG_DB?sslmode=disable"
  (umask 077; mkdir -p "$d") || return 1
  if [[ -s "$d/created" ]]; then
    [[ "$(<"$d/created")" == "$LOCAL_HUB_TENANT" ]] && { do_log "INFO the workspace exists"; return 0; }
    do_log "FATAL $d/created names another workspace than the private config"; return 1
  fi
  if [[ ! -s "$d/root.pub" ]]; then
    (umask 077; _slh_spool root-keygen --out "$d/root.key" >"$d/root.pub") ||
      { do_log "FATAL root-keygen failed"; return 1; }
  fi
  out=$(_slh_spool hub-tenant --tenant "$LOCAL_HUB_TENANT" --root-pubkey "$(tail -1 "$d/root.pub")" --db "$dsn" 2>&1) ||
    { do_log "FATAL hub-tenant: $(tail -2 <<<"$out" | tr '\n' ' ')"; return 1; }
  (umask 077; printf '%s\n' "$LOCAL_HUB_TENANT" >"$d/created")
  do_log "OK the workspace is created (root key in $d, 0600)"
}

# _slh_wui -- L2's generated WUI: generate when the tree's HEAD differs from
# the stamp, serve, wait for 200. Without the overlay: the lde dev WUI.
_slh_wui() {
  if ! _slh_has_service wui-static; then
    do_log "WARN no wui-static (docker-compose-local-hub.yaml): serving the lde dev WUI"
    do_wui_up; return
  fi
  local head stamp="$LDE_STATE_DIR/wui-generated" url="http://localhost:$LDE_WUI_PORT/" code="" i
  head="$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null)"
  if [[ ! -s "$stamp" || "$(<"$stamp")" != "$head" ]]; then
    do_log "INFO generating the WUI for $head"
    lde_compose --profile local-hub-build run --rm --no-deps wui-generate || { do_log "FATAL wui-generate failed"; return 1; }
    printf '%s\n' "$head" >"$stamp"
  fi
  lde_compose up -d wui-static >/dev/null || { do_log "FATAL wui-static did not start"; return 1; }
  for ((i = 0; i < ${LOCAL_HUB_WUI_READY_TIMEOUT:-60}; i++)); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url") && [[ "$code" == 200 ]] && break
    sleep 1
  done
  [[ "$code" == 200 ]] || { do_log "FATAL GET $url -> ${code:-none}"; return 1; }
  do_log "OK WUI $url"
}
