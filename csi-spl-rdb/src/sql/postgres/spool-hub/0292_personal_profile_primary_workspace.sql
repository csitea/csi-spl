-- 0292_personal_profile_primary_workspace.sql — a person's Primary workspace
-- (SPL-5788, spec 119 primary-workspace.md v0.3.1 section 2.2, tasks.md T019;
-- owner HUM-10, t1 69d3f60c poll 6312c024 answer 3a). Forward-only, additive.
--
-- One column on the realm profile (rdb 0168), one row per person, no history:
-- the workspace a new entry made in "My calendar" goes to by default. NULL =
-- none set (everything behaves as before). Plain text with no FK, like
-- personal.note_links.workspace_id: the realm keeps no FK to a table that
-- carries tenant_id (119 7.3). It sits under the table's one person_scope
-- policy (FORCE RLS), so no admin, member or operator reads it.
--
-- The hub checks the value on PUT /v1/me/realm/profile against the
-- workspaces the person may write in (section 2.1), else 400
-- bad_primary_workspace; a value that stops passing is kept but read as
-- unset (section 2.4). The database checks the length only.
SET LOCAL lock_timeout = '5s';

ALTER TABLE personal.profile
    ADD COLUMN IF NOT EXISTS primary_workspace_id text NULL;

ALTER TABLE personal.profile DROP CONSTRAINT IF EXISTS profile_primary_workspace_id_check;
ALTER TABLE personal.profile ADD CONSTRAINT profile_primary_workspace_id_check
    CHECK (primary_workspace_id IS NULL OR length(primary_workspace_id) BETWEEN 1 AND 200);
