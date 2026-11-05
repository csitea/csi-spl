-- 0264_fleet_lanes_topic_issue_required.sql - a lane row always names its
-- discussion and its issue (spec 153 section 3.21, SPL-4799; epic SPL-2403).
-- Forward-only, idempotent (a second apply changes nothing).
--
-- Owner HUM-10 (prd t1 0c2d08a2, 2026-11-04): "the tble of the lanes must
-- not accept nulls , for neither discussions nor issues" (msg 80bee509) and
-- "for the already nulls , do not use resources to search what they were
-- related to -, use the unknown string" (msg 937e89a4).
--
-- fleet_lanes.topic and .issue_key were NOT NULL already (0096, 0221); the
-- empty string was their "none", and the DEFAULT '' let an insert leave them
-- out. Now:
--
--   1. every '' (and any NULL) becomes the literal 'unknown', no search;
--   2. the DEFAULT '' goes: an insert that names no topic or no issue_key
--      fails on NOT NULL;
--   3. a CHECK refuses '' in either column; issue_key holds an issue key
--      or 'unknown'.
--
-- origin_issue (0253) stays optional: the rule is one discussion and one
-- issue per lane, and issue_key is the lane's issue.
--
-- Live-data safety: the table holds about 1000 rows (prd 2026-11-05: 1008);
-- the UPDATEs and the CHECK validations each read it once under the lock,
-- hence lock_timeout. No personal data, no secret. Runs under the operator
-- RLS scope (spool migrate, rdb 0014); the RLS policies of 0096 stay.

SET LOCAL lock_timeout = '5s';

-- The 0221 CHECK allows only '' or a key, so it would refuse the 'unknown'
-- the UPDATE writes: it goes first and comes back in its new form below.
ALTER TABLE fleet_lanes DROP CONSTRAINT IF EXISTS fleet_lanes_issue_key_check;

UPDATE fleet_lanes SET topic = 'unknown' WHERE topic IS NULL OR topic = '';
UPDATE fleet_lanes SET issue_key = 'unknown' WHERE issue_key IS NULL OR issue_key = '';

ALTER TABLE fleet_lanes ALTER COLUMN topic DROP DEFAULT;
ALTER TABLE fleet_lanes ALTER COLUMN issue_key DROP DEFAULT;
ALTER TABLE fleet_lanes ALTER COLUMN topic SET NOT NULL;
ALTER TABLE fleet_lanes ALTER COLUMN issue_key SET NOT NULL;

ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_issue_key_check
    CHECK (issue_key = 'unknown' OR issue_key ~ '^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$');

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'fleet_lanes'::regclass AND conname = 'fleet_lanes_topic_set_check') THEN
        ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_topic_set_check CHECK (topic <> '');
    END IF;
END $$;
