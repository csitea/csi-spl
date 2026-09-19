-- 0017_human_preferred_locale.sql — the language a person reads the site and
-- the hub's mail in (CLE-3403; ported from csi-rel users.preferred_locale).
-- Forward-only.
--
-- humans.preferred_locale is what the person picked on the WUI settings page
-- (PUT /api/v1/auth/preferences). NULL = never picked: the WUI follows the
-- browser, the mail follows the request / the registration locale.
--
-- password_credentials.preferred_locale is the locale the WUI was showing when
-- the email + password account was registered (POST /api/v1/auth/register,
-- X-Locale > Accept-Language > SPOOL_HUB_DEFAULT_LOCALE). A credential exists
-- before its human does (0009: the HUM-* is created on the first admitted
-- login), so the verification mail can only follow this column. Once a human
-- exists, humans.preferred_locale wins when set.
--
-- Both tables are hub-wide and stay outside 0014's row level security.
-- The CHECK lists the 19 supported locales (internal/i18n Supported); adding
-- a locale is a new migration that replaces the constraint.

ALTER TABLE humans
    ADD COLUMN preferred_locale text NULL
        CONSTRAINT humans_preferred_locale_check
        CHECK (preferred_locale IS NULL OR preferred_locale IN
            ('bg','fi','ru','en','sv','he','tr','mk','el','lt','et','lv','sr','ro','uk','sk','pl','es','nl'));

ALTER TABLE password_credentials
    ADD COLUMN preferred_locale text NULL
        CONSTRAINT password_credentials_preferred_locale_check
        CHECK (preferred_locale IS NULL OR preferred_locale IN
            ('bg','fi','ru','en','sv','he','tr','mk','el','lt','et','lv','sr','ro','uk','sk','pl','es','nl'));
