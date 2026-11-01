-- 0248_human_events_resend_once.sql — a re-sent WUI error event is stored
-- once (SPL-4559, specs/005 FR-WUI-EVLOG). Forward-only, idempotent.
--
-- The WUI's event log (csi-spl-wui/src/utils/event-log.mjs) re-sends a batch
-- whose answer it lost, so the hub got the same event twice: prd events 1195
-- and 1197, one `omnibox-send hub_down` with the same error_id and
-- occurred_at, received 22 s apart. The client keeps retrying; the hub now
-- keeps the first copy (INSERT ... ON CONFLICT DO NOTHING).
--
-- One event is (human_id, error_id, occurred_at). A row with error_id '' is
-- never a match (the partial index skips it), nor is a row with no
-- occurred_at (NULLs are distinct), so events without an identity are still
-- stored every time.
--
-- The duplicates already stored are deleted first, keeping the lowest
-- event_id, so the index build cannot fail on them. The lock keeps an insert
-- from adding one between the delete and the build (this file runs in one
-- transaction). human_events is hub-wide, outside RLS (0045).
-- DEPLOY ORDER: run 20 migrates before it rolls the new hub, so for that
-- window the old hub (a plain INSERT) runs on this index: a batch holding a
-- re-sent event fails as a whole (unique violation, 503, hub/events.go). The
-- first copy is already stored; the client retries the batch (3, 6, 12 s,
-- EVENT_RETRY_MAX 3) and then drops it, so the other events of that one batch
-- can be lost, only for a re-send inside the roll. The new hub works on
-- either schema: its ON CONFLICT names no target.

LOCK TABLE human_events IN SHARE ROW EXCLUSIVE MODE;

DELETE FROM human_events d
 USING human_events k
 WHERE d.human_id = k.human_id
   AND d.error_id = k.error_id
   AND d.occurred_at = k.occurred_at
   AND d.error_id <> ''
   AND d.event_id > k.event_id;

CREATE UNIQUE INDEX IF NOT EXISTS human_events_resend_once
    ON human_events (human_id, error_id, occurred_at)
 WHERE error_id <> '';
