#!/bin/sh
# The standalone hub container's entrypoint (the root docker-compose.yml).
#
#   init   one shot, before the hub starts, safe to re-run:
#            1. `spool migrate` as the schema OWNER (SPOOL_OWNER_DSN)
#            2. the runtime login + its DML-only grants (csi-spl-rdb
#               spool-hub-roles/*.sql), run as the owner through psql, so the
#               hub itself never owns a table and row level security binds it
#            3. the session signing key, generated once into $SPOOL_STATE_DIR
#            4. the first tenant (SPOOL_TENANT) with a tenant root key
#               generated once into $SPOOL_STATE_DIR
#            5. off localhost (specs/047 W9, W18): refuse the public default
#               DB passwords, and seat the owner by a one-time invite for
#               SPOOL_OWNER_EMAIL instead of "first sign-up wins"
#            6. print the owner sign-in link and the one line that seats an
#               agent (W5): `docker compose logs hub-init`
#   serve  `spool serve` as the runtime login; the session key comes from
#          SPOOL_HUB_AUTH_SESSION_KEY when set, else from the state dir.
#          SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=auto (the compose default) becomes
#          true on localhost and false anywhere else
#   *      any other argument runs `spool <args>` (e.g. `version`)
#
# Nothing here reads a cloud credential. Every value is an env var the compose
# file documents; the two generated values never leave the state volume.
set -eu

state="${SPOOL_STATE_DIR:-/var/lib/spool/state}"
roles_sql="${SPOOL_ROLES_SQL_DIR:-/opt/spool/sql/postgres/spool-hub-roles}"

log() { printf '%s hub-entrypoint: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL $*"; exit 1; }
need() { eval "v=\${$1:-}"; [ -n "$v" ] || die "$1 must be set (see .env.example)"; }

# owner_psql <file> [psql -v args]: run a roles file as the schema owner
owner_psql() {
  f="$1"; shift
  # client_min_messages: the grants file warns once per extension function
  # (unaccent) that the owner does not own; that is expected, not an error
  PGOPTIONS="-c client_min_messages=error" psql -X -q -v ON_ERROR_STOP=1 "$@" -f "$f" "$SPOOL_OWNER_DSN" >/dev/null
}

public_url() { u="${SPOOL_PUBLIC_URL:-http://localhost:8080}"; printf '%s' "${u%/}"; }
# where: the two facts is_local reads, for a message
where() { printf '%s (bound to %s)' "$(public_url)" "${SPOOL_BIND:-127.0.0.1}"; }

# is_local: 0 when only this machine reaches the stack - the browser URL's
# host is a loopback name AND the ports are bound to loopback (.env.example's
# local profile). Anything else is a public instance.
is_local() {
  h="$(public_url)"; h="${h#*://}"; h="${h%%/*}"
  case "$h" in \[*) h="${h%%]*}]" ;; *) h="${h%%:*}" ;; esac
  case "$h" in localhost|*.localhost|127.[0-9]*.[0-9]*.[0-9]*|"[::1]") ;; *) return 1 ;; esac
  case "${SPOOL_BIND:-127.0.0.1}" in 127.[0-9]*.[0-9]*.[0-9]*|localhost|::1|"[::1]") return 0 ;; *) return 1 ;; esac
}

# refuse_default_passwords (W9): the compose defaults are in a public repo,
# so off localhost each one must have been replaced in .env.
refuse_default_passwords() {
  bad=""
  [ "${SPOOL_OWNER_PASSWORD:-}" != spool-local-owner ] || bad="$bad SPOOL_DB_OWNER_PASSWORD"
  [ "$SPOOL_RUNTIME_PASSWORD" != spool-local-runtime ] || bad="$bad SPOOL_DB_RUNTIME_PASSWORD"
  [ "${SPOOL_SUPERUSER_PASSWORD:-}" != spool-local-superuser ] || bad="$bad SPOOL_DB_SUPERUSER_PASSWORD"
  [ -z "$bad" ] && return 0
  die "this stack is reachable beyond this machine - $(where) - and these Postgres passwords are still the public defaults of docker-compose.yml:$bad. Set each one in .env (a long random value, e.g. openssl rand -hex 24). Postgres takes them on a NEW volume only: on a stack that never held data run 'docker compose down -v' first, then 'docker compose up -d'"
}

# tenant_members: how many humans the tenant has (rdb 0014 row level security
# binds the owner too, so the query names the tenant it reads)
tenant_members() {
  printf '%s\n' "SELECT set_config('app.tenant_id', :'t', false) \\g /dev/null" \
    "SELECT count(*) FROM tenant_memberships WHERE tenant_id = :'t';" |
    psql -X -qtA -v ON_ERROR_STOP=1 -v t="$SPOOL_TENANT" "$SPOOL_OWNER_DSN"
}

