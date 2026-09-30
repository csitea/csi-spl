-- 0085_issue_archive.sql — archive an issue, and cascade archive / delete of a
-- whole epic or feature to its descendants (SPL-1226). Forward-only.
--
-- Owner, 2026-09-29 (prd t1 topic b82f3853): "it shoud be possible to archive
-- and delete entire epics/features , which will archive / delete all of their
-- features too".
--
-- SOFT archive, like a topic card (0065): archived_at on the issue row is the
-- flag (NULL = live, set = archived; archived_by is who did it). Nothing is
-- removed and unarchive clears both, so it is restorable the way a deleted
-- issue is (one UPDATE). While archived_at is set the hub treats the issue as
-- absent, exactly as it does deleted_at (0071): every list, get, patch, parent
-- lookup and child count skips it.
--
-- Cascade is the hub's, not a database trigger: archiving or deleting a level-1
-- row (an epic or a feature) stamps the same flag on every live descendant in
-- one transaction (a WITH RECURSIVE walk of parent_number). This column is what
-- that walk writes.
--
-- The partial index is the archived rows only, so it stays as small as the
-- archive: the live reads all carry `archived_at IS NULL` and never probe it.

ALTER TABLE issues ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE issues ADD COLUMN IF NOT EXISTS archived_by text;

ALTER TABLE issues DROP CONSTRAINT IF EXISTS issues_archived_by_len;
ALTER TABLE issues ADD CONSTRAINT issues_archived_by_len
    CHECK (archived_by IS NULL OR length(archived_by) <= 64);

CREATE INDEX IF NOT EXISTS issues_archived
    ON issues (tenant_id, archived_at)
    WHERE archived_at IS NOT NULL;
