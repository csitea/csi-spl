#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY health report of a cloud env's hub DB: size, load,
# @description vacuum/wraparound, schema shape, and the Cloud SQL instance
# @description itself. One Cloud SQL proxy session for the whole report
# @description (do_spl_db_query starts one per statement, which is ~12 s of
# @description proxy start per question).
# @description
# @description Nothing is mutated. The psql session runs with
# @description default_transaction_read_only=on inside BEGIN READ ONLY and
# @description ends in ROLLBACK, so Postgres itself refuses a write; the
# @description gcloud half only describes and lists. The transaction takes the
# @description operator row-level-security scope (rdb 0014, 017 FR-SEC-013):
# @description without it every tenant table reads empty to the hub login.
# @description
# @description A statement the hub's RUNTIME login may not run (for example
# @description pg_stat_statements without pg_read_all_stats, or pg_ls_waldir
# @description without pg_monitor) prints its ERROR and the report continues:
# @description psql runs with ON_ERROR_ROLLBACK=on, so each statement has its
# @description own savepoint. "Not permitted" is itself a finding, so it is
# @description printed rather than hidden.
# @param ENV - required: dev or prd
# @param SECTION (optional) - all (default) | size | load | vacuum | structure | cloudsql
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=dev ./run -a do_spl_db_health
# @example ENV=prd SECTION=vacuum ./run -a do_spl_db_health
#------------------------------------------------------------------------------
do_spl_db_health() {
  do_require_bin gcloud psql python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local section="${SECTION:-all}"
  spl_db_health_known_section "$section" ||
    { do_log "FATAL SECTION must be all or one of: $(spl_db_health_sections | tr '\n' ' ')"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  printf '===== csi-spl db health: env=%s project=%s instance=%s db=%s section=%s utc=%s\n' \
    "$ENV" "$SPL_PROJECT" "$SPL_SQL_INSTANCE" "$SPL_DB_NAME" "$section" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local rc=0
  if [[ "$section" == all || "$section" == cloudsql ]]; then
    spl_db_health_cloudsql || rc=$?
  fi
  if [[ "$section" != cloudsql ]]; then
    spl_via_proxy _spl_db_health_run "$section" || rc=$?
  fi
  return $rc
}

# spl_db_health_sections -> the sections, one per line, in report order.
spl_db_health_sections() {
  printf '%s\n' size load vacuum structure cloudsql
}

# spl_db_health_known_section <name> -> 0 when it is "all" or a known section.
spl_db_health_known_section() {
  [[ "$1" == all ]] && return 0
  spl_db_health_sections | grep -qxF "$1"
}

# _spl_db_health_run <section> -> the SQL half, with SPL_PROXY_DSN in the env.
_spl_db_health_run() {
  local sql
  sql="$(spl_db_health_sql "$1")" || return 1
  spl_psql_report "$SPL_PROXY_DSN" "$sql"
}

# spl_psql_report <proxy dsn> <sql> -> psql in a read-only transaction with
# ALIGNED output (a report is read by a person, not parsed), the operator RLS
# scope, and a savepoint per statement so one refused catalog read does not
# abort the rest. The login travels in PG* env vars only, never argv.
spl_psql_report() {
  local parts
  parts="$(python3 -c '
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print("\n".join([u.unquote(p.username or ""), u.unquote(p.password or ""), p.hostname or "", str(p.port or 5432), p.path.lstrip("/")]))
' "$1")" || return 1
  local -a f
  mapfile -t f <<<"$parts"
  printf 'BEGIN READ ONLY;\nSET LOCAL app.rls_scope = '\''operator'\'';\n%s\nROLLBACK;\n' "$2" |
    PGUSER="${f[0]}" PGPASSWORD="${f[1]}" PGHOST="${f[2]}" PGPORT="${f[3]}" PGDATABASE="${f[4]}" \
    PGSSLMODE=disable PGCONNECT_TIMEOUT=15 PGOPTIONS='-c default_transaction_read_only=on' \
    psql -X -q -v ON_ERROR_STOP=0 -v ON_ERROR_ROLLBACK=on -P pager=off 2>&1
}

# spl_db_health_sql <all|size|load|vacuum|structure> -> the report's SQL.
spl_db_health_sql() {
  local want="$1" s
  for s in size load vacuum structure; do
    [[ "$want" == all || "$want" == "$s" ]] || continue
    "_spl_db_health_sql_$s"
  done
}

_spl_db_health_sql_size() {
  cat <<'EOF_SQL'
\echo ''
\echo '--- size: the database'
SELECT current_database() AS db,
       pg_size_pretty(pg_database_size(current_database())) AS logical_size,
       pg_database_size(current_database())                 AS bytes;

\echo '--- size: relations, biggest first'
SELECT c.relname                                                             AS relation,
       c.relkind                                                             AS kind,
       COALESCE(st.n_live_tup, c.reltuples::bigint)                          AS rows,
       pg_size_pretty(pg_total_relation_size(c.oid))                         AS total,
       pg_size_pretty(pg_relation_size(c.oid))                               AS heap,
       pg_size_pretty(pg_indexes_size(c.oid))                                AS indexes,
       pg_size_pretty(COALESCE(pg_total_relation_size(c.reltoastrelid), 0))  AS toast
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_stat_user_tables st ON st.relid = c.oid
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
   AND c.relkind IN ('r', 'p', 'm')
 ORDER BY pg_total_relation_size(c.oid) DESC, c.relname;

\echo '--- size: indexes, biggest first (idx_scan = how often the planner used it)'
SELECT t.relname                                AS "table",
       i.relname                                AS index,
       am.amname                                AS method,
       pg_size_pretty(pg_relation_size(i.oid))  AS size,
       s.idx_scan
  FROM pg_class i
  JOIN pg_index x     ON x.indexrelid = i.oid
  JOIN pg_class t     ON t.oid = x.indrelid
  JOIN pg_am am       ON am.oid = i.relam
  JOIN pg_namespace n ON n.oid = i.relnamespace
  LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = i.oid
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
 ORDER BY pg_relation_size(i.oid) DESC, i.relname;

\echo '--- size: dead tuples as a bloat proxy (pgstattuple gives the real number)'
SELECT relname AS "table", n_live_tup, n_dead_tup,
       CASE WHEN n_live_tup + n_dead_tup > 0
            THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1) END AS dead_pct,
       n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd
  FROM pg_stat_user_tables
 ORDER BY n_dead_tup DESC, relname;

SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgstattuple')            AS pgstattuple_installed,
       EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pgstattuple')    AS pgstattuple_available;

\echo '--- size: WAL on disk (needs pg_monitor; an error here is itself the finding)'
SELECT count(*) AS wal_segments, pg_size_pretty(sum(size)) AS wal_size FROM pg_ls_waldir();
EOF_SQL
}

