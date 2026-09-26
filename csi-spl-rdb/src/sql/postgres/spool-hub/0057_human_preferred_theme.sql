-- 0057_human_preferred_theme.sql — the colour theme a person reads the site in.
-- Forward-only. humans is hub-wide and outside row level security.
-- NULL = never picked: the WUI keeps the theme already stored in that browser.
-- 'light' is the light-blue palette (the violet, green, and yellow themes are
-- the other light ones).
ALTER TABLE humans
    ADD COLUMN preferred_theme text NULL
        CONSTRAINT humans_preferred_theme_check
        CHECK (preferred_theme IS NULL OR preferred_theme IN
            ('dark','light','light-violet','light-green','light-yellow'));
