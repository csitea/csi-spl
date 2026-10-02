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
