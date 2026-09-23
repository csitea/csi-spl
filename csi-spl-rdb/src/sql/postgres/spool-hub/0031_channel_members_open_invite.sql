-- 0031_channel_members_open_invite.sql — channel setting "everyone can
-- invite new members" (channels-v1 §7.4). Forward-only. NOT NULL DEFAULT
-- false so every existing channel stays owner-only, and no handler has to
-- carry a NULL. Off: only the channel owner (channels.created_by matching
-- ^HUM-) may add a member. On: every current member may.

ALTER TABLE channels ADD COLUMN IF NOT EXISTS members_open_invite boolean NOT NULL DEFAULT false;
