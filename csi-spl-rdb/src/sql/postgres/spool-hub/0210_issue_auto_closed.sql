-- 0210_issue_auto_closed.sql — mark an epic closed by the SPL-1729
-- auto-close (SPL-2607). Forward-only.
--
-- An epic closes by itself when its last open issue closes (SPL-1729), and
-- that close archives it like a person's close does (SPL-1643). Nothing on
-- the row told the two apart, so no agent could tell whether an archived
-- epic may be reopened by a placer (SPL-2558). auto_closed is that mark:
-- true = the auto-close set the row's closed status; a person's update or
-- an unarchive clears it. The agent op `issue get` answers it for an
-- archived issue (issues-v1 section 6).
--
-- Default false, so the running image, which neither reads nor writes it,
-- keeps working: this file rolls before the image that reads it (wf 20 runs
-- do_spl_db_bootstrap before each env's roll). The table's RLS policies
-- cover the new column. No issue_events row: the trigger (rdb 0181) records
-- only its listed fields.

-- SET CONSTRAINTS first: `spool migrate --dry-run` applies every pending file
-- in ONE transaction, and an earlier file's deferred trigger events on issues
-- (rdb 0194) would make the ALTER fail (SQLSTATE 55006).
SET CONSTRAINTS ALL IMMEDIATE;
SET LOCAL lock_timeout = '5s';

ALTER TABLE issues ADD COLUMN IF NOT EXISTS auto_closed boolean NOT NULL DEFAULT false;

-- Backfill, in the migrator's operator scope: an archived epic whose own
-- archive was the auto-close is the one whose HUB-0 note "Closed as <st>
-- automatically: ..." (hub/issue_epic_autoclose.go) was posted with that
-- archive, at most 5 minutes after it. A note from an earlier close that
-- was unarchived since does not match the current archived_at. A note gone
-- with message retention leaves the row false, as a person's close reads.
UPDATE issues i SET auto_closed = true
WHERE i.archived_at IS NOT NULL AND i.deleted_at IS NULL AND i.level = 1
  AND i.status IN ('done', 'diss') AND NOT i.auto_closed
  AND EXISTS (
      SELECT 1 FROM messages m
      WHERE m.tenant_id = i.tenant_id AND m.task_id = i.task_id
        AND m.from_id = 'HUB-0' AND m.body LIKE 'Closed as % automatically: %'
        AND m.ts >= date_trunc('second', i.archived_at)
        AND m.ts <= i.archived_at + interval '5 minutes');
