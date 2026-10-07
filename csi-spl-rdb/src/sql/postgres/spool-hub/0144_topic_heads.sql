-- 0144_topic_heads.sql - one stored head row per topic, kept by triggers
-- (spec 099 v1.0 phase 1, T002: csi-spl-doc/specs/099-topic-head/spec.md
-- sections 3 and 4). Forward-only, idempotent (a second apply changes nothing).
--
-- Why: every topic list walks the tenant's messages newest first, one
-- recursive step per listed topic (store/view_postgres.go viewTopicsSQL). A
-- head holds the walk key - the topic's latest line, per channel or DM pair
-- part, and the archived flags - so a later read (T005) walks one index and
-- stops at LIMIT. Nothing reads these tables yet: this file only creates them
-- and keeps them right.
--
--   topic_heads         one row per topic: the latest line (any part), the
--                       latest DM line, valid_until (the earliest expiry
--                       among the KEY lines: each part's latest), the card
--                       rule and the count of archived rows
--   topic_head_parts    one row per channel ('c:<channel>') or DM pair
--                       ('d:<lesser id> <greater id>') of a topic
--   topic_head_tenants  the backfill mark: the head read serves a tenant only
--                       once topic_head_backfill has passed all of it
--
-- A head is a pure function of the topic's rows, expired or not: no clock is
-- read when it is written, so topic_head_diff can compare it with a rebuild
-- at any time. A head whose key line has expired is "due" and the read takes
-- the exact old path for it (spec 5.3).
--
-- One writer, applied at COMMIT (spec 4.2). Triggers on messages only MARK
-- the topics a transaction touched, in a transaction-local setting
-- (app.topic_head_marks*, as 0103 holds app.change_stamped): per statement
-- for INSERT and DELETE (one append for a whole bulk statement or sweep
-- chunk), per row for an UPDATE of a head column (UPDATE OF .. WHEN). One deferred
-- constraint trigger drains the marks at COMMIT: it locks every touched head
-- in (tenant_id, task_id) order - a placeholder INSERT .. ON CONFLICT DO
-- NOTHING, then SELECT .. FOR UPDATE, no advisory lock - and only then, in
-- new statements under READ COMMITTED, reads messages. A topic touched only
-- by inserts gets the incremental add of its new lines; any other topic, and
-- a head miss (a topic written before this file), gets one set-based rebuild.
--
-- Marks: an insert marks ('a', its topic, its msg_id); an update of a head
-- column or a delete marks ('r', the old and new topic). The card rule (a
-- topic whose card row, msg_id = task_id, is archived anywhere is hidden)
-- also marks the topic named by an ARCHIVED row's msg_id, since only an
-- archived row can change it. An edit, a kind change, a claim, a replay and
-- the search_sig backfill touch no head column and mark nothing.
--
-- Every function is SECURITY INVOKER and never switches the RLS scope: a
-- tenant-scoped writer writes its own tenant's heads (WITH CHECK holds it to
-- that), the operator scope (the sweep, the backfill, migrations) writes any.
-- The drain skips a topic whose tenant row is gone (as 0023's
-- message_period_counts_sub does): a tenant delete cascades the heads away.
-- No tenant_change_stamps trigger here: every head write is caused by a
-- messages write in the same transaction, which 0103 already stamps.
--
-- A later migration that updates messages marks its topics like any writer;
-- the drain runs once at its COMMIT.
--
-- Runtime grants: the default privileges of spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: any time before the hub that reads the tables (T005). The
-- current hub ignores them; the triggers keep them right under either hub.
-- After the DDL: topic_head_backfill over every topic (T006's action), then
-- topic_head_diff per tenant.

CREATE TABLE IF NOT EXISTS topic_heads (
    tenant_id      text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id        uuid        NOT NULL,
    last_at        timestamptz NOT NULL,
    last_msg_id    uuid        NOT NULL,
    dm_last_at     timestamptz NULL,
    dm_last_msg_id uuid        NULL,
    valid_until    timestamptz NOT NULL,
    card_archived  boolean     NOT NULL,
    archived_rows  integer     NOT NULL CHECK (archived_rows >= 0),
    rev            bigint      NOT NULL,
    changed_at     timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, task_id),
    CHECK ((dm_last_at IS NULL) = (dm_last_msg_id IS NULL))
);

CREATE INDEX IF NOT EXISTS topic_heads_last ON topic_heads (tenant_id, last_at DESC, task_id DESC);
CREATE INDEX IF NOT EXISTS topic_heads_dm_last ON topic_heads (tenant_id, dm_last_at DESC, task_id DESC)
    WHERE dm_last_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS topic_heads_valid_until ON topic_heads (tenant_id, valid_until);

CREATE TABLE IF NOT EXISTS topic_head_parts (
    tenant_id   text        NOT NULL,
    task_id     uuid        NOT NULL,
    part        text        NOT NULL,
    channel     text        NULL,
    dm_a        text        NULL,
    dm_b        text        NULL,
    last_at     timestamptz NOT NULL,
    last_msg_id uuid        NOT NULL,
    valid_until timestamptz NOT NULL,
    rev         bigint      NOT NULL,
    PRIMARY KEY (tenant_id, task_id, part),
    FOREIGN KEY (tenant_id, task_id) REFERENCES topic_heads (tenant_id, task_id) ON DELETE CASCADE,
    CHECK ((channel IS NULL) = (dm_a IS NOT NULL)),
    CHECK ((dm_a IS NULL) = (dm_b IS NULL))
);

