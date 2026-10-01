-- 0095_fleet_lease_holder_at_box.sql — the fleet lease holder takes the
-- fleet's session name, <agent id>@<box> (CLE-77911). Forward-only.
--
-- Owner, 2026-10-01 (t1 2efb3e78): "change the naming convention of the
-- sessions names to be CLE-<<id>>@<<box> where box should be preferably a 3
-- letter ... aka the new boxname should be just sat". 0094 wrote holders as
-- <machine>:<agent id>. This CHECK accepts BOTH shapes, so the DDL and the hub
-- that writes the new one can land in either order; no lease row existed
-- when it was written (the hub serving the lease frame had not rolled yet).
ALTER TABLE fleet_leases DROP CONSTRAINT IF EXISTS fleet_leases_holder_check;
ALTER TABLE fleet_leases ADD CONSTRAINT fleet_leases_holder_check CHECK (
    holder ~ '^[A-Za-z0-9_-]{1,32}@[a-z0-9][a-z0-9-]{0,31}$'
    OR holder ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}:[A-Za-z0-9_-]{1,32}$'
);
