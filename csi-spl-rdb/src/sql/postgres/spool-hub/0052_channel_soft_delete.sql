-- 0052_channel_soft_delete.sql — a created channel can be deleted by the
-- member who created it (SPL-72, channels-v1 §5.4). Forward-only.
--
-- Owner, 2026-09-26: "channels should have the delete option in the right
-- click menu , for the owners who have created them".
--
-- SOFT delete: DELETE /v1/channels/{channel} stamps deleted_at / deleted_by
-- and removes nothing. Its messages, its members (channel_humans) and its
-- agent seats (channel_subscriptions) stay, so the way back is one UPDATE
-- (do_spl_channel_restore). While deleted_at is set the hub treats the
-- channel as absent everywhere: every member read (the channel list, search,
-- topics, files) and every agent delivery goes through the membership rows,
-- and those lookups skip a deleted channel. Its messages still expire on
-- their own retention. The slug stays taken while deleted, so a restore can
-- never collide with a newer channel of the same name.
--
-- The CHECK is the database half of "a default channel can never be
-- deleted": only a channel a human created (created_by HUM-*) may carry a
-- deleted_at. The four defaults are created_by 'hub'.

ALTER TABLE channels ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE channels ADD COLUMN IF NOT EXISTS deleted_by text;

ALTER TABLE channels DROP CONSTRAINT IF EXISTS channels_delete_human_only;
ALTER TABLE channels ADD CONSTRAINT channels_delete_human_only
    CHECK (deleted_at IS NULL OR created_by LIKE 'HUM-%');
