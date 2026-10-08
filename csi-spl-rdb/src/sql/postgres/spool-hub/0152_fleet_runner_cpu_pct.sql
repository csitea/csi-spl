-- 0152_fleet_runner_cpu_pct.sql - the runner CPU cap as an instance setting.
-- Forward-only, additive.
--
-- Owner HUM-10, t1 338e5258 b3573121: "yeah we need to reduce those numbers
-- so that there will be always some 20% extra capacity"; 569c4846: "do those
-- changes permanent in the db".
--
--   tenants.fleet_runner_cpu_pct   the % of a box's cores (1..100) that CI
--                                  runners plus agents may use; NULL = the
--                                  default (80). A box may carry its own in
--                                  fleet_box_bands."<box>".runner_cpu_pct
--                                  (rdb 0134's jsonb, no DDL for that).
--
-- The setting is the INSTANCE's, as 0118 / 0134 / 0149: only the operator
-- workspace's row (tenants.is_operator, rdb 0116) is read. The box's runner
-- budget (csi-spl-orc do_apply_gh_runner_cpu_budget) reads it; the hub
-- stores it and enforces nothing.
--
-- A NULL column: a catalog-only ADD COLUMN, no rewrite, and the running image
-- ignores it. RLS is unchanged: tenants already ENABLE + FORCE it (0021).
-- No personal data: one percentage.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS fleet_runner_cpu_pct smallint NULL
        CONSTRAINT tenants_fleet_runner_cpu_pct_check CHECK (fleet_runner_cpu_pct BETWEEN 1 AND 100);
