#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the root docker-compose.yml carries local dev mode as its `dev`
#          profile (spec 148 B5, SPL-2910; owner: one compose file, no
#          docker-compose.dev.yml):
#   1. no profile: the stack is unchanged: no mail service, the hub's SMTP TLS
#      is starttls (its own default) and the dev login is off, and the hub's
#      wait for mail is optional (required: false)
#   2. --profile dev adds `mail`: Mailpit v1.21 pinned by digest, a non-root
#      user, a healthcheck, on the spool bridge, SMTP 1025 and the inbox 8025
#      published on 127.0.0.1 only (also when SPOOL_BIND is 0.0.0.0), and the
#      hub waits for it healthy; pg, s3, hub-init, hub and web stay in it
#   3. every variable the .env.example "local dev mode" block names is read
#      by docker-compose.yml, and that block, uncommented, sends the hub's
#      mail to mail:1025 with TLS none and turns the dev login on (lde)
#   4. the two new hub variables map as .env.example names them:
#      SPOOL_AUTH_DEV_LOGIN_ENABLED -> SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED,
#      SPOOL_MAIL_SMTP_TLS -> SPOOL_HUB_MAIL_SMTP_TLS
#   CONTROL: a block variable the compose file does not read is caught
# Hermetic: `docker compose config` only, no pull, no network, no daemon.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

command -v jq >/dev/null || { fail "jq is not installed"; exit 1; }
docker compose version >/dev/null 2>&1 || { fail "docker compose is not installed"; exit 1; }

COMPOSE="$APP_ROOT/docker-compose.yml"
ENV_EXAMPLE="$APP_ROOT/.env.example"

# cfg [--profile dev] [VAR=value ...] -> the resolved config as JSON, from a
# clean env (an operator's own SPOOL_* would otherwise leak in), no .env file
cfg() {
  local prof=()
  [[ "${1:-}" == --profile ]] && { prof=(--profile "$2"); shift 2; }
  (cd "$APP_ROOT" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} "$@" \
    docker compose --env-file /dev/null -f docker-compose.yml "${prof[@]}" config --format json)
}
# q <json> <jq filter> -> raw value
q() { jq -r "$2" <<<"$1"; }

# --- 1. no profile: the stack as before -----------------------------------------------
c=$(cfg 2>&1) || { fail "docker compose config: $c"; exit 1; }
[[ "$(q "$c" '.services | has("mail")')" == false ]] && pass "no profile: no mail service" || fail "no profile: mail is in the stack"
[[ "$(q "$c" '.services.hub.environment.SPOOL_HUB_MAIL_SMTP_TLS')" == starttls ]] \
  && pass "no profile: hub SMTP TLS defaults to starttls" || fail "no profile: SPOOL_HUB_MAIL_SMTP_TLS is '$(q "$c" '.services.hub.environment.SPOOL_HUB_MAIL_SMTP_TLS')'"
[[ "$(q "$c" '.services.hub.environment.SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED')" == false ]] \
  && pass "no profile: the dev login is off" || fail "no profile: SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED is '$(q "$c" '.services.hub.environment.SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED')'"
[[ "$(q "$c" '.services.hub.depends_on.mail.required')" == false ]] \
  && pass "no profile: the hub's wait for mail is optional" || fail "hub depends_on mail: $(q "$c" '.services.hub.depends_on.mail | tostring')"
[[ "$(q "$c" '.services.hub.environment.SPOOL_HUB_MAIL_TRANSPORT')" == log ]] \
  && pass "no profile: hub mail still goes to the log" || fail "no profile: transport '$(q "$c" '.services.hub.environment.SPOOL_HUB_MAIL_TRANSPORT')'"

# --- 2. --profile dev adds Mailpit ----------------------------------------------------
d=$(cfg --profile dev 2>&1) || { fail "docker compose --profile dev config: $d"; exit 1; }
pass "docker compose --profile dev config parses"
for svc in pg s3 hub-init hub web mail; do
  [[ "$(jq -r --arg x "$svc" '.services | has($x)' <<<"$d")" == true ]] \
    && pass "dev: $svc is in the stack" || fail "dev: $svc is missing"
