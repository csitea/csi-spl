#!/bin/bash
#------------------------------------------------------------------------------
# @description The private local hub's shared settings (do_spl_local_hub_up and
# @description every spl-local-hub-* action): the lde stack, run by ONE
# @description dedicated system user from its own long-lived clone, on that
# @description user's ROOTLESS docker daemon, every port on 127.0.0.1.
# @description
# @description   spl_local_hub_cnf          LOCAL_HUB_* from cnf env.lde.local_hub
# @description                              (the caller's env wins)
# @description   spl_local_hub_private_cnf  LOCAL_HUB_TENANT (+ OWNER_EMAIL) from the
# @description                              user's private config, never from git
# @description   spl_local_hub_env          both, then the LDE_* the lde actions read
# @description   spl_local_hub_reexec       run an action as the hub user, in its tree
# @description
# @description The workspace (tenant) name lives ONLY in the private config
# @description ($LOCAL_HUB_HOME/.config/<org>-<app>/local-hub.env, mode 0600, one
# @description KEY=value per line); nothing in git names it.
# @param LOCAL_HUB_USER / LOCAL_HUB_HOME / LOCAL_HUB_TREE / LOCAL_HUB_CONFIG (optional)
# @param LOCAL_HUB_PROJECT / LOCAL_HUB_{PG,GCS,HUB,WUI}_PORT (optional) - a
# @param   second instance (the e2e) beside the long-lived one
# @param LOCAL_HUB_DOCKER_HOST (optional) - default the caller's rootless socket
# @param LOCAL_HUB_ALLOW_SYSTEM_DOCKER (optional) - 1: allow the system daemon,
# @param   honoured only for a throwaway tenant matching ^e2e-
#------------------------------------------------------------------------------

