-- 0207_issue_spec_attributes.sql — first-class GitSpec task linkage on
-- issues (spec 145 section 2.1, T001, SPL-2452). Forward-only.
--
-- Owner directive (spec 145 section 0.2): the spec path and the task id
-- become first-class attributes of every issue, no longer a "- spec:" line
-- in the description card.
--
-- spec_path     the spec or task file, csi-spl-doc/specs/<NNN>-<slug>/<file>.md,
--               or empty string (no spec yet; the backfill T012 and the strict
--               hub validation T004 come later).
-- spec_task_id  the task row id in that spec's tasks.md (T001, B4, T012.s1),
--               or empty string (a level-1 epic anchors the whole spec).
--
-- Both default to empty string, so the running image, which neither reads
-- nor writes them, keeps working: this file rolls before the image that
-- reads them (T003). The table's RLS policies cover the new columns.

-- SET CONSTRAINTS first: `spool migrate --dry-run` applies every pending file
-- in ONE transaction, and an earlier file's deferred trigger events on issues
-- (rdb 0194) would make the ALTER fail (SQLSTATE 55006).
SET CONSTRAINTS ALL IMMEDIATE;
SET LOCAL lock_timeout = '5s';

ALTER TABLE issues ADD COLUMN IF NOT EXISTS spec_path text NOT NULL DEFAULT ''
    CONSTRAINT issues_spec_path_check CHECK (length(spec_path) <= 255 AND (
        spec_path = ''
        OR spec_path ~ '^csi-spl-doc/specs/[0-9]{3}-[a-z0-9_-]+/[a-z0-9_.-]+\.md$'));

ALTER TABLE issues ADD COLUMN IF NOT EXISTS spec_task_id text NOT NULL DEFAULT ''
    CONSTRAINT issues_spec_task_id_check CHECK (length(spec_task_id) <= 32 AND (
        spec_task_id = '' OR spec_task_id ~ '^[A-Za-z0-9_.-]+$'));

-- The reverse lookup: which issue tracks this spec task.
CREATE INDEX IF NOT EXISTS issues_spec_task_idx
    ON issues (tenant_id, spec_path, spec_task_id)
    WHERE spec_path <> '';
