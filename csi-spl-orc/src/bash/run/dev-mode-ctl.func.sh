#!/bin/bash
#------------------------------------------------------------------------------
# @description Local dev mode (spec 148, row B6): the one command that starts,
# @description stops or shows the developer stack, the `dev` profile of the
# @description root docker-compose.yml (Postgres, SeaweedFS S3, the hub, the
# @description WUI and the Mailpit mail catcher), on this machine only.
# @description do_dev_mode_up and do_dev_mode_down are this action with
# @description DEV_MODE_CMD set; `./run -a do_dev_mode_up` is the one-liner.
# @description
# @description up      1. refuses SPOOL_HUB_ENV=dev or prd: the dev profile
# @description            runs public default secrets and the one-click dev
# @description            login, which the hub refuses there anyway
# @description         2. runs the prerequisite check (dev-preflight.sh, row
# @description            B1) on the ports this stack publishes; the first
# @description            failing check stops it, exit = the check's number
# @description         3. docker compose --profile dev up -d --wait, building
# @description            hub and web from this checkout (DEV_MODE_BUILD=1):
# @description            the published images predate the dev login
# @description         4. prints the app, the Mailpit inbox and how to stop
# @description down    docker compose --profile dev down --remove-orphans;
# @description         --purge (or DEV_MODE_PURGE=1) also removes the volumes
# @description status  docker compose --profile dev ps -a
# @description
# @description The dev values (.env.example, block "local dev mode") are
# @description defaults: a value set in the shell or in the checkout's .env
# @description wins, so a developer changes a port or the sender there.
# @description   SPOOL_HUB_ENV=lde  SPOOL_AUTH_DEV_LOGIN_ENABLED=true
# @description   SPOOL_MAIL_TRANSPORT=smtp to Mailpit (host mail, port 1025,
# @description   TLS none), SPOOL_MAIL_FROM=spool@example.org,
# @description   SPOOL_ENV_NAME=lde (the web UI's dev toolbar) and
# @description   SPOOL_AUTH_FORM_PER_IP=100 (the login flows can be walked
# @description   again within the hub's 15 min rate window),
# @description   SPOOL_AUTH_DEBUG_LINKS=false (every link is in Mailpit,
# @description   none in an API answer or on the sign-up page)
# @param DEV_MODE_CMD - optional: up | down | status (default status)
# @param DEV_MODE_TREE - optional: the checkout with docker-compose.yml (default $APP_PATH)
# @param DEV_MODE_BUILD - optional: 1 (default) build from the checkout, 0 pull the pinned images
# @param DEV_MODE_PURGE - optional: 1 = down also removes the volumes (same as --purge)
# @param DEV_MODE_WAIT_S - optional: seconds compose waits for healthy services on up (default 900)
# @param DEV_MODE_PREFLIGHT - optional: the prerequisite check script (default src/bash/scripts/dev-preflight.sh)
# @param COMPOSE_PROJECT_NAME - optional: a second stack beside the default `spool`
# @example ./run -a do_dev_mode_up
# @example ./run -a do_dev_mode_down --purge
# @example DEV_MODE_CMD=status ./run -a do_dev_mode_ctl
#------------------------------------------------------------------------------

# the variables the dev profile needs, with their local dev value
DEV_MODE_DEFAULTS=(
  SPOOL_HUB_ENV=lde
  SPOOL_AUTH_DEV_LOGIN_ENABLED=true
  SPOOL_MAIL_TRANSPORT=smtp
  SPOOL_MAIL_SMTP_HOST=mail
  SPOOL_MAIL_SMTP_PORT=1025
  SPOOL_MAIL_SMTP_TLS=none
  SPOOL_MAIL_FROM=spool@example.org
  SPOOL_ENV_NAME=lde
  SPOOL_AUTH_FORM_PER_IP=100
  SPOOL_AUTH_DEBUG_LINKS=false
)

