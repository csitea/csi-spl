-- db-maint/facts.sql - the raw numbers of do_spl_db_maint's before and after
-- snapshots, one '|'-separated row per line (psql -At -F'|'). READ ONLY: the
-- caller runs it inside BEGIN READ ONLY with default_transaction_read_only=on
-- and the operator row-level-security scope, and ends in ROLLBACK.
--
-- Why the width probes (TW / IW) and not pg_stats: pg_stats hides every
-- column of a table whose row security is active for the reader, and every
-- tenant table is FORCE RLS (rdb 0014) for the owner too, who holds no
-- BYPASSRLS. So the bloat estimate measures the average row and key width on
-- at most :sample rows per table. Only sizes leave the database, never a value.
--
-- T|schema|table|n_live|n_dead|n_mod_since_analyze|relpages|reltuples|heap_bytes|total_bytes|fillfactor|last_vacuum|last_autovacuum|last_analyze|last_autoanalyze
SELECT 'T', s.schemaname, s.relname, s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze,
       c.relpages, greatest(c.reltuples, 0)::bigint,
       pg_relation_size(s.relid), pg_total_relation_size(s.relid),
       COALESCE((SELECT option_value FROM pg_options_to_table(c.reloptions) WHERE option_name = 'fillfactor'), '100'),
       COALESCE(to_char(s.last_vacuum      AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''),
       COALESCE(to_char(s.last_autovacuum  AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''),
       COALESCE(to_char(s.last_analyze     AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''),
       COALESCE(to_char(s.last_autoanalyze AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')
  FROM pg_stat_user_tables s
  JOIN pg_class c ON c.oid = s.relid
 ORDER BY pg_total_relation_size(s.relid) DESC, s.relname;

-- I|schema|index|table|relpages|reltuples|bytes|valid|am|fillfactor|has_expression|idx_scan
SELECT 'I', s.schemaname, s.indexrelname, s.relname, ci.relpages, greatest(ci.reltuples, 0)::bigint,
       pg_relation_size(s.indexrelid), i.indisvalid, am.amname,
       COALESCE((SELECT option_value FROM pg_options_to_table(ci.reloptions) WHERE option_name = 'fillfactor'), '90'),
       (0 = ANY (i.indkey::int2[])), s.idx_scan
  FROM pg_stat_user_indexes s
  JOIN pg_index i  ON i.indexrelid = s.indexrelid
  JOIN pg_class ci ON ci.oid = s.indexrelid
  JOIN pg_am am    ON am.oid = ci.relam
 ORDER BY pg_relation_size(s.indexrelid) DESC, s.indexrelname;

-- TW|schema|table|rows_sampled|avg_row_bytes
SELECT format('SELECT %L, %L, %L, count(*), COALESCE(round(avg(pg_column_size(s.*))), 0) FROM (SELECT * FROM %I.%I LIMIT %s) s',
              'TW', schemaname, relname, schemaname, relname, :sample)
  FROM pg_stat_user_tables
 WHERE n_live_tup > 0
 ORDER BY relname
\gexec

-- IW|schema|index|rows_sampled|avg_key_bytes (btree, plain columns only)
SELECT format('SELECT %L, %L, %L, count(*), COALESCE(round(avg(%s)), 0) FROM (SELECT * FROM %I.%I LIMIT %s) s',
              'IW', s.schemaname, s.indexrelname,
              string_agg(format('COALESCE(pg_column_size(s.%I), 0)', a.attname), ' + ' ORDER BY k.ord),
              s.schemaname, s.relname, :sample)
  FROM pg_stat_user_indexes s
  JOIN pg_index i  ON i.indexrelid = s.indexrelid
  JOIN pg_class ci ON ci.oid = s.indexrelid
  JOIN pg_am am    ON am.oid = ci.relam AND am.amname = 'btree'
  CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
 WHERE NOT (0 = ANY (i.indkey::int2[]))
 GROUP BY s.schemaname, s.indexrelname, s.relname
 ORDER BY s.indexrelname
\gexec
