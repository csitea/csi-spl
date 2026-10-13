-- msg-purge/undo.sql: put back what one purge.sql run took, from its
-- journal on stdin (backslashes doubled for \copy's text format), in ONE
-- transaction under the tenant's RLS context (do_spl_msg_purge_undo).
--
-- psql variables: tenant, dry (1|0). It refuses unless the journal is this
-- tenant's, names only messages and its cascade children, and none of its
-- messages exists again. The archive stamps the purge set are cleared only
-- where they are still that stamp. Rows go back with every non-generated
-- column (search_tsv is recomputed).
--
-- Output lines: J|n messages|n archive|n child rows|ok, UNSTAMP|n,
-- RESTORED|n, COMMITTED.
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
CREATE TEMP TABLE mp_undo (tbl text, j jsonb) ON COMMIT DROP;
\copy mp_undo FROM pstdin
CREATE TEMP TABLE mp_rel ON COMMIT DROP AS
SELECT 'messages'::text AS tbl UNION
SELECT k.conrelid::regclass::text FROM pg_constraint k WHERE k.contype = 'f' AND k.confrelid = 'messages'::regclass;
SELECT count(*) FILTER (WHERE tbl = 'messages') AS n,
       count(*) FILTER (WHERE tbl = '=archive') AS na,
       count(*) FILTER (WHERE tbl NOT LIKE '=%' AND tbl <> 'messages') AS nc,
       COALESCE(count(*) FILTER (WHERE tbl = '=meta') = 1
       AND bool_and(tbl <> '=meta' OR j->>'tenant' = :'tenant')
       AND bool_and(tbl IN ('=meta', '=archive') OR tbl IN (SELECT tbl FROM mp_rel))
       AND bool_and(tbl <> 'messages' OR j->>'tenant_id' = :'tenant')
       AND NOT EXISTS (SELECT 1 FROM messages m JOIN mp_undo u ON u.tbl = 'messages'
                         AND m.tenant_id = :'tenant' AND m.msg_id = (u.j->>'msg_id')::uuid), false) AS ok
  FROM mp_undo \gset
\echo J|:n|:na|:nc|:ok
\if :ok
UPDATE messages SET archived_at = NULL, archived_by = NULL
 WHERE tenant_id = :'tenant' AND (msg_id, archived_at) IN
       (SELECT (j->>'msg_id')::uuid, (j->>'archived_at')::timestamptz FROM mp_undo WHERE tbl = '=archive');
\echo UNSTAMP|:ROW_COUNT
-- messages first, then each child table, every non-generated column.
SELECT format('INSERT INTO %s (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM jsonb_populate_recordset(NULL::%s, (SELECT jsonb_agg(j) FROM mp_undo WHERE tbl = %L))',
              t.tbl, c.cols, c.cols, t.tbl, t.tbl)
  FROM (SELECT DISTINCT tbl FROM mp_undo WHERE tbl NOT LIKE '=%') t,
  LATERAL (SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) AS cols FROM pg_attribute
            WHERE attrelid = t.tbl::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = '') c
 ORDER BY t.tbl <> 'messages', t.tbl \gexec
SELECT count(*) AS back, count(*) = :n AS same FROM messages m
 WHERE m.tenant_id = :'tenant' AND m.msg_id IN (SELECT (j->>'msg_id')::uuid FROM mp_undo WHERE tbl = 'messages') \gset
\echo RESTORED|:back
\if :dry
ROLLBACK;
\elif :same
COMMIT;
\echo COMMITTED
\else
ROLLBACK;
\endif
\else
ROLLBACK;
\endif
