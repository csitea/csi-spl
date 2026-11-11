-- 0275_cost_allocations.sql - an estate cost assigned or split to workspaces
-- by hand (SPL-5291, spec 143 costs-allocation.md; owner HUM-10, t1 41a74806
-- poll 0c5e94b4 answer C part B: "A cost (e.g. a shared cloud bill, a
-- person's hours) can be assigned or split to workspaces by hand, and each
-- workspace's page shows its share"; poll 01cbbdea answers 1B 2B 3B).
-- Forward-only.
--
--   cost_allocations  one row per (item, workspace): that workspace's share
--                     in basis points of the estate Persons or Cloud cost
--                     item (source, project_or_vendor, kind). The rows of
--                     one item are its split; the hub writes them in one
--                     transaction and their share_bp sum to 10000. A split
--                     has no month: it holds for every month, past ones too
--                     (answer 2 B). Written through PUT /v1/operator/
--                     cost-allocations and PUT /v1/tenant/cost-allocations,
--                     never seeded.
--
-- Operator scope only, the pattern of rdb 0245 cost_entries: the items are
-- the instance's estate, so the row has no tenant_id; workspace_id names
-- where the share goes and is never an RLS key. created_by is the caller's
-- hub id.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that reads this table (wf 20 does).

CREATE TABLE cost_allocations (
    source             text        NOT NULL CHECK (length(source) BETWEEN 1 AND 200),
    project_or_vendor  text        NOT NULL CHECK (length(project_or_vendor) BETWEEN 1 AND 200),
    kind               text        NOT NULL CHECK (length(kind) BETWEEN 1 AND 200),
    workspace_id       text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    share_bp           integer     NOT NULL CHECK (share_bp BETWEEN 1 AND 10000),
    created_by         text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, project_or_vendor, kind, workspace_id)
);

ALTER TABLE cost_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_allocations FORCE ROW LEVEL SECURITY;
CREATE POLICY operator_scope ON cost_allocations
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
