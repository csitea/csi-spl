-- 0038_human_diagnostics_enabled.sql — the "Debug pane" checkbox on the WUI
-- settings page (CLE-34963; ported from the donor's users.diagnostics_enabled).
-- Forward-only.
--
-- humans.diagnostics_enabled is the signed-in person's OWN choice to show the
-- diagnostics panel at the bottom of the app (PUT /api/v1/auth/preferences).
-- The hub reads it on every GET /api/v1/auth/session and answers it as the
-- `diagnostics_enabled` claim; it is never part of the signed cookie, so
-- unticking hides the panel at the next session read.
--
-- It is the SOLE gate: it replaces the operator list
-- SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS (empty in every env). Under "list OR
-- checkbox" unticking would change nothing for a listed address.
-- NOT NULL DEFAULT false = every existing human and every new one starts
-- without the panel (fail shut).
--
-- humans is hub-wide and stays outside 0014's row level security.

ALTER TABLE humans
    ADD COLUMN diagnostics_enabled boolean NOT NULL DEFAULT false;
