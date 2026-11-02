-- 0252_fleet_lanes_origin_issue.sql - a lane row names the issue it came from
-- (spec 153 section 3.12, SPL-4620; owner HUM-10, t1 4e9f7153, msg 9a89d1e1:
-- "Once a lane is created it it should add a link to both the discussions
-- from where it originated and to the issue from where it originated").
--
--   fleet_lanes.origin_issue  '' (none, every row written before this) or an
--                             issue key. issue_key stays the lane's own issue;
--                             a lane placed on an existing issue has the same
--                             key in both.
--
-- The constant default rewrites no row and no closed lane is backfilled. The
-- CHECK scans the table once (about 2000 rows); RLS of 0096 stays as it is.

SET LOCAL lock_timeout = '5s';

ALTER TABLE fleet_lanes
    ADD COLUMN IF NOT EXISTS origin_issue text NOT NULL DEFAULT '';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'fleet_lanes'::regclass AND conname = 'fleet_lanes_origin_issue_check') THEN
        ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_origin_issue_check
            CHECK (origin_issue = '' OR origin_issue ~ '^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$');
    END IF;
END $$;
