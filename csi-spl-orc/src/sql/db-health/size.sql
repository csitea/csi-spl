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
