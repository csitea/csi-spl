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
#   serve  `spool serve` as the runtime login; the session key comes from
#          SPOOL_HUB_AUTH_SESSION_KEY when set, else from the state dir
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

do_init() {
  need SPOOL_OWNER_DSN; need SPOOL_RUNTIME_ROLE; need SPOOL_RUNTIME_PASSWORD; need SPOOL_TENANT
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
  log "tenant $SPOOL_TENANT ready; init done"
}

do_serve() {
  if [ -z "${SPOOL_HUB_AUTH_SESSION_KEY:-}" ]; then
    [ -s "$state/session.key" ] || die "no session key: run the init service first (docker compose up runs it)"
    SPOOL_HUB_AUTH_SESSION_KEY="$(cat "$state/session.key")"
    export SPOOL_HUB_AUTH_SESSION_KEY
  fi
  exec spool serve
}

case "${1:-serve}" in
  init) do_init ;;
  serve) do_serve ;;
  *) exec spool "$@" ;;
esac
