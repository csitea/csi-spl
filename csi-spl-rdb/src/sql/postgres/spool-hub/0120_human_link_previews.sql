-- 0120_human_link_previews.sql — whether a person sees a short preview card
-- (Landed first as 0119 in b0def3ad, beside 0119_agent_join_tokens; renumbered.
-- Idempotent, so a database that applied it as 0119 applies it again as a no-op.)
-- under a message that links an object of the same workspace (a topic, a
-- message). Forward-only. humans is hub-wide and outside row level security,
-- like the other layout choices (0070, 0072, 0077); a per-tenant override
-- rides tenant_memberships.settings (0078) under the same key.
--
-- Owner, prd t1 topic e1f8f797: "each internal link to an object ... if the
-- user has a setting for it - it should present as small slack like 3 lines
-- excerpt", then "the users should be able to turn this off, from their
-- individual settings". The switch is the person's own, never a workspace one.
--
-- NULL = never picked: the WUI applies the default, previews on.
-- link_previews 'on'  : a linked topic / message shows its preview card.
--               'off' : the link stays a plain link.
ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS link_previews text NULL;

ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_link_previews_check;
ALTER TABLE humans ADD CONSTRAINT humans_link_previews_check
    CHECK (link_previews IS NULL OR link_previews IN ('on','off'));
