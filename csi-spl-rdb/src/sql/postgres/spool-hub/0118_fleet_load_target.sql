-- 0118_fleet_load_target.sql - the fleet load target: the band a box's load
-- should stay in, and the order the boxes take new agent lanes. Forward-only,
-- additive.
--
-- Owner HUM-10, t1 c13e8023: "we should aim for utilization rate between 50%
-- and 75%", "only after that transfer load to the [next] box", "this should
-- be also some what configurable", and (msg 5fa43972) "this setting should
-- be configurable from the spool-hub instance only in every cloud instance".
--
--   tenants.fleet_load_low    the band's low mark, % of cores (load5 / cpus).
--   tenants.fleet_load_high   the band's high mark: a box at or above it takes
--                             no new lane; the next box in the order does.
--   tenants.fleet_box_order   the boxes' fill order (box ids, the lane map's
--                             agent_box); a box not named comes after them.
--
-- The setting is the INSTANCE's: only the operator workspace's row
-- (tenants.is_operator, rdb 0116) is read, and only that workspace's admin
-- writes it (PATCH /v1/operator/fleet-load). NULL = "the default", which
-- lives in ONE place, store.DefaultFleetLoad (50 / 75, no order: the box's
-- cnf env.box.fleet_load.box_order seeds it), as agent_lifecycle_config does
-- (rdb 0105). The hub checks low < high on the values in force.
--
-- NULL columns: a catalog-only ADD COLUMN, no rewrite, and the running image
-- ignores them. RLS is unchanged: tenants already ENABLE + FORCE it (0021).
-- No personal data: numbers and box ids only.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS fleet_load_low smallint NULL
        CONSTRAINT tenants_fleet_load_low_check CHECK (fleet_load_low BETWEEN 1 AND 99),
    ADD COLUMN IF NOT EXISTS fleet_load_high smallint NULL
        CONSTRAINT tenants_fleet_load_high_check CHECK (fleet_load_high BETWEEN 2 AND 100),
    ADD COLUMN IF NOT EXISTS fleet_box_order text[] NULL
        CONSTRAINT tenants_fleet_box_order_check CHECK (
            cardinality(fleet_box_order) <= 32
            AND array_to_string(fleet_box_order, ',') ~ '^([a-z0-9][a-z0-9-]{0,31}(,[a-z0-9][a-z0-9-]{0,31})*)?$');
