-- 0129_tenant_marketing_switch.sql - marketing is switchable per workspace
-- (spec 090 §15; owner HUM-10, t1 f0c3927e msg 37bcb88b item 4: "a workspace
-- admin can turn it on/off at runtime (db flag + workspace settings toggle),
-- with cnf marketing.workspaces as the outer allow-list"). Forward-only,
-- additive.
--
--   tenants.marketing_enabled  the workspace admin's switch. Marketing is on
--                              for a workspace only when the cnf allow-list
--                              (SPOOL_HUB_MARKETING_WORKSPACES) names it, or
--                              is "all", AND this is true.
--
-- DEFAULT false (owner HUM-10, t1 f0c3927e msg 5cd2e544: "no even on dev
-- nobody should be spamming LinkedInn on Csitea Oy's behalf"): nothing posts
-- until an admin of an allow-listed workspace turns it on. Outside the
-- allow-list the value is never read, so it can turn nothing on there.
--
-- NOT NULL with a constant default: a catalog-only ADD COLUMN (pg 11+), no
-- rewrite, and the running image ignores it. RLS is unchanged: tenants
-- already ENABLE + FORCE it (0021), and a column needs no policy of its own.
-- No change_stamp trigger: the stamp (0103) covers only the tables a cached
-- view reads, tenants is not one of them, and the flag is read per request.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45;
-- wf 20 migrates before it rolls).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS marketing_enabled boolean NOT NULL DEFAULT false;
