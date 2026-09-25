-- 0043_messages_box_reply_level_backfill.sql — an agent's answer in a
-- channel thread is a reply. Forward-only.
--
-- A box frame carries no level, so until hub 0.5.6 (CLE-34978) every agent
-- line was stored is_parent 1: an answer an agent posted on a channel
-- topic's task sat in the channel feed as a new post, while the same answer
-- typed in the WUI reply pane was a reply (0). Measured 2026-09-25 17:35Z,
-- non-root rows under a channel topic: box dev 8 / prd 23, all 1; browser
-- dev 97 / prd 20, all 0. The hub now stores such a box line as 0
-- (hub.boxLevel); this file gives the rows stored before that the same
-- answer.
--
-- The root is what store.TopicChannel picks: the earliest is_parent 1 row of
-- the task. Only rows after it on a task whose root names a channel move;
-- the root itself, DM topics, browser rows and the legacy lobby task
-- (cnf SPOOL_HUB_LOBBY_TASK_ID, the same UUID in every env) are untouched.

UPDATE messages AS r
SET is_parent = 0
FROM (
    SELECT DISTINCT ON (tenant_id, task_id) tenant_id, task_id, msg_id, channel
    FROM messages
    WHERE is_parent = 1
    ORDER BY tenant_id, task_id, received_at, msg_id
) AS root
WHERE r.is_parent = 1
  AND r.from_box <> 'box-wui'
  AND r.task_id <> '00000000-0000-4000-8000-000000000001'
  AND root.tenant_id = r.tenant_id
  AND root.task_id = r.task_id
  AND root.msg_id <> r.msg_id
  AND root.channel IS NOT NULL;