CREATE INDEX IF NOT EXISTS topic_head_parts_channel ON topic_head_parts (tenant_id, channel, last_at DESC, task_id DESC)
    WHERE channel IS NOT NULL;

CREATE TABLE IF NOT EXISTS topic_head_tenants (
    tenant_id     text        PRIMARY KEY REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    backfilled_at timestamptz NULL
);

-- RLS in the 0021 fail-closed NULLIF shape (as 0127): a tenant reads and
-- writes only its own rows; the operator scope sees everything.
DO $$
DECLARE
    tb text;
BEGIN
    FOREACH tb IN ARRAY ARRAY['topic_heads', 'topic_head_parts', 'topic_head_tenants'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tb);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', tb);
        EXECUTE format('DROP POLICY IF EXISTS tenant_scope ON %I', tb);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, tb);
        EXECUTE format('DROP POLICY IF EXISTS operator_scope ON %I', tb);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, tb);
    END LOOP;
END
$$;

-- The part key of a line: its channel, or its DM pair (ids only: the read
-- door of a DM is an id, never a box).
CREATE OR REPLACE FUNCTION topic_head_part(channel text, dm_a text, dm_b text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT CASE WHEN channel IS NOT NULL THEN 'c:' || channel ELSE 'd:' || dm_a || ' ' || dm_b END $$;

-- The topic set of a call: (tns[i], tks[i]) distinct, in lock order
-- (tenant_id, task_id). Every table read below is driven from it through a
-- LATERAL index probe, and it is plpgsql so the planner takes its ROWS: the
-- planner cannot see through the RLS quals or the placeholders a bulk
-- statement just wrote, read topic_heads as 1 row, and a join of two sets
-- planned as a nested loop took 40 M probes for one 9 000-row INSERT.
CREATE OR REPLACE FUNCTION topic_head_set(tns text[], tks uuid[]) RETURNS TABLE (tn text, tk uuid)
    LANGUAGE plpgsql IMMUTABLE ROWS 1000 AS $$
BEGIN
    RETURN QUERY SELECT DISTINCT u.a, u.b FROM unnest(tns, tks) AS u (a, b) ORDER BY 1, 2;
END
$$;

-- What the heads and parts of the topics (tns[i], tks[i]) must be, read from
-- messages: one row per part (part NOT NULL), then one per head (part NULL).
-- The ONE definition: the rebuild writes it and topic_head_diff compares it.
CREATE OR REPLACE FUNCTION topic_head_expected(tns text[], tks uuid[])
    RETURNS TABLE (tenant_id text, task_id uuid, part text, channel text, dm_a text, dm_b text,
                   last_at timestamptz, last_msg_id uuid, valid_until timestamptz,
                   dm_last_at timestamptz, dm_last_msg_id uuid, card_archived boolean, archived_rows integer)
    LANGUAGE sql STABLE
    AS $$
    WITH l AS (
        SELECT m.tenant_id, m.task_id, m.msg_id, m.received_at, m.expires_at, m.archived_at, m.channel,
               CASE WHEN m.channel IS NULL THEN least(m.from_id, m.to_id) END AS dm_a,
               CASE WHEN m.channel IS NULL THEN greatest(m.from_id, m.to_id) END AS dm_b
        FROM topic_head_set(tns, tks) s
        CROSS JOIN LATERAL (SELECT * FROM messages m WHERE m.tenant_id = s.tn AND m.task_id = s.tk) m
    ), p AS (
        -- One row per part: its latest line and its archived rows. One
        -- grouping, no join between two aggregates: the planner reads each
        -- CTE as 1 row, and a join of two made 9 000 topics take 40 M probes.
        SELECT l.tenant_id, l.task_id, l.channel, l.dm_a, l.dm_b,
               (array_agg(l.received_at ORDER BY l.received_at DESC, l.msg_id DESC))[1] AS received_at,
               (array_agg(l.msg_id ORDER BY l.received_at DESC, l.msg_id DESC))[1] AS msg_id,
               (array_agg(l.expires_at ORDER BY l.received_at DESC, l.msg_id DESC))[1] AS expires_at,
               (count(*) FILTER (WHERE l.archived_at IS NOT NULL))::int AS archived
        FROM l
        GROUP BY l.tenant_id, l.task_id, l.channel, l.dm_a, l.dm_b
    ), h AS (
        SELECT p.tenant_id, p.task_id,
               (array_agg(p.received_at ORDER BY p.received_at DESC, p.msg_id DESC))[1] AS last_at,
               (array_agg(p.msg_id ORDER BY p.received_at DESC, p.msg_id DESC))[1] AS last_msg_id,
               (array_agg(p.received_at ORDER BY p.received_at DESC, p.msg_id DESC) FILTER (WHERE p.channel IS NULL))[1] AS dm_last_at,
               (array_agg(p.msg_id ORDER BY p.received_at DESC, p.msg_id DESC) FILTER (WHERE p.channel IS NULL))[1] AS dm_last_msg_id,
               min(p.expires_at) AS valid_until,
               sum(p.archived)::int AS archived_rows
        FROM p GROUP BY p.tenant_id, p.task_id
    )
    SELECT p.tenant_id, p.task_id, topic_head_part(p.channel, p.dm_a, p.dm_b), p.channel, p.dm_a, p.dm_b,
           p.received_at, p.msg_id, p.expires_at, NULL::timestamptz, NULL::uuid, NULL::boolean, NULL::integer
    FROM p
    UNION ALL
    SELECT h.tenant_id, h.task_id, NULL, NULL, NULL, NULL, h.last_at, h.last_msg_id, h.valid_until,
           h.dm_last_at, h.dm_last_msg_id,
           coalesce((SELECT c.archived_at IS NOT NULL FROM messages c
                     WHERE c.tenant_id = h.tenant_id AND c.msg_id = h.task_id), false),
           h.archived_rows
    FROM h
$$;

-- The head row is the lock (spec 4.2 point 3): a placeholder head for each
-- topic (it waits for an in-flight insert of the same key), then FOR UPDATE,
-- both in (tenant_id, task_id) order. A placeholder has last_at -infinity: a
-- head miss, which the add turns into a rebuild. READ COMMITTED only: the
-- callers read messages in the NEXT statement and need its fresh snapshot.
CREATE OR REPLACE FUNCTION topic_head_lock(tns text[], tks uuid[]) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'topic heads are written under READ COMMITTED only, not %', current_setting('transaction_isolation')
            USING HINT = 'spec 099 4.2: the drain reads messages in a fresh snapshot after it locks the heads';
    END IF;
    INSERT INTO topic_heads AS h (tenant_id, task_id, last_at, last_msg_id, valid_until, card_archived, archived_rows, rev, changed_at)
    SELECT s.tn, s.tk, '-infinity', '00000000-0000-0000-0000-000000000000', '-infinity', false, 0, 0, clock_timestamp()
    FROM topic_head_set(tns, tks) s
    ON CONFLICT (tenant_id, task_id) DO NOTHING;
    PERFORM 1 FROM topic_head_set(tns, tks) s
        CROSS JOIN LATERAL (SELECT 1 FROM topic_heads h WHERE h.tenant_id = s.tn AND h.task_id = s.tk FOR UPDATE) x;
END
$$;

-- Rebuild the topics (tns[i], tks[i]) from messages, set-based: lock, then
-- ONE statement upserts the parts that changed and every head whose columns
-- or parts changed (rev + 1); the stale parts and the heads of topics with
-- no row left are then deleted by primary key.
CREATE OR REPLACE FUNCTION topic_head_rebuild(tns text[], tks uuid[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    st_tn   text[];
    st_tk   uuid[];
    st_part text[];
    go_tn   text[];
    go_tk   uuid[];
BEGIN
    PERFORM topic_head_lock(tns, tks);
    WITH e AS MATERIALIZED (
        SELECT x.* FROM topic_head_expected(tns, tks) x
    ), up AS (
        INSERT INTO topic_head_parts AS tp (tenant_id, task_id, part, channel, dm_a, dm_b, last_at, last_msg_id, valid_until, rev)
        SELECT e.tenant_id, e.task_id, e.part, e.channel, e.dm_a, e.dm_b, e.last_at, e.last_msg_id, e.valid_until, 1
        FROM e WHERE e.part IS NOT NULL
        ON CONFLICT (tenant_id, task_id, part) DO UPDATE
            SET channel = EXCLUDED.channel, dm_a = EXCLUDED.dm_a, dm_b = EXCLUDED.dm_b, last_at = EXCLUDED.last_at,
                last_msg_id = EXCLUDED.last_msg_id, valid_until = EXCLUDED.valid_until, rev = tp.rev + 1
            WHERE (tp.channel, tp.dm_a, tp.dm_b, tp.last_at, tp.last_msg_id, tp.valid_until)
                IS DISTINCT FROM (EXCLUDED.channel, EXCLUDED.dm_a, EXCLUDED.dm_b, EXCLUDED.last_at, EXCLUDED.last_msg_id, EXCLUDED.valid_until)
        RETURNING tp.tenant_id, tp.task_id
    ), stored AS (
        SELECT p.tenant_id, p.task_id, p.part FROM topic_head_set(tns, tks) s
        CROSS JOIN LATERAL (SELECT tp.tenant_id, tp.task_id, tp.part FROM topic_head_parts tp
                            WHERE tp.tenant_id = s.tn AND tp.task_id = s.tk) p
    ), stale AS (
        SELECT stored.tenant_id, stored.task_id, stored.part FROM stored
        EXCEPT
        SELECT e.tenant_id, e.task_id, e.part FROM e WHERE e.part IS NOT NULL
    ), moved AS (
        SELECT up.tenant_id, up.task_id FROM up UNION SELECT stale.tenant_id, stale.task_id FROM stale
    ), heads AS (
        -- Every head exists (topic_head_lock), so this always updates. The
        -- source rev only flags "a part of this topic moved" (1) for the
        -- WHERE: the stored rev is what is bumped.
        INSERT INTO topic_heads AS h (tenant_id, task_id, last_at, last_msg_id, dm_last_at, dm_last_msg_id, valid_until,
                                      card_archived, archived_rows, rev, changed_at)
        SELECT e.tenant_id, e.task_id, e.last_at, e.last_msg_id, e.dm_last_at, e.dm_last_msg_id, e.valid_until,
               e.card_archived, e.archived_rows, ((e.tenant_id, e.task_id) IN (SELECT moved.tenant_id, moved.task_id FROM moved))::int,
               clock_timestamp()
        FROM e WHERE e.part IS NULL
        ON CONFLICT (tenant_id, task_id) DO UPDATE
            SET last_at = EXCLUDED.last_at, last_msg_id = EXCLUDED.last_msg_id, dm_last_at = EXCLUDED.dm_last_at,
                dm_last_msg_id = EXCLUDED.dm_last_msg_id, valid_until = EXCLUDED.valid_until,
                card_archived = EXCLUDED.card_archived, archived_rows = EXCLUDED.archived_rows,
                rev = h.rev + 1, changed_at = EXCLUDED.changed_at
            WHERE EXCLUDED.rev = 1
               OR (h.last_at, h.last_msg_id, h.dm_last_at, h.dm_last_msg_id, h.valid_until, h.card_archived, h.archived_rows)
                  IS DISTINCT FROM (EXCLUDED.last_at, EXCLUDED.last_msg_id, EXCLUDED.dm_last_at, EXCLUDED.dm_last_msg_id,
                                    EXCLUDED.valid_until, EXCLUDED.card_archived, EXCLUDED.archived_rows)
        RETURNING h.task_id
    ), gone AS (
        SELECT s.tn, s.tk FROM topic_head_set(tns, tks) s
        EXCEPT
        SELECT e.tenant_id, e.task_id FROM e WHERE e.part IS NULL
    )
    SELECT (SELECT array_agg(stale.tenant_id) FROM stale), (SELECT array_agg(stale.task_id) FROM stale),
           (SELECT array_agg(stale.part) FROM stale),
           (SELECT array_agg(gone.tn ORDER BY gone.tn, gone.tk) FROM gone), (SELECT array_agg(gone.tk ORDER BY gone.tn, gone.tk) FROM gone),
           (SELECT count(*) FROM heads)
      INTO st_tn, st_tk, st_part, go_tn, go_tk;
    FOR i IN 1 .. coalesce(array_length(st_tn, 1), 0) LOOP
        DELETE FROM topic_head_parts WHERE tenant_id = st_tn[i] AND task_id = st_tk[i] AND part = st_part[i];
    END LOOP;
    FOR i IN 1 .. coalesce(array_length(go_tn, 1), 0) LOOP
        DELETE FROM topic_heads WHERE tenant_id = go_tn[i] AND task_id = go_tk[i];
    END LOOP;
END
$$;

-- The incremental add: the lines msgs[i] were inserted into (tns[i], tks[i])
-- and nothing else touched those topics in this transaction. A head miss
-- (a placeholder: the topic predates this file, or its head was lost) is
-- rebuilt first (spec 4.2 point 4); the add then finds its new lines already
-- there and moves nothing. Otherwise each part keeps the greater of its
-- latest line and the new lines' latest, and each head whose parts moved is
-- folded from its parts: last over every part, dm_last over the DM parts,
-- valid_until the earliest part expiry. Archived rows are not inserted here
-- (an insert with archived_at set is marked for a rebuild), so the archived
-- columns stay.
CREATE OR REPLACE FUNCTION topic_head_add(tns text[], tks uuid[], msgs uuid[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    miss_tn text[];
    miss_tk uuid[];
    up_tn   text[];
    up_tk   uuid[];
BEGIN
    PERFORM topic_head_lock(tns, tks);
    SELECT array_agg(s.tn), array_agg(s.tk) INTO miss_tn, miss_tk
    FROM topic_head_set(tns, tks) s
    CROSS JOIN LATERAL (SELECT 1 FROM topic_heads h
                        WHERE h.tenant_id = s.tn AND h.task_id = s.tk AND h.last_at = '-infinity') x;
    IF miss_tn IS NOT NULL THEN
        PERFORM topic_head_rebuild(miss_tn, miss_tk);
    END IF;

    WITH l AS (
        SELECT m.tenant_id, m.task_id, m.msg_id, m.received_at, m.expires_at, m.channel,
               CASE WHEN m.channel IS NULL THEN least(m.from_id, m.to_id) END AS dm_a,
               CASE WHEN m.channel IS NULL THEN greatest(m.from_id, m.to_id) END AS dm_b
        FROM unnest(tns, tks, msgs) AS u (tn, tk, mid)
        CROSS JOIN LATERAL (SELECT * FROM messages m WHERE m.tenant_id = u.tn AND m.msg_id = u.mid AND m.task_id = u.tk) m
    ), p AS (
        SELECT l.tenant_id, l.task_id, l.channel, l.dm_a, l.dm_b,
               (array_agg(l.received_at ORDER BY l.received_at DESC, l.msg_id DESC))[1] AS received_at,
               (array_agg(l.msg_id ORDER BY l.received_at DESC, l.msg_id DESC))[1] AS msg_id,
               (array_agg(l.expires_at ORDER BY l.received_at DESC, l.msg_id DESC))[1] AS expires_at
        FROM l GROUP BY l.tenant_id, l.task_id, l.channel, l.dm_a, l.dm_b
    ), up AS (
        INSERT INTO topic_head_parts AS tp (tenant_id, task_id, part, channel, dm_a, dm_b, last_at, last_msg_id, valid_until, rev)
        SELECT p.tenant_id, p.task_id, topic_head_part(p.channel, p.dm_a, p.dm_b), p.channel, p.dm_a, p.dm_b,
               p.received_at, p.msg_id, p.expires_at, 1
        FROM p
        ON CONFLICT (tenant_id, task_id, part) DO UPDATE
            SET last_at = EXCLUDED.last_at, last_msg_id = EXCLUDED.last_msg_id, valid_until = EXCLUDED.valid_until,
                rev = tp.rev + 1
            WHERE (EXCLUDED.last_at, EXCLUDED.last_msg_id) > (tp.last_at, tp.last_msg_id)
        RETURNING tp.tenant_id, tp.task_id
    )
    SELECT array_agg(d.tenant_id), array_agg(d.task_id) INTO up_tn, up_tk
    FROM (SELECT DISTINCT up.tenant_id, up.task_id FROM up) d;
    IF up_tn IS NULL THEN
        RETURN;
    END IF;

    -- The fold, as an upsert on the locked heads (it always updates); the
    -- archived columns are not in its SET.
    INSERT INTO topic_heads AS h (tenant_id, task_id, last_at, last_msg_id, dm_last_at, dm_last_msg_id, valid_until,
                                  card_archived, archived_rows, rev, changed_at)
    SELECT s.tn, s.tk,
           (array_agg(tp.last_at ORDER BY tp.last_at DESC, tp.last_msg_id DESC))[1],
           (array_agg(tp.last_msg_id ORDER BY tp.last_at DESC, tp.last_msg_id DESC))[1],
           (array_agg(tp.last_at ORDER BY tp.last_at DESC, tp.last_msg_id DESC) FILTER (WHERE tp.channel IS NULL))[1],
           (array_agg(tp.last_msg_id ORDER BY tp.last_at DESC, tp.last_msg_id DESC) FILTER (WHERE tp.channel IS NULL))[1],
           min(tp.valid_until), false, 0, 1, clock_timestamp()
    FROM topic_head_set(up_tn, up_tk) s
    CROSS JOIN LATERAL (SELECT * FROM topic_head_parts tp WHERE tp.tenant_id = s.tn AND tp.task_id = s.tk) tp
    GROUP BY s.tn, s.tk
    ON CONFLICT (tenant_id, task_id) DO UPDATE
        SET last_at = EXCLUDED.last_at, last_msg_id = EXCLUDED.last_msg_id, dm_last_at = EXCLUDED.dm_last_at,
            dm_last_msg_id = EXCLUDED.dm_last_msg_id, valid_until = EXCLUDED.valid_until,
            rev = h.rev + 1, changed_at = EXCLUDED.changed_at;
END
$$;

-- The drain: marks is app.topic_head_marks, entries chr(30)-led, fields
-- chr(31)-split: kind ('a' = an insert, with its msg_id; 'r' = rebuild),
-- tenant, task, msg. Topics of a gone tenant are skipped. Every head is
-- locked first, sorted; then the insert-only topics get the add and the rest
-- one rebuild. One pass with window functions, no join of two sets.
CREATE OR REPLACE FUNCTION topic_head_apply_marks(marks text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    ks     text[];
    e_tn   text[];
    e_tk   uuid[];
    e_msg  uuid[];
    live   text[];
    all_tn text[];
    all_tk uuid[];
    re_tn  text[];
    re_tk  uuid[];
    a_tn   text[];
    a_tk   uuid[];
    a_msg  uuid[];
BEGIN
    SELECT array_agg(split_part(x, chr(31), 1)), array_agg(split_part(x, chr(31), 2)),
           array_agg(split_part(x, chr(31), 3)::uuid), array_agg(nullif(split_part(x, chr(31), 4), '')::uuid)
      INTO ks, e_tn, e_tk, e_msg
      FROM unnest(string_to_array(marks, chr(30))) AS x
     WHERE x <> '';
    IF ks IS NULL THEN
        RETURN;
    END IF;
    SELECT array_agg(d.tn) INTO live
    FROM (SELECT DISTINCT u.tn FROM unnest(e_tn) AS u (tn)) d
    WHERE EXISTS (SELECT 1 FROM tenants t WHERE t.tenant_id = d.tn);
    IF live IS NULL THEN
        RETURN;
    END IF;

    WITH e AS (
        SELECT u.k, u.tn, u.tk, u.msg,
               bool_and(u.k = 'a') OVER (PARTITION BY u.tn, u.tk) AS only_add,
               row_number() OVER (PARTITION BY u.tn, u.tk) AS rn
        FROM unnest(ks, e_tn, e_tk, e_msg) AS u (k, tn, tk, msg)
        WHERE u.tn = ANY (live)
    )
    SELECT array_agg(e.tn) FILTER (WHERE e.rn = 1), array_agg(e.tk) FILTER (WHERE e.rn = 1),
           array_agg(e.tn) FILTER (WHERE e.rn = 1 AND NOT e.only_add), array_agg(e.tk) FILTER (WHERE e.rn = 1 AND NOT e.only_add),
           array_agg(e.tn) FILTER (WHERE e.only_add), array_agg(e.tk) FILTER (WHERE e.only_add),
           array_agg(e.msg) FILTER (WHERE e.only_add)
      INTO all_tn, all_tk, re_tn, re_tk, a_tn, a_tk, a_msg
      FROM e;
    PERFORM topic_head_lock(all_tn, all_tk);
    IF a_tn IS NOT NULL THEN
        PERFORM topic_head_add(a_tn, a_tk, a_msg);
    END IF;
    IF re_tn IS NOT NULL THEN
        PERFORM topic_head_rebuild(re_tn, re_tk);
    END IF;
END
$$;

-- The marks are held in 8 KB chunks: app.topic_head_marks is the open
-- chunk, app.topic_head_marks_<i> (i = 1 .. app.topic_head_chunks) the full
-- ones. One string for the whole transaction made every append copy all of
-- it: a 9 000-row UPDATE across 9 000 topics took 11.7 s. With chunks an
-- append copies at most 8 KB, and the drain joins the chunks once.
CREATE OR REPLACE FUNCTION topic_head_append(add text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    cur text := coalesce(current_setting('app.topic_head_marks', true), '');
    n   integer;
BEGIN
    IF octet_length(cur) + octet_length(add) > 8192 THEN
        n := coalesce(nullif(current_setting('app.topic_head_chunks', true), ''), '0')::integer + 1;
        PERFORM set_config('app.topic_head_marks_' || n, cur || add, true);
        PERFORM set_config('app.topic_head_chunks', n::text, true);
        PERFORM set_config('app.topic_head_marks', '', true);
    ELSE
        PERFORM set_config('app.topic_head_marks', cur || add, true);
    END IF;
END
$$;

-- Every mark of the transaction, and an empty set after it.
CREATE OR REPLACE FUNCTION topic_head_take() RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    n   integer := coalesce(nullif(current_setting('app.topic_head_chunks', true), ''), '0')::integer;
    out text := '';
BEGIN
    FOR i IN 1 .. n LOOP
        out := out || coalesce(current_setting('app.topic_head_marks_' || i, true), '');
        PERFORM set_config('app.topic_head_marks_' || i, '', true);
    END LOOP;
    out := out || coalesce(current_setting('app.topic_head_marks', true), '');
    PERFORM set_config('app.topic_head_marks', '', true);
    PERFORM set_config('app.topic_head_chunks', '', true);
    PERFORM set_config('app.topic_head_last', '', true);
    RETURN out;
END
$$;

-- One row mark (the UPDATE trigger). A rebuild mark equal to the one
-- appended last is not added again (a statement updating many rows of one
-- topic marks it once); any other repeat is merged by the drain's grouping.
-- Only the last entry is compared, so a mark stays O(1).
CREATE OR REPLACE FUNCTION topic_head_mark(k text, tn text, tk uuid, msg uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    e text := chr(30) || k || chr(31) || tn || chr(31) || tk::text || chr(31) || coalesce(msg::text, '');
BEGIN
    IF msg IS NULL AND e = coalesce(current_setting('app.topic_head_last', true), '') THEN
        RETURN;
    END IF;
    PERFORM topic_head_append(e);
    PERFORM set_config('app.topic_head_last', e, true);
END
$$;

-- The UPDATE mark, per row: the old and the new topic, and the card topic of
-- a row archived before or after.
CREATE OR REPLACE FUNCTION topic_head_mark_trg() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM topic_head_mark('r', OLD.tenant_id, OLD.task_id, NULL);
    IF OLD.archived_at IS NOT NULL THEN
        PERFORM topic_head_mark('r', OLD.tenant_id, OLD.msg_id, NULL);
    END IF;
    PERFORM topic_head_mark('r', NEW.tenant_id, NEW.task_id, NULL);
    IF NEW.archived_at IS NOT NULL THEN
        PERFORM topic_head_mark('r', NEW.tenant_id, NEW.msg_id, NULL);
    END IF;
    RETURN NULL;
END
$$;

-- The INSERT and DELETE marks, per statement over the transition table: ONE
-- append however many rows (the sweep deletes 5 000 a chunk; a bulk
-- INSERT .. SELECT writes thousands). A statement trigger cannot take a
-- column list, which only the UPDATE mark needs. An inserted line marks
-- ('a', its topic, its msg_id), or a rebuild of its topic and its card
-- topic when it arrives archived; a deleted line marks a rebuild of its
-- topic, and of its card topic when it was archived.
CREATE OR REPLACE FUNCTION topic_head_mark_ins_trg() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    add text;
BEGIN
    SELECT string_agg(CASE WHEN n.archived_at IS NULL
               THEN chr(30) || 'a' || chr(31) || n.tenant_id || chr(31) || n.task_id::text || chr(31) || n.msg_id::text
               ELSE chr(30) || 'r' || chr(31) || n.tenant_id || chr(31) || n.task_id::text || chr(31)
                 || chr(30) || 'r' || chr(31) || n.tenant_id || chr(31) || n.msg_id::text || chr(31) END, '')
      INTO add FROM topic_head_new n;
    IF add IS NOT NULL THEN
        PERFORM topic_head_append(add);
        PERFORM set_config('app.topic_head_last', '', true);
    END IF;
    RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION topic_head_mark_del_trg() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    add text;
BEGIN
    SELECT string_agg(chr(30) || 'r' || chr(31) || g.tenant_id || chr(31) || g.task_id::text || chr(31), '')
      INTO add
      FROM (SELECT o.tenant_id, o.task_id FROM topic_head_old o
            UNION
            SELECT o.tenant_id, o.msg_id FROM topic_head_old o WHERE o.archived_at IS NOT NULL) g;
    IF add IS NOT NULL THEN
        PERFORM topic_head_append(add);
        PERFORM set_config('app.topic_head_last', '', true);
    END IF;
    RETURN NULL;
END
$$;

-- The first firing at COMMIT drains the set; every later firing finds it
-- empty and returns.
CREATE OR REPLACE FUNCTION topic_head_apply_trg() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    marks text;
BEGIN
    IF coalesce(current_setting('app.topic_head_marks', true), '') = ''
       AND coalesce(current_setting('app.topic_head_chunks', true), '') = '' THEN
        RETURN NULL;
    END IF;
    marks := topic_head_take();
    PERFORM topic_head_apply_marks(marks);
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS topic_head_mark_ins ON messages;
CREATE TRIGGER topic_head_mark_ins AFTER INSERT ON messages
    REFERENCING NEW TABLE AS topic_head_new
    FOR EACH STATEMENT EXECUTE FUNCTION topic_head_mark_ins_trg();

-- The head columns: the part key (channel, from_id, to_id), the order key
-- (received_at, msg_id), the expiry, the archived flag, the topic and the
-- tenant. An archived_at restamp (set to set) changes no head.
DROP TRIGGER IF EXISTS topic_head_mark_upd ON messages;
CREATE TRIGGER topic_head_mark_upd
    AFTER UPDATE OF tenant_id, task_id, msg_id, channel, from_id, to_id, received_at, expires_at, archived_at ON messages
    FOR EACH ROW
    WHEN (OLD.tenant_id IS DISTINCT FROM NEW.tenant_id OR OLD.task_id IS DISTINCT FROM NEW.task_id
       OR OLD.msg_id IS DISTINCT FROM NEW.msg_id OR OLD.channel IS DISTINCT FROM NEW.channel
       OR OLD.from_id IS DISTINCT FROM NEW.from_id OR OLD.to_id IS DISTINCT FROM NEW.to_id
       OR OLD.received_at IS DISTINCT FROM NEW.received_at OR OLD.expires_at IS DISTINCT FROM NEW.expires_at
       OR (OLD.archived_at IS NULL) <> (NEW.archived_at IS NULL))
    EXECUTE FUNCTION topic_head_mark_trg();

DROP TRIGGER IF EXISTS topic_head_mark_del ON messages;
CREATE TRIGGER topic_head_mark_del AFTER DELETE ON messages
    REFERENCING OLD TABLE AS topic_head_old
    FOR EACH STATEMENT EXECUTE FUNCTION topic_head_mark_del_trg();

-- Deferred to COMMIT, so the head locks are the transaction's last locks
-- (0103's pattern). The same column list as the update mark: an UPDATE of
-- other columns (a claim, an edit) queues no event at all.
DROP TRIGGER IF EXISTS topic_head_apply ON messages;
CREATE CONSTRAINT TRIGGER topic_head_apply
    AFTER INSERT OR DELETE
       OR UPDATE OF tenant_id, task_id, msg_id, channel, from_id, to_id, received_at, expires_at, archived_at
    ON messages
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION topic_head_apply_trg();

-- Which topics of tenant tn have a stored head or part that differs from a
-- rebuild: one row per topic, what names the differences. Empty = right.
CREATE OR REPLACE FUNCTION topic_head_diff(tn text) RETURNS TABLE (task_id uuid, what text)
    LANGUAGE sql STABLE
    AS $$
    WITH s AS (
        SELECT DISTINCT m.task_id FROM messages m WHERE m.tenant_id = tn
        UNION
        SELECT h.task_id FROM topic_heads h WHERE h.tenant_id = tn
    ), e AS (
        SELECT x.* FROM (SELECT array_agg(tn) AS a, array_agg(s.task_id) AS b FROM s) q,
            LATERAL topic_head_expected(q.a, q.b) x
    ), hd AS (
        SELECT coalesce(e.task_id, h.task_id) AS task_id,
               CASE WHEN h.task_id IS NULL THEN 'missing head' WHEN e.task_id IS NULL THEN 'orphan head' ELSE 'head' END AS what
        FROM (SELECT * FROM e WHERE e.part IS NULL) e
        FULL JOIN (SELECT * FROM topic_heads h WHERE h.tenant_id = tn) h ON h.task_id = e.task_id
        WHERE e.task_id IS NULL OR h.task_id IS NULL
           OR (e.last_at, e.last_msg_id, e.dm_last_at, e.dm_last_msg_id, e.valid_until, e.card_archived, e.archived_rows)
              IS DISTINCT FROM (h.last_at, h.last_msg_id, h.dm_last_at, h.dm_last_msg_id, h.valid_until, h.card_archived, h.archived_rows)
    ), pd AS (
        SELECT coalesce(e.task_id, p.task_id) AS task_id,
               CASE WHEN p.task_id IS NULL THEN 'missing part ' || e.part
                    WHEN e.task_id IS NULL THEN 'orphan part ' || p.part ELSE 'part ' || p.part END AS what
        FROM (SELECT * FROM e WHERE e.part IS NOT NULL) e
        FULL JOIN (SELECT * FROM topic_head_parts p WHERE p.tenant_id = tn) p ON p.task_id = e.task_id AND p.part = e.part
        WHERE e.task_id IS NULL OR p.task_id IS NULL
           OR (e.channel, e.dm_a, e.dm_b, e.last_at, e.last_msg_id, e.valid_until)
              IS DISTINCT FROM (p.channel, p.dm_a, p.dm_b, p.last_at, p.last_msg_id, p.valid_until)
    )
    SELECT d.task_id, string_agg(d.what, ', ' ORDER BY d.what)
    FROM (SELECT * FROM hd UNION ALL SELECT * FROM pd) d
    GROUP BY d.task_id
$$;

-- The backfill (spec 8 step 2): a keyset walk over the distinct (tenant_id,
-- task_id) of messages - plus, with rebuild_all, of topic_heads, so a head
-- whose topic has no row left is deleted - that rebuilds every topic it
-- passes, head or not, chunk topics per call. after is the cursor the call
-- before returned ('<tenant>/<task>', NULL or '' to start); the result is
-- the next cursor, NULL once a chunk comes back empty. Every tenant the walk
-- has passed completely gets its topic_head_tenants mark; the empty chunk
-- marks the rest. Run it in the operator scope, one short transaction per
-- call (T006's action sets lock_timeout).
CREATE OR REPLACE FUNCTION topic_head_backfill(chunk integer, rebuild_all boolean, after text) RETURNS text
    LANGUAGE plpgsql AS $$
DECLARE
    a_tn text;
    a_tk uuid;
    tns  text[];
    tks  uuid[];
    n    integer;
BEGIN
    IF coalesce(after, '') <> '' THEN
        a_tn := left(after, length(after) - 37);
        a_tk := right(after, 36)::uuid;
    END IF;
    SELECT array_agg(k.tenant_id ORDER BY k.tenant_id, k.task_id), array_agg(k.task_id ORDER BY k.tenant_id, k.task_id)
      INTO tns, tks
      FROM (
        SELECT u.tenant_id, u.task_id FROM (
            (SELECT DISTINCT m.tenant_id, m.task_id FROM messages m
              WHERE a_tn IS NULL OR (m.tenant_id, m.task_id) > (a_tn, a_tk)
              ORDER BY m.tenant_id, m.task_id LIMIT chunk)
            UNION
            (SELECT h.tenant_id, h.task_id FROM topic_heads h
              WHERE rebuild_all AND (a_tn IS NULL OR (h.tenant_id, h.task_id) > (a_tn, a_tk))
              ORDER BY h.tenant_id, h.task_id LIMIT chunk)
        ) u
        ORDER BY u.tenant_id, u.task_id LIMIT chunk
      ) k;
    IF tns IS NULL THEN
        INSERT INTO topic_head_tenants (tenant_id, backfilled_at)
        SELECT t.tenant_id, clock_timestamp() FROM tenants t WHERE a_tn IS NULL OR t.tenant_id >= a_tn
        ON CONFLICT (tenant_id) DO UPDATE SET backfilled_at = EXCLUDED.backfilled_at;
        RETURN NULL;
    END IF;
    PERFORM topic_head_rebuild(tns, tks);
    n := array_length(tns, 1);
    INSERT INTO topic_head_tenants (tenant_id, backfilled_at)
    SELECT t.tenant_id, clock_timestamp() FROM tenants t
    WHERE (a_tn IS NULL OR t.tenant_id >= a_tn) AND t.tenant_id < tns[n]
    ON CONFLICT (tenant_id) DO UPDATE SET backfilled_at = EXCLUDED.backfilled_at;
    RETURN tns[n] || '/' || tks[n]::text;
END
$$;
