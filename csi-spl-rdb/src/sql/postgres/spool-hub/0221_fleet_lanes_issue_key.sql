-- 0221_fleet_lanes_issue_key.sql - a lane row names its own issue (spec 153
-- v1.0 section 3.4, build row B3, SPL-3158; epic SPL-2403). Forward-only,
-- idempotent (a second apply changes nothing).
--
-- Owner HUM-10 (prd t1 5e7b15c9, msgs 5949d68e and 5c7d1395): a Monitoring
-- tab of the active lanes, from whose rows one jumps to the discussion and
-- from there to the issues. The lane's issue key lives only on its box
-- (<spool root>/<id>/lifetime/issue); `lane_op put` now carries it here, so
-- the hub's lanes view (hub/fleet_lanes_view.go) can link it.
--
--   fleet_lanes.issue_key   '' (no key, every row written before this) or a
--                           key like SPL-3075 (spec 153 3.4): a prefix of
--                           2..10 of [A-Z0-9], a letter first,
--                           a dash, a number of at most 9 digits.
--
-- Live-data safety: ADD COLUMN with a constant default is catalog-only and
-- every existing row satisfies the CHECK (''), so the validation scan reads
-- the table once under ACCESS EXCLUSIVE until COMMIT, hence lock_timeout.
-- No personal data, no secret.
-- EXPAND only: wf 20 applies this before the hub that writes the column
-- rolls; the old hub's upsert does not name it, so its rows keep the
-- default. Runs under the operator RLS scope (spool migrate, rdb 0014); the
-- RLS policies of 0096 stay as they are.

SET LOCAL lock_timeout = '5s';

ALTER TABLE fleet_lanes
    ADD COLUMN IF NOT EXISTS issue_key text NOT NULL DEFAULT '';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'fleet_lanes'::regclass AND conname = 'fleet_lanes_issue_key_check') THEN
        ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_issue_key_check
            CHECK (issue_key = '' OR issue_key ~ '^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$');
    END IF;
END $$;
