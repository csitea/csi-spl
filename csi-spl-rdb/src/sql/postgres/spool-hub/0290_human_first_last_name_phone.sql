-- 0290_human_first_last_name_phone.sql — a member's first name, last name and
-- phone number (SPL-5707, spec 154 section 12.5; owner HUM-10, t1 028ac340
-- msg ca3b3206, poll 36ec7895 A/A/A). Forward-only. humans is hub-wide and
-- outside row level security, like display_name (0006) and interests (0086).
--
-- The person edits all three in Settings -> Profile (PUT /v1/auth/preferences
-- first_name, last_name, phone). The member card (GET /v1/view/members/{id}/card)
-- shows them to the other members of a workspace; in a name-only workspace
-- (t1) only the two names, never the phone. The roster never carries the phone.
--
-- phone is E.164: '+', then 7..15 digits, the first not 0, stored normalised.
-- It is the member's own number, never read from personal.contacts (0226).
--
-- display_name stays and is NOT touched here: it changes only when the person
-- or an admin saves a name (then it is written as first || ' ' || last).
SET LOCAL lock_timeout = '5s';

ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS first_name text NULL,
    ADD COLUMN IF NOT EXISTS last_name text NULL,
    ADD COLUMN IF NOT EXISTS phone text NULL;

ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_first_name_check;
ALTER TABLE humans ADD CONSTRAINT humans_first_name_check
    CHECK (first_name IS NULL OR length(first_name) BETWEEN 1 AND 100);
ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_last_name_check;
ALTER TABLE humans ADD CONSTRAINT humans_last_name_check
    CHECK (last_name IS NULL OR length(last_name) BETWEEN 1 AND 100);
ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_phone_check;
ALTER TABLE humans ADD CONSTRAINT humans_phone_check
    CHECK (phone IS NULL OR phone ~ '^\+[1-9][0-9]{6,14}$');

-- Backfill from display_name, split at its FIRST run of whitespace: the first
-- word is the first name, the rest the last name ("Mary Ann Smith" -> Mary /
-- Ann Smith); one word is a first name only. Each part is cut to 100 chars.
-- Only the two new columns are written, and only where both are still NULL
-- (so a re-run changes nothing); display_name is left byte-identical.
UPDATE humans
   SET first_name = left(substring(btrim(display_name) FROM '^\S+'), 100),
       last_name  = left(NULLIF(btrim(regexp_replace(btrim(display_name), '^\S+\s*', '')), ''), 100)
 WHERE first_name IS NULL AND last_name IS NULL
   AND display_name IS NOT NULL AND btrim(display_name) <> '';
