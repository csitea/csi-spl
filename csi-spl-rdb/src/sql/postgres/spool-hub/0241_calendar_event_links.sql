-- 0241_calendar_event_links.sql — an event's issue links and its owner
-- (SPL-4043, specs/097). Forward-only, additive, idempotent.
--
--   calendar_events.issue_keys  issue keys in this workspace (SPL-12).
--                     Empty until a member sets them. The hub caps the
--                     list at 20; this file does not.
--   calendar_events.owner_id    one responsible member (HUM-n) or agent id,
--                     distinct from creator_id. Backfilled from creator_id
--                     so every existing row has an owner.
--
-- topic_id (0125) stays the discussion link. RLS is unchanged: the 0125
-- policies on calendar_events cover the new columns. No new table.
-- DEPLOY ORDER: the hub probes owner_id. Until this file is applied it
-- reads '' and '{}' in their place and writes neither column, so a hub
-- may roll first. Apply on dev and prd before a stored owner or issue
-- list is required.

ALTER TABLE calendar_events ADD COLUMN IF NOT EXISTS issue_keys text[] NOT NULL DEFAULT '{}';
ALTER TABLE calendar_events ADD COLUMN IF NOT EXISTS owner_id text NOT NULL DEFAULT '';

UPDATE calendar_events SET owner_id = creator_id WHERE owner_id = '';
