-- 0161_calendar_web_to_public.sql - the audience rename, step 5, the last
-- (0159's header; owner t1 a3ce2031, msg bad3799a). Forward-only,
-- idempotent.
--
--   calendar_events   every row still holding web (the signed-out audience
--                     before the rename) becomes public.
--   calendar_events_audience_check  the four audiences under their names:
--                     public, workspace, internal, private. No web, and no
--                     public meaning workspace (0160 mapped those).
--
-- updated_at is left alone: the rename is not an edit. Operator scope (this
-- file runs in one transaction; FORCE RLS since 0125). No personal data.
-- DEPLOY ORDER: only after the step-4 hub (writes public, takes web as
-- public) serves dev and prd; a step-1 hub would still write web and fail
-- the check.

SELECT set_config('app.rls_scope', 'operator', true);
UPDATE calendar_events SET audience = 'public' WHERE audience = 'web';
ALTER TABLE calendar_events DROP CONSTRAINT IF EXISTS calendar_events_audience_check;
ALTER TABLE calendar_events ADD CONSTRAINT calendar_events_audience_check
    CHECK (audience IN ('public', 'workspace', 'internal', 'private'));