_spl_db_health_sql_load() {
  cat <<'EOF_SQL'
\echo ''
\echo '--- load: the settings a hub on a shared tier lives or dies by'
SELECT name, setting, unit, source
  FROM pg_settings
 WHERE name IN ('max_connections', 'superuser_reserved_connections', 'shared_buffers',
                'effective_cache_size', 'work_mem', 'maintenance_work_mem', 'temp_buffers',
                'autovacuum', 'autovacuum_max_workers', 'autovacuum_naptime',
                'autovacuum_vacuum_scale_factor', 'autovacuum_vacuum_threshold',
                'autovacuum_vacuum_insert_scale_factor', 'autovacuum_analyze_scale_factor',
                'autovacuum_vacuum_cost_delay', 'autovacuum_vacuum_cost_limit',
                'autovacuum_freeze_max_age', 'vacuum_freeze_table_age',
                'checkpoint_timeout', 'max_wal_size', 'min_wal_size', 'wal_level',
                'track_counts', 'track_io_timing', 'shared_preload_libraries',
                'statement_timeout', 'idle_in_transaction_session_timeout',
                'log_min_duration_statement', 'random_page_cost', 'jit', 'max_worker_processes')
 ORDER BY name;

\echo '--- load: connections by login and state (against max_connections above)'
SELECT COALESCE(usename, '(background)') AS login,
       COALESCE(state, '(none)')         AS state,
       count(*)                          AS conns,
       max(now() - state_change)         AS longest_in_state
  FROM pg_stat_activity
 GROUP BY 1, 2
 ORDER BY 3 DESC, 1, 2;

\echo '--- load: the oldest sessions (long transactions, idle-in-transaction, waits)'
SELECT pid, usename AS login, state,
       now() - xact_start    AS xact_age,
       now() - state_change  AS state_age,
       wait_event_type, wait_event,
       left(regexp_replace(COALESCE(query, ''), '\s+', ' ', 'g'), 60) AS query
  FROM pg_stat_activity
 WHERE pid <> pg_backend_pid() AND datname = current_database()
 ORDER BY COALESCE(xact_start, state_change) NULLS LAST
 LIMIT 15;

\echo '--- load: sessions blocked on a lock (empty = nothing is waiting right now)'
SELECT w.pid AS waiting, w.usename AS waiting_login, w.wait_event_type, w.wait_event,
       b.pid AS blocked_by, now() - w.state_change AS waiting_for
  FROM pg_stat_activity w
  CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS b(pid)
 ORDER BY 1;

\echo '--- load: database counters since the last stats reset'
SELECT numbackends, xact_commit, xact_rollback,
       blks_read, blks_hit,
       round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
       tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
       temp_files, pg_size_pretty(temp_bytes) AS temp_bytes, deadlocks,
       round(blk_read_time::numeric, 1)  AS blk_read_ms,
       round(blk_write_time::numeric, 1) AS blk_write_ms,
       stats_reset, now() - stats_reset AS stats_age
  FROM pg_stat_database
 WHERE datname = current_database();

\echo '--- load: sequential vs index scans per table (a high seq_pct on a BIG table is the smell)'
SELECT relname AS "table", seq_scan, seq_tup_read, idx_scan, idx_tup_fetch, n_live_tup,
       CASE WHEN seq_scan + COALESCE(idx_scan, 0) > 0
            THEN round(100.0 * seq_scan / (seq_scan + COALESCE(idx_scan, 0)), 1) END AS seq_pct,
       CASE WHEN seq_scan > 0 THEN (seq_tup_read / seq_scan) END AS rows_per_seq_scan
  FROM pg_stat_user_tables
 ORDER BY seq_tup_read DESC, relname;

\echo '--- load: indexes the planner has NEVER used (pk/unique excluded: those are constraints)'
SELECT s.relname AS "table", s.indexrelname AS index,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
  FROM pg_stat_user_indexes s
  JOIN pg_index x ON x.indexrelid = s.indexrelid
 WHERE s.idx_scan = 0 AND NOT x.indisunique AND NOT x.indisprimary
 ORDER BY pg_relation_size(s.indexrelid) DESC, s.indexrelname;

\echo '--- load: redundant indexes (one leads with the other, same method and predicate)'
SELECT a.relname AS "table", ai.relname AS narrower, bi.relname AS wider
  FROM pg_index xa
  JOIN pg_index xb    ON xb.indrelid = xa.indrelid AND xb.indexrelid <> xa.indexrelid
  JOIN pg_class ai    ON ai.oid = xa.indexrelid
  JOIN pg_class bi    ON bi.oid = xb.indexrelid
  JOIN pg_class a     ON a.oid  = xa.indrelid
  JOIN pg_namespace n ON n.oid  = a.relnamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
   AND ai.relam = bi.relam
   AND pg_get_expr(xa.indpred, xa.indrelid) IS NOT DISTINCT FROM pg_get_expr(xb.indpred, xb.indrelid)
   AND length(xa.indkey::text) < length(xb.indkey::text)
   AND strpos(xb.indkey::text || ' ', xa.indkey::text || ' ') = 1
 ORDER BY 1, 2;

SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')         AS pgss_installed,
       EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_stat_statements') AS pgss_available
\gset

\echo '--- load: is pg_stat_statements there?'
\echo '        installed:' :pgss_installed '  available:' :pgss_available

\if :pgss_installed
\echo '--- load: top statements by total execution time'
SELECT calls,
       round(total_exec_time::numeric, 1) AS total_ms,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       round(max_exec_time::numeric, 2)   AS max_ms,
       rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS query
  FROM pg_stat_statements
 ORDER BY total_exec_time DESC
 LIMIT 20;

\echo '--- load: top statements by call count'
SELECT calls, round(mean_exec_time::numeric, 2) AS mean_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 100) AS query
  FROM pg_stat_statements
 ORDER BY calls DESC
 LIMIT 20;
