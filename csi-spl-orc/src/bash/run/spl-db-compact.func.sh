#!/bin/bash
#------------------------------------------------------------------------------
# @description Give a bloated hub table's dead space back: VACUUM (FULL,
# @description ANALYZE) of ONE table as the schema OWNER (only an owner may),
# @description through the Cloud SQL proxy, printing the table's size before
# @description and after (SPL-984, spec 029).
# @description
# @description Why this exists: autovacuum makes dead rows reusable but never
# @description shrinks a table or its indexes. After a mass delete (the 022 §9
# @description 400k-row search seed and purge on dev) the relation stays
# @description huge: dev messages was 425 MB for ~17 MB of rows on 2026-09-26,
# @description and every index walk paid for the empty pages.
# @description
# @description VACUUM FULL rewrites the table and holds an ACCESS EXCLUSIVE
# @description lock for the duration: every hub read and write of that table
# @description waits. lock_timeout (COMPACT_LOCK_TIMEOUT, default 5s) makes it
# @description give up rather than queue behind the hub and stall the queue
# @description behind itself; statement_timeout caps the rewrite. prd is
# @description refused unless ALLOW_PRD=1 (a prd rewrite is a planned window,
# @description announced first). DRY_RUN=1 (default) prints the sizes and what
# @description it would run, and changes nothing.
# @param ENV - required: dev or prd
# @param TABLE (optional) - messages (default) | deliveries | message_revisions | issues | human_events
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ALLOW_PRD (optional) - 1 lets ENV=prd run for real
# @param COMPACT_LOCK_TIMEOUT (optional) - default 5s
# @param COMPACT_STATEMENT_TIMEOUT (optional) - default 10min
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_db_compact
# @example ENV=dev TABLE=messages DRY_RUN=0 ./run -a do_spl_db_compact
#------------------------------------------------------------------------------
do_spl_db_compact() {
  do_require_bin yq psql python3 || return 1
  local table="${TABLE:-messages}" dry="${DRY_RUN:-1}"
  spl_db_compact_check "$table" "$dry" "${ALLOW_PRD:-0}" "${COMPACT_LOCK_TIMEOUT:-5s}" "${COMPACT_STATEMENT_TIMEOUT:-10min}" || return 1
  do_spl_cloud_cnf || return 1
  if [[ "$(do_spl_cloud_provider)" != none ]]; then
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  local owner_dsn
  owner_dsn="$(spl_read_owner_dsn)"
  [[ -n "$owner_dsn" ]] || { do_log "FATAL cannot read $SPL_OWNER_DSN_SECRET: VACUUM FULL needs the table owner"; return 1; }
  local user
  user="$(spl_dsn_user "$owner_dsn")"
  [[ "$user" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL $SPL_OWNER_DSN_SECRET logs in as '$user', not the owner $SPL_DB_OWNER_USER"; return 1; }
  local rc=0 pdsn
  spl_sql_proxy_start || return 1
  pdsn="$(spl_local_dsn "$owner_dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL the owner DSN is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"; return 1; }
  do_log "INFO $ENV $table before:"
  spl_pg_env "$pdsn" psql -X -q -P pager=off -c "$(spl_db_compact_size_sql "$table")" || rc=1
  if [[ "$dry" == 1 ]]; then
    do_log "INFO DRY_RUN would run as $user: SET lock_timeout, statement_timeout; VACUUM (FULL, ANALYZE) $table"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to compact."
  elif (( rc == 0 )); then
    local t0=$SECONDS
    # One psql -c per statement: VACUUM cannot run inside a transaction
    # block, and psql -c "A; B" is ONE implicit transaction.
    if spl_pg_env "$pdsn" psql -X -q -v ON_ERROR_STOP=1 \
         -c "SET lock_timeout = '${COMPACT_LOCK_TIMEOUT:-5s}'" \
         -c "SET statement_timeout = '${COMPACT_STATEMENT_TIMEOUT:-10min}'" \
         -c "VACUUM (FULL, ANALYZE) $table"; then
      do_log "OK $ENV $table compacted in $((SECONDS - t0)) s; after:"
      spl_pg_env "$pdsn" psql -X -q -P pager=off -c "$(spl_db_compact_size_sql "$table")" || rc=1
    else
      rc=1
      do_log "ERROR VACUUM FULL $table failed (a lock_timeout means the hub held the table: re-run in a quieter minute)"
    fi
  fi
  spl_sql_proxy_stop
  return $rc
}

# spl_db_compact_tables -> the tables this action may rewrite, one per line.
spl_db_compact_tables() {
  printf '%s\n' messages deliveries message_revisions issues human_events
}

# spl_db_compact_check <table> <dry> <allow_prd> <lock timeout> <statement timeout>
spl_db_compact_check() {
  spl_db_compact_tables | grep -xF "$1" >/dev/null ||
    { do_log "FATAL TABLE must be one of: $(spl_db_compact_tables | tr '\n' ' ')got '$1'"; return 1; }
  [[ "$2" == 0 || "$2" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got '$2'"; return 1; }
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got '${ENV:-}'"; return 1; }
  if [[ "$ENV" == prd && "$2" == 0 && "$3" != 1 ]]; then
    do_log "FATAL ENV=prd DRY_RUN=0 rewrites a live prd table under an exclusive lock: announce a window, then pass ALLOW_PRD=1"
    return 1
  fi
  [[ "$4" =~ ^[0-9]+(ms|s)$ ]] || { do_log "FATAL COMPACT_LOCK_TIMEOUT must look like 5s or 500ms, got '$4'"; return 1; }
  [[ "$5" =~ ^[0-9]+(s|min)$ ]] || { do_log "FATAL COMPACT_STATEMENT_TIMEOUT must look like 600s or 10min, got '$5'"; return 1; }
}

# spl_db_compact_size_sql <table> -> one row: rows, heap, indexes, toast, total.
spl_db_compact_size_sql() {
  cat <<EOF_SQL
SELECT '$1' AS "table", (SELECT n_live_tup FROM pg_stat_user_tables WHERE relname = '$1') AS live_rows,
       (SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname = '$1') AS dead_rows,
       pg_size_pretty(pg_relation_size('$1'::regclass)) AS heap,
       pg_size_pretty(pg_indexes_size('$1'::regclass)) AS indexes,
       pg_size_pretty(pg_total_relation_size('$1'::regclass) - pg_relation_size('$1'::regclass) - pg_indexes_size('$1'::regclass)) AS toast,
       pg_size_pretty(pg_total_relation_size('$1'::regclass)) AS total
EOF_SQL
}
