-- 0180_fleet_asks_queue.sql — a spawn request waits in a queue with a
-- position (owner HUM-10, t1 c9beaa77, msg ca668844). Forward-only.
--
-- Owner: "the orchestrators - could simply reply - \"you will be given a
-- lane\" - you are in line ... or create some kind scheduling structure in
-- the db, where once resources are free they will be just taken".
--
-- A spawn request was an open ask the orchestrator placed by hand from a
-- queue file on its own disk, one per 10 min while the box had room. The ask
-- meanwhile aged, was re-raised and went to the owner, and after 4 raises was
-- dead-lettered while its lane still waited in that file (9 asks, 10-11..12).
-- Now the queue is here:
--
--   open | acked -> queued (enqueued_at, placement) -> acked (placing, by the
--   placer) -> done ("placed: <ID>@<box>") | queued again (placement stalled)
--
-- queued is an open state for the ops (ack, done, decline still apply) but
-- the asks tick re-raises and escalates only open and acked rows, so a queued
-- ask is never raised, never told to the owner and never dead-lettered,
-- whatever its age. Its position is its rank by enqueued_at among the queued
-- rows of its role, computed on read: a placement moves every later one up.
-- enqueued_at is set once, so a stalled placement goes back to the head.
-- placement is what the placer needs to launch it without judgement,
-- "<vendor>:<slug>" (its brief is <slug>'s file on the orchestrator's box);
-- empty = the orchestrator decides, the placer hands it over when it is next.
ALTER TABLE fleet_asks ADD COLUMN enqueued_at timestamptz;
ALTER TABLE fleet_asks ADD COLUMN placement text NOT NULL DEFAULT ''
    CHECK (placement ~ '^([a-z]{2,16}:[a-z0-9][a-z0-9._-]{0,63})?$');

ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_state_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_state_check
    CHECK (state IN ('open', 'acked', 'queued', 'done', 'declined', 'dead'));

-- The book's "still waiting" read now includes the queue.
DROP INDEX IF EXISTS fleet_asks_open;
CREATE INDEX fleet_asks_open ON fleet_asks (tenant_id, fleet, role, created_at)
    WHERE state IN ('open', 'acked', 'queued');
