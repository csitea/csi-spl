-- 0185_fleet_ci_overflow.sql - the CI overflow switch and the runner core
-- count as instance settings. Forward-only, additive.
--
-- Owner HUM-10, t1 f67e3656 d4ba4b17: "If the GitHub runners are overwhelmed,
-- then we should spawn local runners, but we should cap them"; 70480eb3:
-- "This feature should be configurable to be put on or off, and the number of
-- cpus should also be configurable"; 61cd35bc: "From the settings for the
-- admin of the workspace settings".
--
--   tenants.fleet_ci_overflow   CI overflows to the box runners when the
--                               hosted runners are overwhelmed; NULL = the
--                               default (true, on).
--   tenants.fleet_runner_cpus   the cores (0..256) the CI box runners may
--                               take; NULL = the default (0 = no count, the
--                               box's cnf share). A box may carry its own in
--                               fleet_box_bands."<box>".runner_cpus (rdb
--                               0134's jsonb, no DDL for that).
--
-- The setting is the INSTANCE's, as 0118 / 0134 / 0149 / 0152: only the
-- operator workspace's row (tenants.is_operator, rdb 0116) is read. The
-- box's runner side reads it (`spool fleet-load get`); the hub stores it and
-- enforces nothing.
--
-- NULL columns: a catalog-only ADD COLUMN, no rewrite, and the running image
-- ignores them. RLS is unchanged: tenants already ENABLE + FORCE it (0021).
-- No personal data: one switch and one count.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS fleet_ci_overflow boolean NULL,
    ADD COLUMN IF NOT EXISTS fleet_runner_cpus smallint NULL
        CONSTRAINT tenants_fleet_runner_cpus_check CHECK (fleet_runner_cpus BETWEEN 0 AND 256);