\else
\echo '        pg_stat_statements is NOT installed: there are no per-statement timings.'
\echo '        Cloud SQL ships the library; turning it on is the flag'
\echo '        cloudsql.enable_pg_stat_statements plus CREATE EXTENSION - an owner'
\echo '        decision, because the flag restarts the instance.'
\endif
EOF_SQL
}

_spl_db_health_sql_vacuum() {
  cat <<'EOF_SQL'
\echo ''
\echo '--- vacuum: when each table was last cleaned, and how much of it is dead'
SELECT relname AS "table", n_live_tup, n_dead_tup,
       CASE WHEN n_live_tup + n_dead_tup > 0
            THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1) END AS dead_pct,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
       vacuum_count, autovacuum_count, analyze_count, autoanalyze_count
  FROM pg_stat_user_tables
 ORDER BY n_dead_tup DESC, relname;

\echo '--- vacuum: transaction-id age per relation (headroom = freeze ceiling - xid_age)'
SELECT c.relname AS relation, c.relkind AS kind,
       age(c.relfrozenxid)    AS xid_age,
       mxid_age(c.relminmxid) AS mxid_age
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
 ORDER BY age(c.relfrozenxid) DESC, c.relname
 LIMIT 20;

\echo '--- vacuum: database-wide id age against the freeze ceiling (wraparound risk)'
SELECT d.datname,
       age(d.datfrozenxid)                                  AS db_xid_age,
       current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age,
       current_setting('autovacuum_freeze_max_age')::bigint - age(d.datfrozenxid) AS headroom,
       round(100.0 * age(d.datfrozenxid)
             / current_setting('autovacuum_freeze_max_age')::bigint, 2) AS pct_of_ceiling
  FROM pg_database d
 ORDER BY age(d.datfrozenxid) DESC;

