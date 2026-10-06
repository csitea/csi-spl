-- 0134_fleet_load_box_bands.sql - a per-box load band, overriding the fleet
-- band of rdb 0118 for the boxes it names. Forward-only, additive.
--
-- Owner HUM-10, t1 29b19f85: "we should have spool-hub only setting for
-- target hw load per box", "specify min-load and max-load ... default 50%
-- and 75%", and "In this way the load will be distributed also between the
-- boxes the way the admin desires".
--
--   tenants.fleet_box_bands   {"<box id>": {"low": <1..99>, "high": <2..100>}, ...}
--                             % of cores (load5 / cpus); a box not named
--                             takes fleet_load_low / fleet_load_high (0118),
--                             which default to store.DefaultFleetLoad.
--
-- The setting is the INSTANCE's, as 0118: only the operator workspace's row
-- (tenants.is_operator, rdb 0116) is read, and only that workspace's admin
-- writes it (PATCH /v1/operator/fleet-load). The hub checks each entry (box
-- id grammar, both marks in range, low < high, at most 32 boxes); the CHECK
-- here only keeps the column an object.
--
-- NULL column: a catalog-only ADD COLUMN, no rewrite, and the running image
-- ignores it. RLS is unchanged: tenants already ENABLE + FORCE it (0021).
-- No personal data: numbers and box ids only.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS fleet_box_bands jsonb NULL
        CONSTRAINT tenants_fleet_box_bands_check CHECK (jsonb_typeof(fleet_box_bands) = 'object');
