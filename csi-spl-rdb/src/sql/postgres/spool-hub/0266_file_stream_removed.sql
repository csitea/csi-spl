-- 0266_file_stream_removed.sql - spec 160 section 3.10 row B13 (SPL-4979; owner
-- HUM-10, t1 3331b0e6, msg 5bb5d078): a file removed from Monitoring -> File
-- streams stays removed. Forward-only, additive, idempotent. The spec names "the
-- next free number at build time": the next prefix on master when it lands
-- (renumbered on rebase).
--
--   file_streams.removed_at       set = removed by a workspace owner or admin.
--                                 A box's announce upserts the row and never
--                                 clears it, so the removal survives every
--                                 re-announce, whatever code the box runs; only
--                                 a put back clears it. The row's lines stay
--                                 until retention (3.7).
--   file_stream_glob_audit.action two more actions, file_remove and
--                                 file_restore (key = the stream key, glob = its
--                                 path, glob_id NULL): the one audit list of the
--                                 page (3.8.9).
--
-- No new table, so no new RLS: both tables keep the policies of rdb 0237 and
-- 0242. No secret, no personal data beyond the audit's actor human id.
-- DEPLOY ORDER: wf 20 applies this file before it rolls the hub that reads the
-- column; the running hub names its columns, so it does not see it.

SET LOCAL lock_timeout = '5s';

ALTER TABLE file_streams ADD COLUMN IF NOT EXISTS removed_at timestamptz NULL;

ALTER TABLE file_stream_glob_audit DROP CONSTRAINT IF EXISTS file_stream_glob_audit_action_check;
ALTER TABLE file_stream_glob_audit ADD CONSTRAINT file_stream_glob_audit_action_check
    CHECK (action IN ('add', 'remove', 'refused', 'file_remove', 'file_restore'));
