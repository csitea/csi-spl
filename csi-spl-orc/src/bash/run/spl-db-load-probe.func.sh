#!/bin/bash
#------------------------------------------------------------------------------
# @description Bounded load on the DEV hub DB (SPL-2880): does the db-f1-micro
# @description tier stall (checkpoint sync, swap, CPU waits) under prd-like
# @description concurrency on its own, with no platform incident? pgbench runs
# @description DBL_CLIENTS sessions for DBL_MINUTES of a memory-heavy read
# @description (messages grouped per topic, bodies aggregated and sorted)
# @description through one Cloud SQL proxy, as the hub's runtime login, under
# @description the operator row-level-security scope. The sessions are
# @description default_transaction_read_only=on and each script is BEGIN READ
# @description ONLY .. COMMIT: Postgres refuses any write. pgbench is the one
# @description in the box's postgres image (DBL_IMAGE, host network, so it
# @description reaches the local proxy); nothing is installed. Read the instance
# @description over the printed window with do_spl_db_window, and a quiet
# @description window of the same length before it.
# @description Refused for any ENV but dev. A dry run unless DRY_RUN=0.
# @param ENV - required: dev (any other env is refused)
# @param DBL_MINUTES (optional) - run length, 1..15, default 10
# @param DBL_CLIENTS (optional) - concurrent sessions, 1..12, default 8
# @param DBL_IMAGE (optional) - the image pgbench runs from, default postgres:16-alpine
# @param DRY_RUN (optional) - 1 (default) prints the plan; 0 runs it
# @example ENV=dev DBL_MINUTES=10 DBL_CLIENTS=8 DRY_RUN=0 ./run -a do_spl_db_load_probe
#------------------------------------------------------------------------------
do_spl_db_load_probe() {
  local minutes="${DBL_MINUTES:-10}" clients="${DBL_CLIENTS:-8}"
  spl_db_load_probe_check_args "${ENV:-}" "$minutes" "$clients" || return 1
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    printf 'DRY RUN: would run pgbench on %s for %s min with %s read-only clients; script:\n%s\n' \
      "$ENV" "$minutes" "$clients" "$(spl_db_load_probe_script)"
    return 0
  fi
  do_require_bin gcloud docker python3 yq || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_db_load_probe_run "$minutes" "$clients"
}

# spl_db_load_probe_check_args <env> <minutes> <clients> -> 0 when sane.
spl_db_load_probe_check_args() {
  [[ "$1" == dev ]] || { do_log "FATAL do_spl_db_load_probe runs on ENV=dev only, got '$1'"; return 1; }
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 15 )) || { do_log "FATAL DBL_MINUTES must be 1..15, got '$2'"; return 1; }
  [[ "$3" =~ ^[0-9]+$ ]] && (( $3 >= 1 && $3 <= 12 )) || { do_log "FATAL DBL_CLIENTS must be 1..12, got '$3'"; return 1; }
}

# spl_db_load_probe_script -> the pgbench script: one read-only transaction.
spl_db_load_probe_script() {
  cat <<'SQL'
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT task_id, count(*) AS n, sum(length(body)) AS bytes, md5(string_agg(left(body, 400), '' ORDER BY ts)) AS h
  FROM messages GROUP BY task_id ORDER BY n DESC, task_id LIMIT 20;
COMMIT;
SQL
}

# _spl_db_load_probe_run <minutes> <clients> -> pgbench with SPL_PROXY_DSN in
# the env. The login travels in PG* env vars only, never argv.
_spl_db_load_probe_run() {
  local parts script rc=0
  parts="$(python3 -c '
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print("\n".join([u.unquote(p.username or ""), u.unquote(p.password or ""), p.hostname or "", str(p.port or 5432), p.path.lstrip("/")]))
' "$SPL_PROXY_DSN")" || return 1
  local -a f
  mapfile -t f <<<"$parts"
  script="$(mktemp)" || return 1
  spl_db_load_probe_script >"$script"
  printf '===== csi-spl db load probe: env=%s instance=%s clients=%s start=%s minutes=%s\n' \
    "$ENV" "$SPL_SQL_INSTANCE" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
  chmod 0644 "$script"
  PGUSER="${f[0]}" PGPASSWORD="${f[1]}" PGHOST="${f[2]}" PGPORT="${f[3]}" PGDATABASE="${f[4]}" \
    PGSSLMODE=disable PGCONNECT_TIMEOUT=15 PGOPTIONS='-c default_transaction_read_only=on' \
    docker run --rm --network host -v "$script:/load.sql:ro" \
      -e PGUSER -e PGPASSWORD -e PGHOST -e PGPORT -e PGDATABASE -e PGSSLMODE -e PGCONNECT_TIMEOUT -e PGOPTIONS \
      "${DBL_IMAGE:-postgres:16-alpine}" pgbench -n -c "$2" -j 2 -T "$(( $1 * 60 ))" -P 60 -r -f /load.sql 2>&1 || rc=$?
  printf '===== end=%s rc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc"
  rm -f "$script"
  return $rc
}