\echo '--- vacuum: per-table storage overrides (empty = every table runs on the instance defaults)'
SELECT c.relname AS relation, c.reloptions
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
   AND c.reloptions IS NOT NULL
 ORDER BY c.relname;

\echo '--- vacuum: autovacuum workers running right now'
SELECT pid, now() - xact_start AS running_for, left(COALESCE(query, ''), 70) AS query
  FROM pg_stat_activity
 WHERE query LIKE 'autovacuum:%'
 ORDER BY xact_start;
EOF_SQL
}

_spl_db_health_sql_structure() {
  cat <<'EOF_SQL'
\echo ''
\echo '--- structure: applied migrations (the schema this report describes)'
SELECT filename, applied_at
  FROM spool_schema_migrations
 ORDER BY filename;

\echo '--- structure: row-level security per table (rdb 0014/0021: a tenant table wants t/t)'
SELECT c.relname AS "table",
       c.relrowsecurity      AS rls_enabled,
       c.relforcerowsecurity AS rls_forced,
       EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped) AS has_tenant_id,
       (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = current_schema() AND c.relkind = 'r'
 ORDER BY c.relname;

\echo '--- structure: tenant_id tables with NO index leading on tenant_id'
SELECT c.relname AS "table"
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
 WHERE n.nspname = current_schema() AND c.relkind = 'r'
   AND NOT EXISTS (SELECT 1 FROM pg_index x WHERE x.indrelid = c.oid AND x.indkey[0] = a.attnum)
 ORDER BY c.relname;

\echo '--- structure: text columns whose NAME says timestamp or enum (a typing smell)'
SELECT c.relname AS "table", a.attname AS "column",
       format_type(a.atttypid, a.atttypmod) AS type, a.attnotnull AS not_null
  FROM pg_attribute a
  JOIN pg_class c     ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = current_schema() AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
   AND format_type(a.atttypid, a.atttypmod) IN ('text', 'character varying')
   AND (a.attname ~ '(_at|_ts|_time|_on)$' OR a.attname ~ '(^|_)(status|state|kind|type|role|provider|mode)$')
 ORDER BY 1, 2;

\echo '--- structure: CHECK constraints standing in for an enum type'
SELECT conrelid::regclass AS "table", conname,
       left(pg_get_constraintdef(oid), 90) AS definition
  FROM pg_constraint
 WHERE contype = 'c' AND connamespace = current_schema()::regnamespace
   AND pg_get_constraintdef(oid) LIKE '%ANY (ARRAY%'
 ORDER BY 1, 2;

\echo '--- structure: foreign keys'
SELECT conrelid::regclass AS "table", conname, confrelid::regclass AS "references",
       CASE confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                        WHEN 'r' THEN 'RESTRICT' WHEN 'd' THEN 'SET DEFAULT' END AS on_delete
  FROM pg_constraint
 WHERE contype = 'f' AND connamespace = current_schema()::regnamespace
 ORDER BY 1, 2;

\echo '--- structure: tenant_id columns that are NOT a foreign key to tenants (orphan risk)'
SELECT c.relname AS "table"
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
 WHERE n.nspname = current_schema() AND c.relkind = 'r'
   AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = c.oid AND k.contype = 'f' AND a.attnum = ANY (k.conkey))
 ORDER BY c.relname;

