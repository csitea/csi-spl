-- 0156_calendar_source_key.sql - synced calendar events (specs/112 RDB-1,
-- spec section 4.2). Forward-only, additive, idempotent.
--
--   calendar_events.source_key  the event's stable key when a sync writes it
--                     (goal:G01:deadline, goal:G01:m:<key>, release:v1.3.0,
--                     spec:089:done, db:<topic_id>); NULL for an event a
--                     human or agent made. Every sync re-run is an upsert by
--                     this key (STORE-1), never a duplicate.
--   calendar_events_source_key  partial unique index: one row per
--                     (tenant_id, source_key), soft-deleted rows included;
--                     NULL keys are exempt, so hand-made events are
--                     unaffected.
--   calendar_events_kind_check  0125's seven kinds plus goal and milestone.
--
-- The column is nullable with no default, so the add is catalogue-only;
-- widening a CHECK fails no existing row. Plain CREATE UNIQUE INDEX, not
-- CONCURRENTLY: the runner (internal/store migrate.go) applies each file in
-- its own transaction. RLS is unchanged: calendar_events has its 0125
-- policies. No personal data.
-- DEPLOY ORDER: apply on dev and prd BEFORE the hub that writes source_key
-- (STORE-1 / HUB-1); the running hub reads nothing new.

ALTER TABLE calendar_events ADD COLUMN IF NOT EXISTS source_key text NULL;

CREATE UNIQUE INDEX IF NOT EXISTS calendar_events_source_key
    ON calendar_events (tenant_id, source_key)
    WHERE source_key IS NOT NULL;

ALTER TABLE calendar_events DROP CONSTRAINT IF EXISTS calendar_events_kind_check;
ALTER TABLE calendar_events ADD CONSTRAINT calendar_events_kind_check
    CHECK (kind IN ('release', 'deploy', 'maintenance', 'freeze', 'agent_task', 'reminder', 'other', 'goal', 'milestone'));
