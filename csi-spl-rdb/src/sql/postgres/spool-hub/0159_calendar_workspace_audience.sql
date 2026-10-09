-- 0159_calendar_workspace_audience.sql - the calendar audience workspace:
-- step 1 of the audience rename (owner t1 a3ce2031, msg bad3799a: "the same
-- naming convention as for the docs, not web, but public").
-- Forward-only, additive, idempotent.
--
-- The rename: today's public ("everyone in the workspace", the default)
-- becomes workspace, and web (signed-out visitors, 0158) becomes public.
-- The word public changes meaning, so no hub may ever read it both ways.
-- It rolls in steps, each live on dev and prd before the next lands:
--
--   1. this file + the hub that writes workspace and reads public as
--      workspace (store.CalendarAudienceOf). The check holds both names.
--   2. a data step: every stored public row becomes workspace, so no row
--      holds the old meaning any more.
--   3. the WUI that sends workspace (and web for signed-out).
--   4. the hub that reads and takes public as signed-out (web its alias),
--      and a data step that maps web to public.
--   5. the check without web, and the column default workspace.
--
--   calendar_events_audience_check  0158's four audiences plus workspace.
--
-- Widening a CHECK fails no existing row. RLS is unchanged. No personal
-- data.
-- DEPLOY ORDER: apply on dev and prd BEFORE the hub that writes workspace;
-- the running hub writes nothing new.

ALTER TABLE calendar_events DROP CONSTRAINT IF EXISTS calendar_events_audience_check;
ALTER TABLE calendar_events ADD CONSTRAINT calendar_events_audience_check
    CHECK (audience IN ('public', 'internal', 'private', 'web', 'workspace'));
