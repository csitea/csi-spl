-- 0162_tenant_roadmap_public.sql - a workspace's roadmap visibility switch
-- (specs/112 RDB-2, spec 12.5, OQ3 DECIDED in HUM-10 t1 4e373f5d msg
-- 730f6f90: "internal by default, with a per-workspace switch to make one
-- public"). Forward-only, additive.
--
--   tenants.roadmap_public  the switch a biz_owner or admin of the workspace
--                           flips (PATCH /v1/workspaces/<slug>/roadmap,
--                           HUB-2). false: the synced goal:, release: and
--                           spec: events are written internal (members of
--                           that workspace only); true: public. db: events
--                           stay internal either way (spec 4.3).
--
-- DEFAULT false (OQ3): no roadmap is public until its workspace says so.
-- The 0129 marketing_enabled pattern: NOT NULL with a constant default is a
-- catalog-only ADD COLUMN (pg 11+), no rewrite, and the running image ignores
-- it. RLS is unchanged: tenants already ENABLE + FORCE it (0021), and a
-- column needs no policy of its own. No change_stamp trigger: tenants is not
-- a cached-view table (0103), and the flag is read per sync and per switch.
-- No personal data.
-- DEPLOY ORDER: apply to dev and prd BEFORE the hub that reads it (HUB-2;
-- spec 072 A45, wf 20 migrates before it rolls).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS roadmap_public boolean NOT NULL DEFAULT false;
