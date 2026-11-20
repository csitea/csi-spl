-- 0301_topic_loops.sql - discussion loops (spec 182 v0.4 sections 5.1, 5.2
-- and 7.1, build row L1). Forward-only, idempotent (a second apply changes
-- nothing).
--
-- Owner HUM-10 (t1 #spool-hub-devel, topic f08c0c58, msgs a0c4e227,
-- b20e28e9): a saved prompt on a discussion that runs on an agent reply or a
-- human post; msg eae9e64f: "the loop replies must not be shown as separate
-- prompts, they should just run in the background".
--
--   topic_loops       one row per loop (answer 6 B: several per topic): its
--                     prompt, its checked triggers (the eleven of spec 182
--                     1.2; Q11 C dropped before_human_reply) and the field each needs (the n of "each n
--                     minutes", the keyword, the idle n, the daily time and
--                     zone; set exactly when its trigger is checked), its
--                     three due times (every_*, the idle count after a human
--                     post, the daily time), its state, its author, its hour counter (answer
--                     4 B: at most 12 fires an hour) and the agent whose
--                     answer it awaits (Q10 A, spec 182 4.4). The cap check
--                     and the count are ONE UPDATE (store/topic_loop_postgres.go
--                     CountTopicLoopFire), and so is the ticker's claim of the
--                     due loops (ClaimDueTopicLoops), so two hub instances
--                     never fire past the cap or fire one tick twice.
--   messages.loop_id  the loop a stored loop prompt message was fired by;
--                     NULL on every other row. Such a row is delivered to
--                     the agent and kept as the record of the fire, but no
--                     person sees it (spec 182 5.2): the views, the topic
--                     list, the fallback reads and the topic head leave it
--                     out, for every viewer.
--
-- The topic head (rdb 0144, add from 0182): a loop row is no line of the
-- head. topic_head_expected (the rebuild and topic_head_diff) reads the
-- latest line of each part from the topic's other rows, and the insert mark
-- does not mark a loop row, so its insert touches no head. Its archived
-- flag still counts in archived_rows, as the walk's archived hide
-- (store/topic_archive_postgres.go archivedTopicHideSQL) reads every row: a
-- head and the walk agree on a topic whatever rows it holds. A part or a
-- topic with only loop rows has no head row. topic_head_add is unchanged: it
-- is only handed the msg_ids the insert mark wrote.
--
-- Live-data safety: one new, empty table; messages gains a NULL column with
-- no default, a catalog-only change (no rewrite of the hub's largest table,
-- every existing row reads NULL); messages_task_received is rebuilt (the
-- last block says how). Two functions are replaced in place with
-- the same signatures; no stored head changes, since no row has a loop_id
-- yet. RLS: the messages policies cover the new column; topic_loops gets
-- its own below. Runtime grants: the default privileges of
-- spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: apply before a hub that writes either (spec 182 row L2); an
-- older hub names neither.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS topic_loops (
    tenant_id      text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    loop_id        uuid        NOT NULL,
    task_id        uuid        NOT NULL,
    prompt         text        NOT NULL CHECK (prompt <> '' AND length(prompt) <= 4000),
    triggers       text[]      NOT NULL CHECK (triggers <@ ARRAY['after_agent_reply', 'before_agent_reply', 'after_human_reply',
                                                                 'every_hour', 'every_n_minutes',
                                                                 'post_has_keyword', 'post_has_file', 'blocker_posted',
                                                                 'no_reply_after_human', 'issue_status_changed', 'daily_at']
                                               AND cardinality(triggers) >= 1),
    interval_min   integer     CHECK (interval_min BETWEEN 5 AND 1440),
    next_due_at    timestamptz,
    keyword        text        CHECK (keyword <> '' AND length(keyword) <= 200),
    idle_min       integer     CHECK (idle_min BETWEEN 5 AND 1440),
    idle_due_at    timestamptz,
    idle_post      uuid,
    daily_at       time,
    daily_tz       text        NOT NULL DEFAULT 'UTC' CHECK (daily_tz <> '' AND length(daily_tz) <= 64),
    daily_due_at   timestamptz,
    set_by         text        NOT NULL CHECK (set_by <> '' AND length(set_by) <= 64),
    set_at         timestamptz NOT NULL,
    state          text        NOT NULL DEFAULT 'on' CHECK (state IN ('on', 'paused')),
    hour_start     timestamptz,
    fires_in_hour  integer     NOT NULL DEFAULT 0 CHECK (fires_in_hour >= 0),
    fires_total    integer     NOT NULL DEFAULT 0 CHECK (fires_total >= 0),
    last_fired_at  timestamptz,
    awaiting       text        NOT NULL DEFAULT '' CHECK (length(awaiting) <= 64),
    awaiting_until timestamptz,
    PRIMARY KEY (tenant_id, loop_id),
    CHECK ((interval_min IS NOT NULL) = ('every_n_minutes' = ANY (triggers))),
    CHECK ((keyword IS NOT NULL) = ('post_has_keyword' = ANY (triggers))),
    CHECK ((idle_min IS NOT NULL) = ('no_reply_after_human' = ANY (triggers))),
    CHECK ((daily_at IS NOT NULL) = ('daily_at' = ANY (triggers)))
);

