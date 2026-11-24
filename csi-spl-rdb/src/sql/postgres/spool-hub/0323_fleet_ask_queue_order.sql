-- 0323_fleet_ask_queue_order.sql - a queued spawn request's own priority,
-- its dragged place in the line, and the placer's hold reason (spec 153
-- sections 3.22.6-3.22.8, row Q2, SPL-6396). Forward-only, idempotent.
--
-- priority, priority_by, priority_at : the ask's own priority 1..5, who set
--     it (an operator admin, or the dispatch holder through ask_op
--     position) and when. NULL = never set. The effective priority (store
--     askFillPriorities): the ask's own and its discussion's topic_priorities
--     row both set, the newer write wins (priority_at against set_at); one
--     set, that one; neither, 3.
-- queue_rank, rank_by, rank_at : the row's place among its priority's rows
--     (store askPositions: priority, then ranked rows first, lower first,
--     then the class, enqueued_at, ask_id). rank_by names who dragged THIS
--     row; a row ranked only because a drag landed below it has a rank and
--     no rank_by. A rank older than the row's effective priority reads as
--     none: a priority change clears it. Ranks use gaps of 1024.
-- hold_reason : why the placer passed the row over on its last tick (row Q3
--     writes it, ask_op holds); NULL = waiting for room.
--
-- Nullable columns, no rewrite, no backfill. The two inline CHECKs make
-- Postgres scan fleet_asks once under ACCESS EXCLUSIVE to validate them (a
-- small table); lock_timeout bounds the wait for that lock. No personal
-- data, no secret.
SET LOCAL lock_timeout = '5s';
ALTER TABLE fleet_asks ADD COLUMN IF NOT EXISTS priority smallint
    CHECK (priority BETWEEN 1 AND 5);
ALTER TABLE fleet_asks ADD COLUMN IF NOT EXISTS priority_by text;
ALTER TABLE fleet_asks ADD COLUMN IF NOT EXISTS priority_at timestamptz;
ALTER TABLE fleet_asks ADD COLUMN IF NOT EXISTS queue_rank bigint
    CHECK (queue_rank > 0);
ALTER TABLE fleet_asks ADD COLUMN IF NOT EXISTS rank_by text;
ALTER TABLE fleet_asks ADD COLUMN IF NOT EXISTS rank_at timestamptz;
ALTER TABLE fleet_asks ADD COLUMN IF NOT EXISTS hold_reason text;
