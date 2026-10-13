-- msg-purge/purge.sql: delete a listed set of messages of ONE tenant and
-- archive their topics, in ONE transaction under the tenant's RLS context
-- (do_spl_msg_purge, csi-spl-orc/src/bash/run/spl-msg-purge.func.sh).
--
-- psql variables (quoted by psql, never spliced): tenant, pairs
-- ("<msg_id>:<task_id>,..."), by (archived_by), dry (1|0), journal (the
-- undo file; /dev/null on a dry run).
--
-- Delete = the hub's own: a hard DELETE FROM messages (store DeleteMessage /
-- DeleteTopic); there is no message soft delete. Every child row that goes
-- with it (each ON DELETE CASCADE foreign key onto messages, read from
-- pg_constraint so a new one is not missed) is written to the journal first.
-- Archive = the hub's own (store SetArchived, rdb 0065): archived_at and
-- archived_by on the topic's card, the first remaining is_parent=1 row of
-- the task, and on its DM mirrors (mirror_of).
--
-- Output lines: MISSING|msg|task, TOPIC|task|state|card|rest, CHILD|table|n,
-- MIRRORS|n, N|n|nids|ok, and on a real run DELETE|n, STAMP|n, COMMITTED.
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT date_trunc('second', now()) AS stamp \gset
CREATE TEMP TABLE mp_list ON COMMIT DROP AS
SELECT split_part(p, ':', 1)::uuid AS msg_id, split_part(p, ':', 2)::uuid AS task_id
  FROM unnest(string_to_array(:'pairs', ',')) AS p;
CREATE TEMP TABLE mp_tasks ON COMMIT DROP AS SELECT DISTINCT task_id FROM mp_list;
-- Every row of the listed topics, locked: an edit or archive waits for us.
SELECT count(*) AS locked FROM (SELECT 1 FROM messages m WHERE m.tenant_id = :'tenant'
   AND m.task_id IN (SELECT task_id FROM mp_tasks) FOR UPDATE) x \gset

CREATE TEMP TABLE mp_hit ON COMMIT DROP AS
SELECT l.msg_id, l.task_id, m.msg_id AS found
  FROM mp_list l LEFT JOIN messages m
    ON m.tenant_id = :'tenant' AND m.msg_id = l.msg_id AND m.task_id = l.task_id;
SELECT 'MISSING|' || msg_id || '|' || task_id FROM mp_hit WHERE found IS NULL ORDER BY msg_id;

-- Each topic after the delete: GONE (no row left), ISSUE (an issue's
-- discussion: the hub archives it with its issue, so it is skipped), NOCARD
-- (rows left, none is_parent=1), ARCHIVED (already), or STAMP (its card).
CREATE TEMP TABLE mp_card ON COMMIT DROP AS
SELECT t.task_id, c.msg_id,
       (SELECT count(*) FROM messages r WHERE r.tenant_id = :'tenant' AND r.task_id = t.task_id
           AND r.msg_id NOT IN (SELECT msg_id FROM mp_list)) AS rest,
       CASE WHEN NOT EXISTS (SELECT 1 FROM messages r WHERE r.tenant_id = :'tenant' AND r.task_id = t.task_id
                               AND r.msg_id NOT IN (SELECT msg_id FROM mp_list)) THEN 'GONE'
            WHEN EXISTS (SELECT 1 FROM issues i WHERE i.tenant_id = :'tenant' AND i.task_id = t.task_id) THEN 'ISSUE'
            WHEN c.msg_id IS NULL THEN 'NOCARD'
            WHEN EXISTS (SELECT 1 FROM messages r WHERE r.tenant_id = :'tenant' AND r.task_id = t.task_id
                           AND r.archived_at IS NOT NULL AND r.msg_id NOT IN (SELECT msg_id FROM mp_list)) THEN 'ARCHIVED'
            ELSE 'STAMP' END AS state
  FROM mp_tasks t
  LEFT JOIN LATERAL (SELECT m.msg_id FROM messages m
     WHERE m.tenant_id = :'tenant' AND m.task_id = t.task_id AND m.is_parent = 1
       AND m.msg_id NOT IN (SELECT msg_id FROM mp_list)
     ORDER BY m.received_at, m.msg_id LIMIT 1) c ON true;
SELECT 'TOPIC|' || task_id || '|' || state || '|' || COALESCE(msg_id::text, '-') || '|' || rest
  FROM mp_card ORDER BY task_id;
