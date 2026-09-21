-- 0025_checkout_buyer_locale.sql — the language the BUYER was reading the
-- checkout in (spec 021 T022, CLE-3439). Forward-only.
--
-- payment_checkouts.buyer_locale is what the WUI was showing when the slug was
-- held (POST /api/v1/checkout body `locale` > X-Locale > Accept-Language).
-- NULL = the buyer never said: the claim mail then follows
-- SPOOL_HUB_DEFAULT_LOCALE at send time, which is what every checkout did
-- before this column existed.
--
-- The claim mail (tenant_paid) is sent by the paid webhook, long after the
-- buyer's request is gone, so its language can only come from a column on the
-- checkout row. The same value prefixes the claim link's WUI path
-- (i18n.LocalizeURL, prefix_except_default), so the buyer lands on the page in
-- the language they bought in.
--
-- The CHECK lists the same 19 supported locales as 0017 (internal/i18n
-- Supported); adding a locale is a new migration that replaces the constraint.
-- RLS: payment_checkouts keeps 0014's policies untouched — a column is added,
-- nothing about who may read the row changes.

ALTER TABLE payment_checkouts
    ADD COLUMN buyer_locale text NULL
        CONSTRAINT payment_checkouts_buyer_locale_check
        CHECK (buyer_locale IS NULL OR buyer_locale IN
            ('bg','fi','ru','en','sv','he','tr','mk','el','lt','et','lv','sr','ro','uk','sk','pl','es','nl'));
