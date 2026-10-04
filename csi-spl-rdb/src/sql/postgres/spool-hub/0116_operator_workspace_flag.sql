-- 0116_operator_workspace_flag.sql - the operator workspace is recorded in
-- the database (spec 074 phase 1b, T002b; owner decision D1, HUM-10 t1
-- aa35699c msg 5d2e5ab5: "Where is the operator workspace recorded ... in
-- the db"). Forward-only, additive.
--
--   tenants.is_operator  true on the ONE workspace whose admins manage every
--                        other workspace of this instance through
--                        /v1/operator/workspaces (0115). false everywhere
--                        else, and on every workspace before this file.
--   tenants_operator_unique
--                        at most one operator workspace per instance.
--
-- No row is flagged here: which workspace is the operator one is estate
-- data (the cnf SPOOL_HUB_OPERATOR_TENANT, else SPOOL_HUB_WUI_APEX_TENANT),
-- and a migration file reads no cnf. The hub claims it once at start
-- (store.ClaimOperatorTenant): it flags the cnf workspace while NO row is
-- flagged, and from then on the database is the authority - the cnf is only
-- that bootstrap value.
--
-- NOT NULL with a constant default: a catalog-only ADD COLUMN (pg 11+), no
-- rewrite, and the running image ignores it. RLS is unchanged: tenants
-- already ENABLE + FORCE it (0021), and a column needs no policy of its own.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file - spec 072 A45
-- makes `spool serve` refuse a database behind its image. (The store still
-- probes the catalogue for the column, store/operator_flag.go, and falls back
-- to the cnf until it is there.)

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS is_operator boolean NOT NULL DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS tenants_operator_unique
    ON tenants (is_operator) WHERE is_operator = true;
