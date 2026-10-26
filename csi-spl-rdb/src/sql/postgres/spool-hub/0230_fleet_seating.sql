-- 0230_fleet_seating.sql - fleet seating, the hub half of spec 158 section
-- 4.2 (items 1 and 2, build row T4): "a new workspace works automatically"
-- (owner HUM-10, t1 99ffa592, msg e0510945). Forward-only, additive,
-- idempotent.
--
--   tenants.fleet_seating  true: the fleet desk boxes may enrol a key into
--                          this workspace and seat the role seats in it
--                          (POST /v1/fleet/enrol, row T7). Written only by an
--                          admin of the operator workspace (PATCH
--                          /v1/operator/workspaces/{id}, audited) and by the
--                          create route (row T5, default true there). DEFAULT
--                          false here, for every existing workspace too: the
--                          backfill (do_spl_fleet_seating_switch, row T12)
--                          switches those, on its own go.
--   fleet_desk_boxes       the desk boxes of the operator workspace that may
--                          self-enrol (PUT/DELETE /v1/operator/fleet-desks/
--                          {box}, do_spl_fleet_desk_box). A box is listed only
--                          while it holds a live pin in the operator
--                          workspace; the route checks it, since the operator
--                          workspace id is cnf, not a constant here. Removing
--                          a row stops new enrolments (spec 158 4.2.5).
--
-- RLS: fleet_desk_boxes has no tenant_id, it is the estate's own list, so it
-- carries the operator policy only (the 0199 shape): a tenant scope and no
-- scope read and write no row. tenants already ENABLE + FORCE it (0021), and
-- a column needs no policy of its own. The runtime grants come from the
-- default privileges of spool-hub-roles/runtime-grants.sql, like every table
-- since 017. NOT NULL with a constant default is a catalog-only ADD COLUMN
-- (pg 11+), no rewrite. No change_stamp trigger, no personal data.
-- DEPLOY ORDER: wf 20 applies this file to dev and prd before it rolls the
-- hub that reads either; the running hub names its columns, so it never
-- sees them.

SET LOCAL lock_timeout = '5s';

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS fleet_seating boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS fleet_desk_boxes (
    box_id   text        PRIMARY KEY CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    added_by text        NOT NULL CHECK (length(added_by) BETWEEN 1 AND 64),
    added_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE fleet_desk_boxes ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleet_desk_boxes FORCE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                   WHERE schemaname = current_schema() AND tablename = 'fleet_desk_boxes'
                     AND policyname = 'operator_scope') THEN
        CREATE POLICY operator_scope ON fleet_desk_boxes
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
    END IF;
END
$$;