# spl_local_hub_cnf -- export LOCAL_HUB_* from cnf env.lde.local_hub.
spl_local_hub_cnf() {
  local ns="${PROJ_PATH:?PROJ_PATH unset}"
  ns="${ns##*/}"; ns="${ns%-orc}"
  local f="${APP_PATH:?APP_PATH unset}/$ns-cnf/$ns/lde.env.yaml" v
  [[ -f "$f" ]] || { do_log "FATAL missing $f"; return 1; }
  _slh_get() { yq -r ".env.lde.local_hub.$1 // \"\"" "$f"; }
  LOCAL_HUB_USER="${LOCAL_HUB_USER:-$(_slh_get user)}"
  LOCAL_HUB_HOME="${LOCAL_HUB_HOME:-$(_slh_get home)}"
  LOCAL_HUB_PROJECT="${LOCAL_HUB_PROJECT:-$(_slh_get compose_project)}"
  LOCAL_HUB_SMOKE_TENANT="$(_slh_get smoke_tenant)"
  LOCAL_HUB_PG_PORT="${LOCAL_HUB_PG_PORT:-$(_slh_get pg_port)}"
  LOCAL_HUB_GCS_PORT="${LOCAL_HUB_GCS_PORT:-$(_slh_get gcs_port)}"
  LOCAL_HUB_HUB_PORT="${LOCAL_HUB_HUB_PORT:-$(_slh_get hub_port)}"
  LOCAL_HUB_WUI_PORT="${LOCAL_HUB_WUI_PORT:-$(_slh_get wui_port)}"
  unset -f _slh_get
  LOCAL_HUB_TREE="${LOCAL_HUB_TREE:-$LOCAL_HUB_HOME/$ns}"
  LOCAL_HUB_CONFIG="${LOCAL_HUB_CONFIG:-$LOCAL_HUB_HOME/.config/$ns/local-hub.env}"
  for v in LOCAL_HUB_USER LOCAL_HUB_HOME LOCAL_HUB_PROJECT LOCAL_HUB_SMOKE_TENANT \
           LOCAL_HUB_PG_PORT LOCAL_HUB_GCS_PORT LOCAL_HUB_HUB_PORT LOCAL_HUB_WUI_PORT; do
    [[ -n "${!v}" && "${!v}" != null ]] || { do_log "FATAL $v is empty: check env.lde.local_hub in $f"; return 1; }
  done
  [[ "$LOCAL_HUB_HOME" == /* ]] || { do_log "FATAL LOCAL_HUB_HOME must be absolute, got: $LOCAL_HUB_HOME"; return 1; }
  export LOCAL_HUB_USER LOCAL_HUB_HOME LOCAL_HUB_PROJECT LOCAL_HUB_SMOKE_TENANT LOCAL_HUB_PG_PORT \
    LOCAL_HUB_GCS_PORT LOCAL_HUB_HUB_PORT LOCAL_HUB_WUI_PORT LOCAL_HUB_TREE LOCAL_HUB_CONFIG
}

# spl_local_hub_private_cnf -- LOCAL_HUB_TENANT (required) and
# LOCAL_HUB_OWNER_EMAIL (optional) from $LOCAL_HUB_CONFIG: owned by the
# caller, mode 0600, KEY=value lines; an unknown key is a typo, refused. The
# file is parsed, never sourced. The values are never logged.
spl_local_hub_private_cnf() {
  local f="$LOCAL_HUB_CONFIG" line k v mode
  [[ -f "$f" ]] || { do_log "FATAL no private config $f: write LOCAL_HUB_TENANT=<workspace> there (mode 0600)"; return 1; }
  [[ -O "$f" ]] || { do_log "FATAL $f is not owned by $(id -un)"; return 1; }
  mode="$(stat -c %a "$f")"
  [[ "$mode" == 600 || "$mode" == 400 ]] || { do_log "FATAL $f has mode $mode: it must be 0600"; return 1; }
  LOCAL_HUB_TENANT="" LOCAL_HUB_OWNER_EMAIL=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    k="${line%%=*}" v="${line#*=}"
    v="${v%\"}"; v="${v#\"}"
    case "$k" in
      LOCAL_HUB_TENANT) LOCAL_HUB_TENANT="$v" ;;
      LOCAL_HUB_OWNER_EMAIL) LOCAL_HUB_OWNER_EMAIL="$v" ;;
      *) do_log "FATAL $f: unknown key '$k' (LOCAL_HUB_TENANT, LOCAL_HUB_OWNER_EMAIL)"; return 1 ;;
    esac
  done <"$f"
  [[ "$LOCAL_HUB_TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
    { do_log "FATAL $f: LOCAL_HUB_TENANT must match ^[a-z0-9][a-z0-9-]{0,31}\$"; return 1; }
  [[ "$LOCAL_HUB_TENANT" != "$LOCAL_HUB_SMOKE_TENANT" ]] ||
    { do_log "FATAL $f: LOCAL_HUB_TENANT must not be the smoke tenant"; return 1; }
  export LOCAL_HUB_TENANT LOCAL_HUB_OWNER_EMAIL
}

# spl_local_hub_docker_host -- DOCKER_HOST = the caller's rootless daemon. The
# system daemon is refused: its docker group is root-equivalent, so every
# member could read the workspace's volumes.
spl_local_hub_docker_host() {
  local host="${LOCAL_HUB_DOCKER_HOST:-unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock}"
  local sock="${host#unix://}"
  if [[ "$sock" == /var/run/docker.sock || "$sock" == /run/docker.sock ]]; then
    [[ "${LOCAL_HUB_ALLOW_SYSTEM_DOCKER:-0}" == 1 && "$LOCAL_HUB_TENANT" == e2e-* ]] || {
      do_log "FATAL $host is the system docker daemon: the local hub runs on its user's rootless daemon (do_spl_local_hub_install)"
      return 1; }
  fi
  [[ "$host" != unix://* || -S "$sock" ]] ||
    { do_log "FATAL no docker socket at $sock: start the rootless daemon (do_spl_local_hub_install)"; return 1; }
  export DOCKER_HOST="$host"
}

# spl_local_hub_env -- everything the lde actions need for the local hub.
spl_local_hub_env() {
  spl_local_hub_cnf && spl_local_hub_private_cnf && spl_local_hub_docker_host || return 1
  local d="$PROJ_PATH/src/docker" f extra=()
  for f in docker-compose-local-hub.yaml docker-compose-local-hub-vault.yaml docker-compose-local-hub-backup.yaml; do
    [[ -f "$d/$f" ]] && extra+=("$d/$f")
  done
  export LDE_STATE_DIR="$LOCAL_HUB_HOME/state" LDE_COMPOSE_PROJECT_NAME="$LOCAL_HUB_PROJECT" \
    LDE_PG_PORT="$LOCAL_HUB_PG_PORT" LDE_GCS_PORT="$LOCAL_HUB_GCS_PORT" \
    LDE_HUB_PORT="$LOCAL_HUB_HUB_PORT" LDE_WUI_PORT="$LOCAL_HUB_WUI_PORT" \
    LDE_SMOKE_TENANT="$LOCAL_HUB_SMOKE_TENANT" LDE_WUI_TENANT="$LOCAL_HUB_TENANT" \
    LDE_AUTH_NATIVE=1 LDE_AUTH_PROVIDERS="" LDE_WUI_DISPATCH=0 \
    LDE_HUB_ENV_OVERLAY=.env.lde.local_hub.hub.env LDE_COMPOSE_EXTRA_FILES="${extra[*]}"
  if declare -F do_spl_local_hub_unlock >/dev/null && [[ " ${extra[*]} " == *-vault.yaml* ]]; then
    export LDE_PG_UNLOCK=do_spl_local_hub_unlock
  fi
  (umask 077; mkdir -p "$LDE_STATE_DIR") && chmod 700 "$LDE_STATE_DIR" || return 1
  do_lde_cnf
}

# spl_local_hub_is_user -- the caller is the hub user.
spl_local_hub_is_user() { [[ "$(id -un)" == "$LOCAL_HUB_USER" ]]; }

# spl_local_hub_reexec <action> -- run `./run -a <action>` as the hub user in
# its long-lived tree. Only DRY_RUN and LOCAL_HUB_PURGE pass through: the
# private config is read on the other side, never carried in the env.
spl_local_hub_reexec() {
  local action="$1" orc="${PROJ_PATH##*/}"
  id "$LOCAL_HUB_USER" >/dev/null 2>&1 ||
    { do_log "FATAL no user $LOCAL_HUB_USER: run ./run -a do_spl_local_hub_install first"; return 1; }
  ${LOCAL_HUB_SUDO:-sudo} -n -u "$LOCAL_HUB_USER" test -d "$LOCAL_HUB_TREE/$orc" ||
    { do_log "FATAL no tree $LOCAL_HUB_TREE: run ./run -a do_spl_local_hub_update first"; return 1; }
  do_log "INFO $action as $LOCAL_HUB_USER in $LOCAL_HUB_TREE"
  ${LOCAL_HUB_SUDO:-sudo} -n -u "$LOCAL_HUB_USER" -H \
    env DRY_RUN="${DRY_RUN:-}" LOCAL_HUB_PURGE="${LOCAL_HUB_PURGE:-0}" \
    bash -c 'cd "$1" && exec ./run -a "$2"' _ "$LOCAL_HUB_TREE/$orc" "$action"
}
