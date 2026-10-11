-- 0177_flow_v2.sql - Flow v2, "what is happening" (spec 130 sections 4 and
-- 7, lane L1). Forward-only, additive.
--
-- Owner HUM-10, t1 da98036e: "All of the releases, all of the 'something is
-- ready', and all of the 'something is blocked' should go to the flow."
--
-- 1. flow_events.kind admits 'blocked' (a stored blocker line, the strongest
--    rank) and 'ready' (a line that carries the v:1 key `accepts`). Not
--    'release': releases have no flow_events rows, the hub merges them from
--    release_notes at read time (spec 6). store/flow.go flowKinds is the Go
--    side of this CHECK.
-- 2. release_notes.released_at: when a commit first got a version in THIS
--    hub's table. The ingest upsert (store PutReleaseNotes) sets it once,
--    when the stored version was NULL and the new one is not, and never
--    restamps it: ingested_at is restamped on every re-sent row (one deploy
--    re-stamps 500), so it cannot say "went live".
--    Backfilled from committed_at for the rows that already have a version:
--    the history reads as past days, older than every member's f:seen, so
--    the Flow badge does not flood.
--    The index is the Flow's release merge: newest released first.
--
-- DEPLOY ORDER: apply BEFORE the hub that writes these, on dev AND prd. The
-- old hub writes neither: its inserts keep the old kinds, and its upsert
-- leaves released_at NULL (a release it ingests does not show in the Flow
-- until the new hub runs, never a wrong line).

ALTER TABLE flow_events DROP CONSTRAINT flow_events_kind_check;
ALTER TABLE flow_events ADD CONSTRAINT flow_events_kind_check
    CHECK (kind IN ('blocked', 'ready', 'mention', 'poke', 'dm', 'reply'));

ALTER TABLE release_notes ADD COLUMN released_at timestamptz NULL;
UPDATE release_notes SET released_at = committed_at WHERE version IS NOT NULL;
CREATE INDEX release_notes_released_at ON release_notes (released_at DESC)
    WHERE released_at IS NOT NULL;