# seat_owner (W18): off localhost nobody becomes owner by signing up first.
# While the tenant has no member, SPOOL_OWNER_EMAIL gets a one-time biz_owner
# invite: only a sign-up that CONFIRMS that address is admitted as owner, once.
seat_owner() {
  n="$(tenant_members)" || die "cannot count the members of tenant $SPOOL_TENANT"
  if [ "$n" != 0 ]; then
    log "tenant $SPOOL_TENANT has $n member(s): its owner is seated, no owner invite"
    return 0
  fi
  [ -n "${SPOOL_OWNER_EMAIL:-}" ] || die "this stack is reachable beyond this machine - $(where) - so the first sign-up does NOT become the owner here: set SPOOL_OWNER_EMAIL in .env to the owner's address, then 'docker compose up -d'"
  spool hub-invite --tenant "$SPOOL_TENANT" --email "$SPOOL_OWNER_EMAIL" --role biz_owner \
    --ttl "${SPOOL_OWNER_INVITE_TTL:-168h}" --no-mail --db "$SPOOL_OWNER_DSN" >/dev/null ||
    die "cannot write the owner invite for tenant $SPOOL_TENANT"
  log "OWNER: open $(public_url)/login?tenant=$SPOOL_TENANT and sign up with $SPOOL_OWNER_EMAIL - one time, only that confirmed address becomes the owner (open for ${SPOOL_OWNER_INVITE_TTL:-168h}; a later 'up' renews it until someone accepts)"
}

# seat_line (W5): the one line that seats an agent on this hub, run from this
# clone. The tenant root key is copied into a 0600 file in the operator's home,
# never into a log.
seat_line() {
  log "AGENT: seat one from this clone (the root key goes to a 0600 file, then the installer pins the box):"
  log "  (umask 077; docker compose exec -T hub cat $state/tenant-root.key >\"\$HOME/.spool-root-$SPOOL_TENANT.key\") && SPOOL_HUB_URL=$(public_url) ROOT_KEY_JSON=\"\$HOME/.spool-root-$SPOOL_TENANT.key\" bash csi-spl-orc/src/bash/features/spool-install/install.sh --env self --tenant $SPOOL_TENANT --cli claude"
  log "  then start it inside tmux: spool-agent claude   (README: Connect an agent)"
}

do_init() {
  need SPOOL_OWNER_DSN; need SPOOL_RUNTIME_ROLE; need SPOOL_RUNTIME_PASSWORD; need SPOOL_TENANT
  is_local || refuse_default_passwords
  mkdir -p "$state"
  log "migrate (as the schema owner)"
  out="$(spool migrate --db "$SPOOL_OWNER_DSN")" || die "spool migrate failed"
  log "$(printf '%s\n' "$out" | grep -c '^applied' || true) migration(s) applied, $(printf '%s\n' "$out" | grep -c '^skipped' || true) already there"
  log "runtime login ${SPOOL_RUNTIME_ROLE}: create + DML-only grants"
  owner_psql "$roles_sql/runtime-role.sql" -v runtime_role="$SPOOL_RUNTIME_ROLE" -v runtime_verifier="$SPOOL_RUNTIME_PASSWORD"
  owner_psql "$roles_sql/runtime-grants.sql" -v runtime_role="$SPOOL_RUNTIME_ROLE"
  if [ ! -s "$state/session.key" ]; then
    (umask 077; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$state/session.key")
    log "session key generated into the state volume"
  fi
  if [ ! -s "$state/tenant-root.pub" ]; then
    rm -f "$state/tenant-root.key"
    (umask 077; spool root-keygen --out "$state/tenant-root.key" >"$state/tenant-root.pub")
    log "tenant root key generated into the state volume"
  fi
  spool hub-tenant --tenant "$SPOOL_TENANT" --root-pubkey "$(cat "$state/tenant-root.pub")" \
    --billing-status "${SPOOL_TENANT_BILLING_STATUS:-internal}" --db "$SPOOL_OWNER_DSN" >/dev/null
  if is_local; then
    log "OWNER: $(public_url) is local: the first person who signs up and confirms their email becomes the owner"
  else
    seat_owner
  fi
  seat_line
  log "tenant $SPOOL_TENANT ready; init done"
}

do_serve() {
  case "${SPOOL_HUB_AUTH_BOOTSTRAP_OWNER:-auto}" in
    auto)
      if is_local; then SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=true; else SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=false; fi
      export SPOOL_HUB_AUTH_BOOTSTRAP_OWNER
      log "first sign-up becomes owner: $SPOOL_HUB_AUTH_BOOTSTRAP_OWNER ($(public_url))" ;;
    true) is_local || log "WARN SPOOL_BOOTSTRAP_OWNER=true on $(where): whoever signs up first owns the tenant" ;;
  esac
  if [ -z "${SPOOL_HUB_AUTH_SESSION_KEY:-}" ]; then
    [ -s "$state/session.key" ] || die "no session key: run the init service first (docker compose up runs it)"
    SPOOL_HUB_AUTH_SESSION_KEY="$(cat "$state/session.key")"
    export SPOOL_HUB_AUTH_SESSION_KEY
  fi
  exec spool serve
}

# SPOOL_ENTRYPOINT_LIB=1: define the functions and stop (the unit test
# csi-spl-api/src/bash/tests/hub-entrypoint.tst.sh sources it that way)
[ "${SPOOL_ENTRYPOINT_LIB:-0}" = 1 ] && return 0 2>/dev/null

case "${1:-serve}" in
  init) do_init ;;
  serve) do_serve ;;
  *) exec spool "$@" ;;
esac
