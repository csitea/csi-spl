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