CREATE TEMP TABLE mp_stamp ON COMMIT DROP AS
SELECT m.msg_id FROM messages m JOIN mp_card c ON c.state = 'STAMP' AND (m.msg_id = c.msg_id OR m.mirror_of = c.msg_id)
 WHERE m.tenant_id = :'tenant' AND m.archived_at IS NULL AND m.msg_id NOT IN (SELECT msg_id FROM mp_list);

-- The cascade children: every foreign key onto messages, with the columns
-- that hold tenant_id and msg_id. A cascade one level further down would
-- go unjournaled, so it refuses.
CREATE TEMP TABLE mp_fk ON COMMIT DROP AS
SELECT k.conrelid::regclass AS rel, k.confdeltype AS del,
       (SELECT a.attname FROM unnest(k.conkey, k.confkey) AS u(ck, fk)
          JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.ck
          JOIN pg_attribute f ON f.attrelid = k.confrelid AND f.attnum = u.fk WHERE f.attname = 'tenant_id') AS tcol,
       (SELECT a.attname FROM unnest(k.conkey, k.confkey) AS u(ck, fk)
          JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.ck
          JOIN pg_attribute f ON f.attrelid = k.confrelid AND f.attnum = u.fk WHERE f.attname = 'msg_id') AS mcol
  FROM pg_constraint k WHERE k.contype = 'f' AND k.confrelid = 'messages'::regclass;
SELECT format('SELECT %L || ''|'' || count(*) FROM %s c WHERE c.%I = %L AND c.%I IN (SELECT msg_id FROM mp_list)',
              'CHILD|' || rel::text, rel, tcol, :'tenant', mcol) FROM mp_fk ORDER BY rel::text \gexec
SELECT 'MIRRORS|' || count(*) FROM messages m WHERE m.tenant_id = :'tenant'
   AND m.mirror_of IN (SELECT msg_id FROM mp_list) AND m.msg_id NOT IN (SELECT msg_id FROM mp_list);

SELECT count(found) AS n, count(*) AS nids,
       count(found) = count(*)
       AND count(DISTINCT msg_id) = count(*)
       AND NOT EXISTS (SELECT 1 FROM mp_fk WHERE del <> 'c' OR tcol IS NULL OR mcol IS NULL)
       AND NOT EXISTS (SELECT 1 FROM pg_constraint d WHERE d.contype = 'f' AND d.confdeltype = 'c'
                         AND d.confrelid IN (SELECT rel FROM mp_fk)) AS ok,
       (SELECT count(*) FROM mp_stamp) AS nstamp
  FROM mp_hit \gset
\echo N|:n|:nids|:ok
\if :dry
ROLLBACK;
\elif :ok
-- The journal, BEFORE the delete: one line per row, "<table>\t<row json>".
\o :journal
SELECT '=meta' || E'\t' || jsonb_build_object('tenant', :'tenant', 'at', :'stamp'::timestamptz, 'by', :'by', 'n', :n)::text;
SELECT 'messages' || E'\t' || to_jsonb(m)::text FROM messages m
 WHERE m.tenant_id = :'tenant' AND m.msg_id IN (SELECT msg_id FROM mp_list) ORDER BY m.msg_id;
SELECT format('SELECT %L || E''\t'' || to_jsonb(c)::text FROM %s c WHERE c.%I = %L AND c.%I IN (SELECT msg_id FROM mp_list)',
              rel::text, rel, tcol, :'tenant', mcol) FROM mp_fk ORDER BY rel::text \gexec
SELECT '=archive' || E'\t' || jsonb_build_object('msg_id', msg_id, 'archived_at', :'stamp'::timestamptz)::text
  FROM mp_stamp ORDER BY msg_id;
\o
DELETE FROM messages WHERE tenant_id = :'tenant' AND msg_id IN (SELECT msg_id FROM mp_list);
SELECT :ROW_COUNT AS del, :ROW_COUNT = :n AS del_ok \gset
\echo DELETE|:del
UPDATE messages SET archived_at = :'stamp'::timestamptz, archived_by = :'by'
 WHERE tenant_id = :'tenant' AND archived_at IS NULL AND msg_id IN (SELECT msg_id FROM mp_stamp);
SELECT :ROW_COUNT AS upd, :'del_ok'::boolean AND :ROW_COUNT = :nstamp AS same \gset
\echo STAMP|:upd
\if :same
COMMIT;
\echo COMMITTED
\else
ROLLBACK;
\endif
\else
ROLLBACK;
\endif
