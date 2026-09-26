-- 0050_issue_channel_replaces_tasks.sql — #tasks is removed; issues replace
-- it (SPL-68, specs/039 §3.4). Forward-only.
--
-- Owner, 2026-09-26: "the tasks channel should be removed - issues should be
-- used for it".
--
-- Until this file every issue's discussion was a topic in #tasks (hub 0.7.x,
-- IssueChannel = tasks). From here it lives on the reserved id 'issues': a
-- messages.channel value that is NOT a channel. It has no channels row (the
-- column has no FK), is never listed, can never be created, takes no agents,
-- and every member of the tenant reads it, as they read the issue list.
--
-- Order: the hub that reads 'issues' (and still reads a leftover 'tasks' row
-- as public and hidden) rolls FIRST; this file runs after, so no reader ever
-- meets an 'issues' row it would judge private.
--
-- Measured before writing it (do_spl_db_query, 2026-09-26 ~09:00Z):
--   dev t1   29 #tasks topics: 2 issue discussions, 27 proof artefacts
--            ("L1 channel ...", "L3 channel ...", "attach L1 channel ...",
--            "[spool-probe] clip ...");
--   prd t1   3 topics, all issue discussions;
--   prd e2e  11 topics: 2 issue discussions, 9 proof artefacts.
-- No human-written task sits in #tasks, so nothing becomes an issue here: the
-- artefacts move to #lobby (kept, visible, normal retention). No tenant on
-- either env has a channel named 'issues'; no #tasks row carries an agent
-- (channel_subscriptions) or a human (channel_humans). UPDATE OF channel
-- fires no 0023 period trigger.

-- 1. An issue's discussion: its topic, and any thread rooted under it.
UPDATE messages AS m
SET channel = 'issues'
WHERE m.channel = 'tasks'
  AND EXISTS (SELECT 1 FROM issues i
              WHERE i.tenant_id = m.tenant_id
                AND (i.task_id = m.task_id OR i.task_id = m.parent_task_id));

-- 2. Everything else that was in #tasks goes to #lobby.
UPDATE messages SET channel = 'lobby' WHERE channel = 'tasks';

-- 3. A new tenant is seeded with lobby, alerts and feedback only (0046 was
--    the last to redefine this function).
CREATE OR REPLACE FUNCTION spool_seed_default_channels() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO channels (tenant_id, channel_id, name, created_by)
    SELECT NEW.tenant_id, d.channel_id, d.channel_id, 'hub'
    FROM (VALUES ('lobby'), ('alerts'), ('feedback')) AS d (channel_id)
    ON CONFLICT (tenant_id, channel_id) DO NOTHING;
    RETURN NEW;
END $$;

-- 4. Every tenant loses its #tasks row; channel_subscriptions and
--    channel_humans rows cascade (the FKs are ON DELETE CASCADE).
DELETE FROM channels WHERE channel_id = 'tasks';

-- 5. Neither id can come back as a created channel, like 'general' (0008):
--    a new #tasks would pick up stray old rows, and 'issues' is not a channel.
ALTER TABLE channels ADD CONSTRAINT channels_not_issues_or_tasks
    CHECK (channel_id NOT IN ('issues', 'tasks'));
