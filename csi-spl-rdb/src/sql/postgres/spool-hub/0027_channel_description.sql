-- 0027_channel_description.sql — the channel description the WUI's "new
-- channel" dialog collects next to the title (channels-v1 §5.1).
-- Forward-only. NOT NULL DEFAULT '' so every existing row reads as "no
-- description" and no handler has to carry a NULL.

ALTER TABLE channels ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '';
