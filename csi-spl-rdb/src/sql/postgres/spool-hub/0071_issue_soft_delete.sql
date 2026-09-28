-- 0071_issue_soft_delete.sql — an issue can be deleted from the sheet
-- (SPL-1027, spec 039 FR-009 as revised, issues-v1 §1). Forward-only.
--
-- Owner, 2026-09-28 (prd t1 topic 89485c7a): "the grid should be fully CRUD".
--
-- SOFT delete, like channels (0052): DELETE /v1/issues/{ref} stamps
-- deleted_at / deleted_by and removes nothing. The number stays taken (the
-- counter never reuses one), the discussion topic and its messages stay, and
-- the way back is one UPDATE that clears deleted_at. While deleted_at is set
-- the hub treats the issue as absent: every list, get, patch, parent lookup
-- and child count skips it, so a deleted issue is a 404 and never a parent.
-- The hub refuses to delete an issue that still has live children.

ALTER TABLE issues ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE issues ADD COLUMN IF NOT EXISTS deleted_by text;

ALTER TABLE issues DROP CONSTRAINT IF EXISTS issues_deleted_by_len;
ALTER TABLE issues ADD CONSTRAINT issues_deleted_by_len
    CHECK (deleted_by IS NULL OR length(deleted_by) <= 64);
