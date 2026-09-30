-- 0092_channel_archive.sql — archive a whole channel, and free a deleted
-- channel's name (HUM-10, topics ee21db20 + 32ea1b81). Forward-only.
--
-- Owner, prd 2026-09-30:
--   • "when I created a channel ... and then deleted it, when I tried to
--     recreate it with the same name I got the error that the channel name is
--     reserved, that should not be the case ... only if the channel is
--     archived" — DELETE now FREES the name: the hub hard-deletes the channels
--     row (channel_humans and channel_subscriptions cascade, rdb 0002 + 0028)
--     and its messages, so a new channel of the same slug inherits no topic,
--     member or message. This migration serves only the archive half.
--   • "add the archive function for a whole channel ... the channel name
--     cannot be used, but all of its topics and messages should be archived
--     too" — archived_at / archived_by on the channels row is that flag. A set
--     archived_at hides the channel everywhere (as the old soft delete did)
--     AND every topic card of the channel carries the per-message archived_at
--     (rdb 0065) stamped at the same instant, so the channel and its topics
--     move to the Archive view while the slug stays taken (CreateChannel
--     conflicts). Unarchive clears the channel stamp and only the cards this
--     archive stamped (same archived_at) — a card archived on its own before
--     the channel archive keeps its earlier stamp and stays archived.
--
-- The pre-0092 soft delete (rdb 0052 deleted_at) WAS this archive already —
-- hidden, name reserved, restorable — so its rows carry over as archived ones.
-- deleted_at / deleted_by stay as legacy columns that nothing writes any more.
--
-- The CHECK is the database half of "a default channel is never archived":
-- only a human-created channel (created_by HUM-*) may carry an archived_at.
-- The four defaults are created_by 'hub'.

ALTER TABLE channels ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE channels ADD COLUMN IF NOT EXISTS archived_by text;

UPDATE channels SET archived_at = deleted_at, archived_by = deleted_by
    WHERE deleted_at IS NOT NULL AND archived_at IS NULL;

ALTER TABLE channels DROP CONSTRAINT IF EXISTS channels_archive_human_only;
ALTER TABLE channels ADD CONSTRAINT channels_archive_human_only
    CHECK (archived_at IS NULL OR created_by LIKE 'HUM-%');