do_dev_mode_ctl() {
  local cmd="${DEV_MODE_CMD:-status}" tree="${DEV_MODE_TREE:-${APP_PATH:-}}" a purge=()
  for a in "$@"; do [[ "$a" == --purge ]] && DEV_MODE_PURGE=1; done
  [[ "${DEV_MODE_PURGE:-0}" == 1 ]] && purge=(-v)
  [[ -f "$tree/docker-compose.yml" ]] ||
    { do_log "FATAL no docker-compose.yml in '$tree': set DEV_MODE_TREE to the checkout"; return 1; }
  case "$cmd" in
    up) _dev_mode_up "$tree" ;;
    down) _dev_mode_compose "$tree" down --remove-orphans "${purge[@]}" ;;
    status) _dev_mode_compose "$tree" ps -a ;;
    *) do_log "FATAL DEV_MODE_CMD '$cmd' must be up, down or status"; return 1 ;;
  esac
}

# _dev_mode_val <tree> <name> <default>: the shell's value, else the
# checkout's .env line, else the default (the order compose reads them in)
_dev_mode_val() {
  local v
  if [[ -n "${!2+x}" ]]; then echo "${!2}"; return; fi
  v=$(sed -n "s/^$2=//p" "$1/.env" 2>/dev/null | tail -n 1)
  [[ -n "$v" ]] && { echo "$v"; return; }
  echo "$3"
}

# _dev_mode_compose <tree> <compose args...>: compose on the dev profile, with
# the dev defaults in its environment
_dev_mode_compose() {
  local tree="$1" kv; shift
  (
    for kv in "${DEV_MODE_DEFAULTS[@]}"; do
      export "${kv%%=*}=$(_dev_mode_val "$tree" "${kv%%=*}" "${kv#*=}")"
    done
    docker compose --project-directory "$tree" -f "$tree/docker-compose.yml" --profile dev "$@"
  )
}

_dev_mode_up() {
  local tree="$1" env http https smtp ui ports="" rc running build=()
  env=$(_dev_mode_val "$tree" SPOOL_HUB_ENV lde)
  [[ "$env" == dev || "$env" == prd ]] &&
    { do_log "FATAL SPOOL_HUB_ENV=$env: local dev mode runs only as lde (its secrets are public defaults)"; return 1; }
  http=$(_dev_mode_val "$tree" SPOOL_HTTP_PORT 8080)
  https=$(_dev_mode_val "$tree" SPOOL_HTTPS_PORT 8443)
  smtp=$(_dev_mode_val "$tree" SPOOL_MAILPIT_SMTP_PORT 1025)
  ui=$(_dev_mode_val "$tree" SPOOL_MAILPIT_UI_PORT 8025)
  # a running stack holds its own ports: check them only before a first start
  running=$(_dev_mode_compose "$tree" ps -q --status running 2>/dev/null)
  [[ -z "$running" ]] && ports="$http $https $smtp $ui"
  # one space, not empty: the preflight reads an empty list as its defaults
  DEV_PREFLIGHT_PORTS="${ports:- }" bash "${DEV_MODE_PREFLIGHT:-$PROJ_PATH/src/bash/scripts/dev-preflight.sh}"
  rc=$?
  [[ $rc -eq 0 ]] || { do_log "FATAL dev preflight check $rc failed: fix it as printed above, then run again"; return "$rc"; }
  [[ "${DEV_MODE_BUILD:-1}" == 1 ]] && build=(--build)
  (
    [[ "${DEV_MODE_BUILD:-1}" == 1 ]] && export SPOOL_IMAGE_TAG="${SPOOL_IMAGE_TAG:-local}"
    _dev_mode_compose "$tree" up -d "${build[@]}" --wait --wait-timeout "${DEV_MODE_WAIT_S:-900}"
  )
  rc=$?
  [[ $rc -eq 0 ]] || { do_log "FATAL docker compose up failed ($rc): read 'DEV_MODE_CMD=status ./run -a do_dev_mode_ctl' and 'docker compose logs hub'"; return "$rc"; }
  echo "OK local dev mode is up"
  echo "  app      http://localhost:$http  (Dev login: the button on the sign-in page)"
  echo "  mail     http://localhost:$ui  (Mailpit: every mail the hub sends)"
  echo "  stop     ./run -a do_dev_mode_down   (--purge also removes the data)"
}
