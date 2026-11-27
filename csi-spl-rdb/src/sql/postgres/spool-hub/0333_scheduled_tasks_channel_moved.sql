-- 0333_scheduled_tasks_channel_moved.sql - a channel move pauses the
-- scheduled tasks it leaves without a channel (spec 187 v0.7 sections 4.4 and
-- 8.1, SPL-6659; the R7 note N3 of row S1, SPL-6560). Forward-only, additive,
-- idempotent.
--
-- scheduled_tasks.paused_reason admits one more value:
--   channel_moved : a channel move (spec 169) took the task's only channel
--                   out of its scope_where, or the channel its move action
--                   names. Removing the id alone would leave scope_where {}
--                   (= every channel) or a move with no target, so the move
--                   pauses the task instead (store rewriteStaying).
--
-- Live-data safety: the CHECK only widens, so every stored row passes it;
-- it is re-added NOT VALID, so scheduled_tasks is not scanned under the
-- ACCESS EXCLUSIVE lock, and every new or changed row is checked.
-- lock_timeout bounds the wait for that lock. No row changes. No personal
-- data, no secret.
-- DEPLOY ORDER: apply before a hub that writes 'channel_moved'; an older hub
-- writes none and reads the value as an ordinary paused reason.
SET LOCAL lock_timeout = '5s';

ALTER TABLE scheduled_tasks DROP CONSTRAINT IF EXISTS scheduled_tasks_paused_reason_check;
ALTER TABLE scheduled_tasks ADD CONSTRAINT scheduled_tasks_paused_reason_check
    CHECK (paused_reason IN ('', 'by_person', 'done', 'owner_left', 'failing', 'cap', 'channel_moved')) NOT VALID;
