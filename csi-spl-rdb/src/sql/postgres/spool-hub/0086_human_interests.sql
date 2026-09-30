-- 0086_human_interests.sql — a person's free-text interests, shown in the
-- People section's info card (CLE-77794). Forward-only. humans is hub-wide and
-- outside row level security, like display_name (0006) and submit_key (0062).
-- NULL = never set: the card shows no interests line. The person edits it in
-- Settings -> Profile (PUT /v1/auth/preferences interests, mirroring
-- display_name); every tenant member reads it on GET /v1/view/roster.
ALTER TABLE humans
    ADD COLUMN interests text NULL
        CONSTRAINT humans_interests_check
        CHECK (interests IS NULL OR length(interests) <= 1000);
