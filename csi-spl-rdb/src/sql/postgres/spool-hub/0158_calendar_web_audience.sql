-- 0158_calendar_web_audience.sql - the calendar audience web: an event shown
-- to signed-out visitors of its workspace (owner t1 a3ce2031, msg a8e3d31d).
-- Forward-only, additive, idempotent.
--
--   calendar_events_audience_check  0125's three audiences plus web. public
--                     stays "everyone in the workspace" and stays the
--                     default; web is set only on purpose, never by default.
--                     The hub's signed-out read (GET /v1/public/calendar/
--                     events) answers web rows only.
--
-- Widening a CHECK fails no existing row. RLS is unchanged: calendar_events
-- keeps its 0125 policies, and the signed-out read runs in the workspace's
-- scope. No personal data.
-- DEPLOY ORDER: apply on dev and prd BEFORE the hub that writes web; the
-- running hub writes nothing new.

ALTER TABLE calendar_events DROP CONSTRAINT IF EXISTS calendar_events_audience_check;
ALTER TABLE calendar_events ADD CONSTRAINT calendar_events_audience_check
    CHECK (audience IN ('public', 'internal', 'private', 'web'));
