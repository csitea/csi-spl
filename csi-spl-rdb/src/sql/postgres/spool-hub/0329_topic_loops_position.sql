-- 0329_topic_loops_position.sql - a discussion loop's place in its topic's
-- list (spec 182 v0.11 section 8.8 change 8, SPL-6587; HUM-10 t1 6e8c1cdb).
-- Forward-only, idempotent.
--
-- position : the loop's place among its topic's loops, 0 first. The list
--     reads ORDER BY position, set_at, loop_id (store TopicLoops); a new
--     loop takes the topic's highest position + 1, so it goes last;
--     PUT /v1/topics/{task_id}/loops/order rewrites the topic's every row
--     to 0..n-1 in the order it was sent (store OrderTopicLoops).
--
-- NOT NULL DEFAULT 0, a constant default: no rewrite, no backfill. Rows
-- stored before this file all read 0, so their order stays set_at,
-- loop_id, as before. The inline CHECK makes Postgres scan topic_loops
-- once under ACCESS EXCLUSIVE (a small table); lock_timeout bounds the
-- wait for that lock. No personal data, no secret.
SET LOCAL lock_timeout = '5s';
ALTER TABLE topic_loops ADD COLUMN IF NOT EXISTS position integer NOT NULL DEFAULT 0
    CHECK (position >= 0);
