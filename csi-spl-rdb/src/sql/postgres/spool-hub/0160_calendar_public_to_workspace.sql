-- 0160_calendar_public_to_workspace.sql - the audience rename, step 2
-- (0159's header; owner t1 a3ce2031, msg bad3799a). Forward-only,
-- idempotent.
--
--   calendar_events   every row still holding the old public ("everyone in
--                     the workspace") becomes workspace, so no stored row
--                     holds the old meaning when public turns signed-out
--                     (step 4). Synced rows (source_key goal:, spec:,
--                     release:) move with the rest; the sync route takes
--                     workspace and, until step 4, public as workspace.
--   audience default  workspace (was public). Every hub write names the
--                     audience, so the default serves only a hand insert.
--
-- updated_at is left alone: the rename is not an edit, and a client's
-- If-Match on the event stays valid. Operator scope (this file runs in one
-- transaction; FORCE RLS since 0125). No personal data.
-- DEPLOY ORDER: only after the 0159 hub (writes workspace, reads public as
-- workspace) serves dev and prd; an older hub would read workspace rows it
-- does not know.

SELECT set_config('app.rls_scope', 'operator', true);
UPDATE calendar_events SET audience = 'workspace' WHERE audience = 'public';
ALTER TABLE calendar_events ALTER COLUMN audience SET DEFAULT 'workspace';