done
img=$(q "$d" '.services.mail.image')
[[ "$img" =~ ^axllent/mailpit:v1\.21@sha256:[0-9a-f]{64}$ ]] && pass "dev: mail is Mailpit v1.21 pinned by digest" || fail "dev: mail image '$img'"
usr=$(q "$d" '.services.mail.user // ""')
[[ -n "$usr" && "${usr%%:*}" != 0 && "${usr%%:*}" != root ]] && pass "dev: mail runs as $usr" || fail "dev: mail user '$usr'"
[[ "$(q "$d" '.services.mail.healthcheck.test[0] // "NONE"')" != NONE ]] && pass "dev: mail has a healthcheck" || fail "dev: mail has no healthcheck"
[[ "$(q "$d" '.services.mail.networks | keys | join(" ")')" == spool ]] && pass "dev: mail is on the spool bridge" || fail "dev: mail networks '$(q "$d" '.services.mail.networks | tostring')'"
[[ "$(q "$d" '.services.hub.depends_on.mail.condition')" == service_healthy ]] && pass "dev: hub waits for mail healthy" || fail "dev: hub depends_on mail '$(q "$d" '.services.hub.depends_on.mail | tostring')'"
ports_of() { jq -r '[.services.mail.ports[] | "\(.host_ip):\(.published):\(.target)"] | sort | join(" ")' <<<"$1"; }
got=$(ports_of "$d")
[[ "$got" == "127.0.0.1:1025:1025 127.0.0.1:8025:8025" ]] && pass "dev: mail publishes 1025 + 8025 on 127.0.0.1" || fail "dev: mail ports '$got'"
w=$(cfg --profile dev SPOOL_BIND=0.0.0.0 2>&1) || { fail "config with SPOOL_BIND=0.0.0.0: $w"; w='{}'; }
got=$(ports_of "$w")
[[ "$got" == "127.0.0.1:1025:1025 127.0.0.1:8025:8025" ]] && pass "dev: SPOOL_BIND=0.0.0.0 leaves mail on loopback" || fail "dev: SPOOL_BIND=0.0.0.0 moves mail to '$got'"

# --- 3. the .env.example dev block drives this file ----------------------------------
# block_vars: "NAME=value" per commented assignment in the dev block, from
# its "# --- local dev mode" header to the next "# ---" one
block_vars() {
  awk '/^# --- local dev mode/ {on=1; next} on && /^# ---/ {exit}
       on && /^# SPOOL_[A-Z0-9_]+=/ {sub(/^# /, ""); print}' "$1"
}
mapfile -t kv < <(block_vars "$ENV_EXAMPLE")
[[ "${#kv[@]}" -ge 8 ]] && pass "${#kv[@]} variables in the .env.example dev block" || fail "dev block: only ${#kv[@]} variables found"
# unread <compose file> <NAME=value>... -> each NAME the file never reads
unread() {
  local f="$1" p; shift
  for p in "$@"; do grep -qF "\${${p%%=*}:-" "$f" || grep -qF "\${${p%%=*}}" "$f" || echo "${p%%=*}"; done
}
miss=$(unread "$COMPOSE" "${kv[@]}" | tr '\n' ' ')
[[ -z "$miss" ]] && pass "docker-compose.yml reads every dev block variable" || fail "docker-compose.yml never reads: $miss"
u=$(cfg --profile dev "${kv[@]}" 2>&1) || { fail "config with the dev block: $u"; u='{}'; }
hub_env() { jq -r --arg k "$2" '.services.hub.environment[$k] // ""' <<<"$1"; }
for want in SPOOL_HUB_ENV=lde SPOOL_HUB_MAIL_TRANSPORT=smtp SPOOL_HUB_MAIL_SMTP_HOST=mail \
            SPOOL_HUB_MAIL_SMTP_PORT=1025 SPOOL_HUB_MAIL_SMTP_TLS=none SPOOL_HUB_MAIL_SMTP_USER= \
            SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED=true; do
  got=$(hub_env "$u" "${want%%=*}")
  [[ "$got" == "${want#*=}" ]] && pass "dev block: hub $want" || fail "dev block: hub ${want%%=*}='$got', want '${want#*=}'"
done
got=$(ports_of "$u")
[[ "$got" == "127.0.0.1:1025:1025 127.0.0.1:8025:8025" ]] && pass "dev block: Mailpit host ports 1025 / 8025" || fail "dev block: mail ports '$got'"

# --- 4. each new hub variable on its own ---------------------------------------------
o=$(cfg SPOOL_AUTH_DEV_LOGIN_ENABLED=true SPOOL_MAIL_SMTP_TLS=implicit 2>&1) || { fail "config: $o"; o='{}'; }
[[ "$(hub_env "$o" SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED)" == true ]] && pass "SPOOL_AUTH_DEV_LOGIN_ENABLED -> SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED" || fail "dev login switch not mapped"
[[ "$(hub_env "$o" SPOOL_HUB_MAIL_SMTP_TLS)" == implicit ]] && pass "SPOOL_MAIL_SMTP_TLS -> SPOOL_HUB_MAIL_SMTP_TLS" || fail "SMTP TLS not mapped"

# --- CONTROL ------------------------------------------------------------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
grep -vF 'SPOOL_MAIL_SMTP_TLS' "$COMPOSE" >"$T/compose.yml"
[[ "$(unread "$T/compose.yml" "${kv[@]}")" == SPOOL_MAIL_SMTP_TLS ]] \
  && pass "control: a compose file that drops SPOOL_MAIL_SMTP_TLS is caught" || fail "control: the dropped variable was not seen"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