CREATE INDEX IF NOT EXISTS topic_loops_task ON topic_loops (tenant_id, task_id);
-- The time ticker's claim (store ClaimDueTopicLoops): the loops of every
-- workspace by their earliest due time; least() skips NULLs, and a loop
-- with no due time has a NULL key the claim's "<= now" never reads.
CREATE INDEX IF NOT EXISTS topic_loops_due ON topic_loops (least(next_due_at, idle_due_at, daily_due_at)) WHERE state = 'on';

-- RLS in the 0021 fail-closed NULLIF shape, as topic_pauses (rdb 0297).
ALTER TABLE topic_loops ENABLE ROW LEVEL SECURITY;
ALTER TABLE topic_loops FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON topic_loops;
CREATE POLICY tenant_scope ON topic_loops
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON topic_loops;
CREATE POLICY operator_scope ON topic_loops
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

DROP TRIGGER IF EXISTS change_stamp ON topic_loops;
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON topic_loops
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();

ALTER TABLE messages ADD COLUMN IF NOT EXISTS loop_id uuid NULL;

-- rdb 0144's topic_head_expected, a loop row left out of each part's latest
-- line (the FILTERs of p0) and kept in its archived count. A part with only
-- loop rows (p0.msg_id NULL) is no part, a topic with no other row no head.
CREATE OR REPLACE FUNCTION topic_head_expected(tns text[], tks uuid[])
    RETURNS TABLE (tenant_id text, task_id uuid, part text, channel text, dm_a text, dm_b text,
                   last_at timestamptz, last_msg_id uuid, valid_until timestamptz,
                   dm_last_at timestamptz, dm_last_msg_id uuid, card_archived boolean, archived_rows integer)
    LANGUAGE sql STABLE
    AS $$
    WITH l AS (
        SELECT m.tenant_id, m.task_id, m.msg_id, m.received_at, m.expires_at, m.archived_at, m.channel,
               m.loop_id IS NULL AS line,
               CASE WHEN m.channel IS NULL THEN least(m.from_id, m.to_id) END AS dm_a,
               CASE WHEN m.channel IS NULL THEN greatest(m.from_id, m.to_id) END AS dm_b
        FROM topic_head_set(tns, tks) s
        CROSS JOIN LATERAL (SELECT * FROM messages m WHERE m.tenant_id = s.tn AND m.task_id = s.tk) m
    ), p0 AS (
        -- One row per part: its latest line and its archived rows. One
        -- grouping, no join between two aggregates (rdb 0144 says why).
        SELECT l.tenant_id, l.task_id, l.channel, l.dm_a, l.dm_b,
               (array_agg(l.received_at ORDER BY l.received_at DESC, l.msg_id DESC) FILTER (WHERE l.line))[1] AS received_at,
               (array_agg(l.msg_id ORDER BY l.received_at DESC, l.msg_id DESC) FILTER (WHERE l.line))[1] AS msg_id,
               (array_agg(l.expires_at ORDER BY l.received_at DESC, l.msg_id DESC) FILTER (WHERE l.line))[1] AS expires_at,
               (count(*) FILTER (WHERE l.archived_at IS NOT NULL))::int AS archived
        FROM l
        GROUP BY l.tenant_id, l.task_id, l.channel, l.dm_a, l.dm_b
    ), h AS (
        SELECT p0.tenant_id, p0.task_id,
               (array_agg(p0.received_at ORDER BY p0.received_at DESC, p0.msg_id DESC) FILTER (WHERE p0.msg_id IS NOT NULL))[1] AS last_at,
               (array_agg(p0.msg_id ORDER BY p0.received_at DESC, p0.msg_id DESC) FILTER (WHERE p0.msg_id IS NOT NULL))[1] AS last_msg_id,
               (array_agg(p0.received_at ORDER BY p0.received_at DESC, p0.msg_id DESC)
                    FILTER (WHERE p0.msg_id IS NOT NULL AND p0.channel IS NULL))[1] AS dm_last_at,
               (array_agg(p0.msg_id ORDER BY p0.received_at DESC, p0.msg_id DESC)
                    FILTER (WHERE p0.msg_id IS NOT NULL AND p0.channel IS NULL))[1] AS dm_last_msg_id,
               min(p0.expires_at) AS valid_until,
               sum(p0.archived)::int AS archived_rows
        FROM p0 GROUP BY p0.tenant_id, p0.task_id
    )
    SELECT p0.tenant_id, p0.task_id, topic_head_part(p0.channel, p0.dm_a, p0.dm_b), p0.channel, p0.dm_a, p0.dm_b,
           p0.received_at, p0.msg_id, p0.expires_at, NULL::timestamptz, NULL::uuid, NULL::boolean, NULL::integer
    FROM p0 WHERE p0.msg_id IS NOT NULL
    UNION ALL
    SELECT h.tenant_id, h.task_id, NULL, NULL, NULL, NULL, h.last_at, h.last_msg_id, h.valid_until,
           h.dm_last_at, h.dm_last_msg_id,
           coalesce((SELECT c.archived_at IS NOT NULL FROM messages c
                     WHERE c.tenant_id = h.tenant_id AND c.msg_id = h.task_id), false),
           h.archived_rows
    FROM h WHERE h.last_msg_id IS NOT NULL
