-- 0182_topic_head_add_probes.sql - the insert path of the topic heads stays
-- O(index probes): perf round 5, row P5-02
-- (csi-spl-doc/doc/md/perf-round-5-plan.md section 3). Replaces rdb 0144's
-- topic_head_add; topic_head_apply_marks, its one caller, is unchanged.
-- Forward-only, idempotent.
--
-- What 0144's add cost, measured in a rolled-back lab (postgres:16-alpine,
-- 29 282 lines over 3 644 topics, n = 30 per cell):
--   * the first line of a NEW topic: p50 50.6 ms. Its head is a placeholder,
--     so the add called topic_head_rebuild, and that plans topic_head_set's
--     ROWS 1000 as a merge join over a seq scan of every message of the
--     database. On prd 347 of the 395 topics written in 24 h were new.
--   * a line in an existing topic: p50 5.5..6.1 ms, of which the head fold
--     hash-joins a seq scan of every topic_head_parts row (3.3 ms).
-- Both grow with the tables, not with the lines inserted.
--
-- What stays: the add takes topic_head_lock again although its caller
-- already did (0.15 ms p50 in the lab). It is not redundant: a head that a
-- concurrent merge deletes while the caller waits on its FOR UPDATE is
-- skipped by that wait, and only the second lock puts the placeholder back
-- (TestTopicHeadRaceMirroredVsMerge fails on the parts foreign key without
-- it).
--
-- What changes:
--   1. A placeholder head whose topic holds no line but this call's new ones
--      is a NEW topic: the add writes it like any other (its parts from the
--      new lines, the head folded from the parts), plus the card rule from
--      one primary-key probe. No new line is archived (an archived insert is
--      marked for a rebuild), so archived_rows stays 0. Only a placeholder
--      over older lines (a real miss: a head lost, or a topic from before
--      0144) is rebuilt, as before.
--   2. Every per-topic read is a LATERAL index probe fenced with OFFSET 0,
--      so the planner cannot flatten it into a join over the whole table,
--      whatever row count it guesses for the topic set.
-- The result is the same head and parts a rebuild writes: topic_head_diff
-- stays empty (store/topic_head_*_test.go).

-- The incremental add: the lines msgs[i] were inserted into (tns[i], tks[i])
-- and nothing else touched those topics in this transaction. It locks the
-- heads (the header says why again); a placeholder head over older lines is
-- rebuilt first; the add then finds its
-- new lines already there and moves nothing. Otherwise each part keeps the
-- greater of its latest line and the new lines' latest, and each head whose
-- parts moved is folded from its parts: last over every part, dm_last over
-- the DM parts, valid_until the earliest part expiry.
CREATE OR REPLACE FUNCTION topic_head_add(tns text[], tks uuid[], msgs uuid[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    miss_tn text[];
    miss_tk uuid[];
    up_tn   text[];
    up_tk   uuid[];
BEGIN
    PERFORM topic_head_lock(tns, tks);
    -- A placeholder is a real miss when its topic has more lines than this
    -- call's new ones: count at most n + 1 of them, so a new topic reads only
    -- its own lines.
    SELECT array_agg(s.tn), array_agg(s.tk) INTO miss_tn, miss_tk
    FROM topic_head_set(tns, tks) s
    CROSS JOIN LATERAL (SELECT 1 FROM topic_heads h
                        WHERE h.tenant_id = s.tn AND h.task_id = s.tk AND h.last_at = '-infinity' OFFSET 0) ph
    CROSS JOIN LATERAL (SELECT count(DISTINCT u.mid) AS n FROM unnest(tns, tks, msgs) AS u (tn, tk, mid)
                        WHERE u.tn = s.tn AND u.tk = s.tk) nw
    WHERE (SELECT count(*) FROM (SELECT 1 FROM messages m WHERE m.tenant_id = s.tn AND m.task_id = s.tk
                                 LIMIT nw.n + 1) z) > nw.n;
    IF miss_tn IS NOT NULL THEN
        PERFORM topic_head_rebuild(miss_tn, miss_tk);
    END IF;

    WITH l AS (
        SELECT m.tenant_id, m.task_id, m.msg_id, m.received_at, m.expires_at, m.channel,
               CASE WHEN m.channel IS NULL THEN least(m.from_id, m.to_id) END AS dm_a,
               CASE WHEN m.channel IS NULL THEN greatest(m.from_id, m.to_id) END AS dm_b
        FROM unnest(tns, tks, msgs) AS u (tn, tk, mid)
        CROSS JOIN LATERAL (SELECT * FROM messages m WHERE m.tenant_id = u.tn AND m.msg_id = u.mid AND m.task_id = u.tk OFFSET 0) m
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

    -- The fold, as an upsert on the locked heads (it always updates). The
    -- archived columns are kept, except on a new topic's placeholder: there
    -- the card rule is read (rdb 0144 topic_head_expected's probe) and
    -- archived_rows stays the placeholder's 0.
    INSERT INTO topic_heads AS h (tenant_id, task_id, last_at, last_msg_id, dm_last_at, dm_last_msg_id, valid_until,
                                  card_archived, archived_rows, rev, changed_at)
    SELECT s.tn, s.tk,
           (array_agg(tp.last_at ORDER BY tp.last_at DESC, tp.last_msg_id DESC))[1],
           (array_agg(tp.last_msg_id ORDER BY tp.last_at DESC, tp.last_msg_id DESC))[1],
           (array_agg(tp.last_at ORDER BY tp.last_at DESC, tp.last_msg_id DESC) FILTER (WHERE tp.channel IS NULL))[1],
           (array_agg(tp.last_msg_id ORDER BY tp.last_at DESC, tp.last_msg_id DESC) FILTER (WHERE tp.channel IS NULL))[1],
           min(tp.valid_until),
           coalesce((SELECT c.archived_at IS NOT NULL FROM messages c WHERE c.tenant_id = s.tn AND c.msg_id = s.tk), false),
           0, 1, clock_timestamp()
    FROM topic_head_set(up_tn, up_tk) s
    CROSS JOIN LATERAL (SELECT * FROM topic_head_parts tp WHERE tp.tenant_id = s.tn AND tp.task_id = s.tk OFFSET 0) tp
    GROUP BY s.tn, s.tk
    ON CONFLICT (tenant_id, task_id) DO UPDATE
        SET last_at = EXCLUDED.last_at, last_msg_id = EXCLUDED.last_msg_id, dm_last_at = EXCLUDED.dm_last_at,
            dm_last_msg_id = EXCLUDED.dm_last_msg_id, valid_until = EXCLUDED.valid_until,
            card_archived = CASE WHEN h.last_at = '-infinity' THEN EXCLUDED.card_archived ELSE h.card_archived END,
            rev = h.rev + 1, changed_at = EXCLUDED.changed_at;
END
$$;