\echo '--- structure: the 0020 search column (tsvector) and what its indexes cost'
SELECT c.relname AS "table", a.attname AS "column",
       format_type(a.atttypid, a.atttypmod) AS type,
       a.attstorage AS storage,
       pg_size_pretty(COALESCE((SELECT sum(pg_relation_size(i.indexrelid))
                                  FROM pg_index i
                                 WHERE i.indrelid = c.oid AND a.attnum = ANY (i.indkey)), 0)) AS index_size
  FROM pg_attribute a
  JOIN pg_class c     ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = current_schema() AND a.atttypid = 'tsvector'::regtype AND NOT a.attisdropped
 ORDER BY 1, 2;

\echo '--- structure: retention - rows past their expires_at that the Sweep has not removed'
SELECT 'messages' AS "table", count(*) AS rows_total,
       count(*) FILTER (WHERE expires_at <= now())                      AS expired_now,
       count(*) FILTER (WHERE received_at < now() - interval '30 days') AS older_than_30d,
       count(*) FILTER (WHERE received_at < now() - interval '7 days')  AS older_than_7d,
       min(received_at) AS oldest, max(received_at) AS newest
  FROM messages
UNION ALL
SELECT 'deliveries', count(*), count(*) FILTER (WHERE expires_at <= now()),
       NULL, NULL, NULL, NULL
  FROM deliveries;

\echo '--- structure: deliveries by state (a queue that never drains shows up here)'
SELECT state, count(*) AS rows,
       count(*) FILTER (WHERE expires_at <= now()) AS expired,
       min(expires_at) AS earliest_expiry
  FROM deliveries
 GROUP BY state
 ORDER BY 2 DESC;

\echo '--- structure: the multipliers behind every per-tenant scan'
SELECT (SELECT count(*) FROM tenants)            AS tenants,
       (SELECT count(*) FROM boxes)              AS boxes,
       (SELECT count(*) FROM humans)             AS humans,
       (SELECT count(*) FROM tenant_memberships) AS memberships,
       (SELECT count(*) FROM channels)           AS channels;
