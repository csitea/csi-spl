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
