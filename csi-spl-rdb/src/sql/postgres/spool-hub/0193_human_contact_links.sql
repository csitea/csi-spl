-- 0193_human_contact_links.sql — which app an email address or a phone
-- number in a message opens for this person (SPL-1609). Forward-only.
-- humans is hub-wide and outside row level security, like the other layout
-- choices (0070, 0072, 0077, 0120); a per-tenant override rides
-- tenant_memberships.settings (0078) under the same keys.
--
-- Owner HUM-10, t1 51363151: "in the personal settings , one could configure
-- when clicking to a link which is email , which email client to open -
-- gmail in the browser , thunderbird , outlook , etc.", "the default should
-- be gmail in the browser"; then "the same should apply for the phone
-- numbers", "default should be whatsApp".
--
-- NULL = never picked: the WUI applies the default (gmail / whatsapp).
-- email_client 'gmail'       : Gmail compose in a new tab
--              'system'      : mailto:, the device's own mail app
--              'outlook-web' : Outlook on the web compose in a new tab
--              'outlook'     : mailto:, the desktop Outlook as the OS handler
--              'thunderbird' : mailto:, Thunderbird as the OS handler
-- phone_app    'whatsapp' | 'tel' | 'viber' | 'telegram' | 'signal' | 'teams'
ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS email_client text NULL;
ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS phone_app text NULL;

ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_email_client_check;
ALTER TABLE humans ADD CONSTRAINT humans_email_client_check
    CHECK (email_client IS NULL OR email_client IN ('gmail','system','outlook-web','outlook','thunderbird'));

ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_phone_app_check;
ALTER TABLE humans ADD CONSTRAINT humans_phone_app_check
    CHECK (phone_app IS NULL OR phone_app IN ('whatsapp','tel','viber','telegram','signal','teams'));
