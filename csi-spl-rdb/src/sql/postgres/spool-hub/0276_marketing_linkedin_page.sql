-- 0276_marketing_linkedin_page.sql - spec 090 phase 4, T041 (SPL-5258, epic
-- SPL-2376; linkedin-company-page.md section 6.1): the marketing tables learn
-- LinkedIn Company Pages. Forward-only: one CHECK swap to a wider list, so
-- every existing row still passes. No new table or column, so the 0187 RLS
-- policies cover it all.
--
--   marketing_channels.platform   + linkedin_page: a LinkedIn Company Page,
--                                   connected through the second LinkedIn app
--                                   (Community Management API) by a Page
--                                   Super admin or Content admin.
--                                   account_type 'page' (0236 already allows
--                                   it); account_ref is the organization id;
--                                   metadata holds the organization urn, the
--                                   vanity slug and the connector's Page role,
--                                   never a token. Its token bundle (access +
--                                   refresh) is sealed as ONE ciphertext in
--                                   marketing_channel_tokens, never plain.
--
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (wf 20 migrates
-- before it rolls): the hub writes platform 'linkedin_page'.

SET LOCAL lock_timeout = '5s';

ALTER TABLE marketing_channels DROP CONSTRAINT marketing_channels_platform_check;
ALTER TABLE marketing_channels ADD CONSTRAINT marketing_channels_platform_check
    CHECK (platform IN ('linkedin', 'facebook_page', 'instagram_business', 'x', 'linkedin_page'));
