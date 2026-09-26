-- 0059_human_preferred_theme_warm.sql — reddish and orange palettes.
-- Forward-only. Widens the 0057 check; does not rewrite that file.
-- light-red's accent is rose, not the blocker red. light is still light blue.
ALTER TABLE humans DROP CONSTRAINT humans_preferred_theme_check;

ALTER TABLE humans
    ADD CONSTRAINT humans_preferred_theme_check
    CHECK (preferred_theme IS NULL OR preferred_theme IN
        ('dark','light','light-violet','light-green','light-yellow','light-orange','light-red'));
