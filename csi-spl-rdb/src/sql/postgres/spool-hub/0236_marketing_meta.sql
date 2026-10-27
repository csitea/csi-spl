-- 0236_marketing_meta.sql - spec 090 T031 (SPL-3873, epic SPL-2400): the
-- rdb 0187 marketing tables learn Facebook Pages and Instagram Professional
-- accounts, a post's candidate pictures and the explicit approval hold
-- (spec.md sections 16, 17 and 21). tasks.md named it 0229; 0229 and 0234
-- were taken on master first, so it is the next free one. Forward-only: four CHECK
-- swaps (each a wider list, so every existing row still passes) and two
-- columns with defaults. No new table, so the 0187 RLS policies cover it all.
--
--   marketing_channels.platform       + facebook_page, instagram_business
--   marketing_channels.account_type   + page, business (spec section 12
--                                       lists page; an Instagram Professional
--                                       account is a business account)
--   marketing_channels.metadata       jsonb object: the Page id, the
--                                       Instagram business id, the username,
--                                       the profile picture URL. Never a
--                                       token: tokens stay sealed in
--                                       marketing_channel_tokens.
--   marketing_posts.status            + awaiting_approval: a post made for a
--                                       channel without auto_publish waits
--                                       here. ClaimMarketingPosts selects
--                                       only 'scheduled', so a held post is
--                                       never dispatched until it is approved.
--   marketing_posts.media_assets      jsonb array: the candidate pictures
--                                       (url, width, height, aspect ratio,
--                                       selected).
--   marketing_post_events.event_type  + post_held, post_approved,
--                                       post_handed_over (the manual hand
--                                       over of spec section 17).
--
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (wf 20 migrates
-- before it rolls): the hub's queries read both new columns.

SET LOCAL lock_timeout = '5s';

ALTER TABLE marketing_channels DROP CONSTRAINT marketing_channels_platform_check;
ALTER TABLE marketing_channels ADD CONSTRAINT marketing_channels_platform_check
    CHECK (platform IN ('linkedin', 'facebook_page', 'instagram_business'));

ALTER TABLE marketing_channels DROP CONSTRAINT marketing_channels_account_type_check;
ALTER TABLE marketing_channels ADD CONSTRAINT marketing_channels_account_type_check
    CHECK (account_type IN ('personal', 'page', 'business'));

ALTER TABLE marketing_channels ADD COLUMN metadata jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE marketing_channels ADD CONSTRAINT marketing_channels_metadata_object
    CHECK (jsonb_typeof(metadata) = 'object');

ALTER TABLE marketing_posts DROP CONSTRAINT marketing_posts_status_check;
ALTER TABLE marketing_posts ADD CONSTRAINT marketing_posts_status_check
    CHECK (status IN ('awaiting_approval', 'skipped', 'scheduled', 'dispatching', 'published', 'failed'));

ALTER TABLE marketing_posts ADD COLUMN media_assets jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE marketing_posts ADD CONSTRAINT marketing_posts_media_assets_array
    CHECK (jsonb_typeof(media_assets) = 'array');

ALTER TABLE marketing_post_events DROP CONSTRAINT marketing_post_events_event_type_check;
ALTER TABLE marketing_post_events ADD CONSTRAINT marketing_post_events_event_type_check
    CHECK (event_type IN (
        'channel_connect', 'channel_expired', 'channel_reminder',
        'post_baseline', 'post_scheduled', 'post_dispatched', 'post_published', 'post_failed',
        'post_held', 'post_approved', 'post_handed_over'));