EOF_SQL
}

# spl_db_health_cloudsql -> the Cloud SQL instance itself: tier, disk, backups,
# PITR, maintenance window, insights, and the most recent backup runs.
# Read-only: describe and list only, every call pinned to $GCP_ACCOUNT.
spl_db_health_cloudsql() {
  local rc=0
  echo
  echo "--- cloudsql: instance $SPL_SQL_INSTANCE"
  gcloud sql instances describe "$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --format='yaml(name, databaseVersion, state, gceZone, region,
      settings.tier, settings.edition, settings.availabilityType, settings.dataDiskType,
      settings.dataDiskSizeGb, settings.storageAutoResize, settings.storageAutoResizeLimit,
      settings.backupConfiguration, settings.maintenanceWindow, settings.insightsConfig,
      settings.databaseFlags, settings.deletionProtectionEnabled,
      settings.ipConfiguration.sslMode, settings.userLabels)' || rc=1

  echo
  echo "--- cloudsql: the last 10 backup runs (automated and on demand)"
  gcloud sql backups list --instance="$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --limit=10 --format='table(id, type, status, windowStartTime, enqueuedTime, location)' || rc=1

  echo
  echo "--- cloudsql: disk and CPU as the platform measures them (last 24 h)"
  spl_db_health_metrics || rc=1
  return $rc
}

# spl_db_health_metrics -> the Cloud Monitoring series the size question needs
# (bytes used against the disk quota, CPU, backends, id utilization) over the
# last 24 h, as latest / min / max plus the 24 h delta, which is the growth
# rate. `gcloud monitoring` has no time-series verb (measured 2026-09-21:
# "Invalid choice: 'time-series'"), so this reads the v3 REST endpoint with an
# access token for $GCP_ACCOUNT. The token goes in a header, never in argv.
spl_db_health_metrics() {
  do_require_bin curl python3 || return 1
  local since until m tok rc=0
  until="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  since="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" || return 1
  tok="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$tok" ]] || { do_log "ERROR no access token for $GCP_ACCOUNT: no platform metrics"; return 1; }
  for m in database/disk/bytes_used database/disk/quota database/cpu/utilization \
           database/postgresql/num_backends database/postgresql/transaction_id_utilization; do
    printf '%-50s ' "${m#database/}"
    curl -s -G "https://monitoring.googleapis.com/v3/projects/$SPL_PROJECT/timeSeries" \
      -H "Authorization: Bearer $tok" \
      --data-urlencode "filter=metric.type=\"cloudsql.googleapis.com/$m\" AND resource.labels.database_id=\"$SPL_PROJECT:$SPL_SQL_INSTANCE\"" \
      --data-urlencode "interval.startTime=$since" \
      --data-urlencode "interval.endTime=$until" |
      spl_db_health_series || rc=1
  done
  return $rc
}

# spl_db_health_series -> one line out of a Monitoring v3 timeSeries response
# on stdin: n points, the newest and oldest value, min, max and the delta
# across the window (the growth rate the size question asks for).
spl_db_health_series() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("no data (%s)" % e); sys.exit(0)
if "error" in d:
    print("error: %s" % d["error"].get("message", d["error"])); sys.exit(0)
pts = []
for s in d.get("timeSeries", []):
    for p in s.get("points", []):
        v = p.get("value", {})
        val = v.get("int64Value", v.get("doubleValue", v.get("boolValue")))
        if val is None:
            continue
        pts.append((p["interval"]["endTime"], float(val)))
if not pts:
    print("no points in the window"); sys.exit(0)
pts.sort()
oldest, newest = pts[0][1], pts[-1][1]
lo = min(v for _, v in pts); hi = max(v for _, v in pts)
def f(x):
    return "%.4f" % x if abs(x) < 10 else "%.0f" % x
print("n=%d newest=%s oldest=%s min=%s max=%s delta_24h=%s" % (
    len(pts), f(newest), f(oldest), f(lo), f(hi), f(newest - oldest)))
'
}
