-- 0332_channel_default_priority.sql - the default priority of a channel's new
-- topics (spec 150 v1.8 section 3.3.2, build row B17, SPL-6658). Forward-only,
-- idempotent (a second apply changes nothing).
--
-- Owner HUM-10 (t1 b6c7b21c, poll ab1b0c08 answer msg 81cbf77e; poll
-- 9e0614a6 answer msg 1aa52a37): every channel has a default priority set in
-- its settings; an unset channel defaults to 3; only the workspace owner
-- changes it.
--
-- default_priority NULL = unset, read as 3 (store.TopicPriorityDefault);
-- 1..5 = the priority a new topic of the channel starts at. The CHECK is the
-- database half of the store's 1..5 refusal (ErrBadTopicPriority).
-- default_priority_by / _at are who last changed it and when ('' / NULL
-- before the first change).
--
-- Columns of an existing table: channels keeps its RLS policies (rdb 0021)
-- and change_stamp trigger, which cover the new columns. The running image
-- ignores them, so this file rolls before the image that reads them.
-- Live-data safety: three nullable or defaulted columns, no row changes. No
-- personal data, no secret.

ALTER TABLE channels ADD COLUMN IF NOT EXISTS default_priority smallint CHECK (default_priority BETWEEN 1 AND 5);
ALTER TABLE channels ADD COLUMN IF NOT EXISTS default_priority_by text NOT NULL DEFAULT '';
ALTER TABLE channels ADD COLUMN IF NOT EXISTS default_priority_at timestamptz;
