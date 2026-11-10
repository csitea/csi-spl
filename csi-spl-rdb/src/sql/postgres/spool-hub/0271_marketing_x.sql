-- 0272_marketing_x.sql - spec 090 X row (SPL-5194, epic SPL-2376): the
-- marketing tables learn X (x.com) accounts. 0271 is held by another lane
-- (SPL-5126), so this is the next free number. Forward-only: one CHECK swap
-- to a wider list, so every existing row still passes. No new table or
-- column, so the 0187 RLS policies cover it all.
--
--   marketing_channels.platform   + x: a member's own X account, connected
--                                   with OAuth 2.0 PKCE. account_type stays
--                                   'personal'; metadata holds the username.
--                                   Its token pair (access + refresh) is
--                                   sealed as ONE ciphertext in
--                                   marketing_channel_tokens, never plain.
--
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (wf 20 migrates
-- before it rolls): the hub writes platform 'x'.

SET LOCAL lock_timeout = '5s';

ALTER TABLE marketing_channels DROP CONSTRAINT marketing_channels_platform_check;
ALTER TABLE marketing_channels ADD CONSTRAINT marketing_channels_platform_check
    CHECK (platform IN ('linkedin', 'facebook_page', 'instagram_business', 'x'));