$$;

-- rdb 0144's insert mark: a loop row inserted unarchived marks nothing (it
-- moves no head); arriving archived it marks a rebuild like any row, since
-- it counts in archived_rows.
CREATE OR REPLACE FUNCTION topic_head_mark_ins_trg() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    add text;
BEGIN
    SELECT string_agg(CASE WHEN n.archived_at IS NULL
               THEN chr(30) || 'a' || chr(31) || n.tenant_id || chr(31) || n.task_id::text || chr(31) || n.msg_id::text
               ELSE chr(30) || 'r' || chr(31) || n.tenant_id || chr(31) || n.task_id::text || chr(31)
                 || chr(30) || 'r' || chr(31) || n.tenant_id || chr(31) || n.msg_id::text || chr(31) END, '')
      INTO add FROM topic_head_new n
     WHERE n.loop_id IS NULL OR n.archived_at IS NOT NULL;
    IF add IS NOT NULL THEN
        PERFORM topic_head_append(add);
        PERFORM set_config('app.topic_head_last', '', true);
    END IF;
    RETURN NULL;
END
$$;

-- messages_task_received (rdb 0022, covering since 0083) gains loop_id and
-- is_private_scope in its INCLUDE: the unanswered sweep's k0 pick (spec 182
-- row L2b) and the topic walks filter "loop_id IS NULL", and without the
-- column every such probe reads the heap (R7 of L2b, msg 652b433f: k0 fell
-- from an Index Only Scan, 1 168 buffers, to a Seq Scan, 10 031 buffers,
-- plus a sort spilling 420 temp pages; with the column 892 buffers, no temp;
-- n=3 on 59 559 rows, as a role that skips RLS). messages is FORCE row level
-- security (0014) and its policies read is_private_scope (0219), so under
-- RLS, as the sweep runs (app.rls_scope operator), loop_id alone still reads
-- the heap; with both columns the pick is an Index Only Scan
-- (TestTopicLoopSweepPickIndexOnly).
-- Built under a new name, then the old one dropped and the new one renamed,
-- all in this file's transaction: plain CREATE INDEX (as 0143, 0156; the
-- runner applies a file in one transaction, so no CONCURRENTLY) holds a
-- SHARE lock on messages for the build (writes wait, reads go on), the drop
-- and the rename an ACCESS EXCLUSIVE lock for a catalogue change only; the
-- lock_timeout above refuses the file rather than queue behind a long
-- reader. Skipped when the index already carries both, so a second apply
-- builds nothing.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = current_schema()
            AND indexname = 'messages_task_received' AND indexdef LIKE '%parent_task_id, loop_id, is_private_scope)') THEN
        DROP INDEX IF EXISTS messages_task_received_loop;
        CREATE INDEX messages_task_received_loop
            ON messages (tenant_id, task_id, received_at, msg_id)
            INCLUDE (expires_at, channel, from_id, from_box, to_id, to_box, kind, parent_task_id, loop_id, is_private_scope);
        DROP INDEX IF EXISTS messages_task_received;
        ALTER INDEX messages_task_received_loop RENAME TO messages_task_received;
    END IF;
END
$$;
