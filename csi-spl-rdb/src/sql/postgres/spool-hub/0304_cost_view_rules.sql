-- 0304_cost_view_rules.sql - each workspace's view of the estate's costs
-- (SPL-6086, spec 143 costs-workspace-views.md sections 3.1-3.2, row R1;
-- owner HUM-10, csitea bc9956bf, msgs 3183590c, 7616b11a, 5d7912cd: csitea
-- shows every cost, spool-hub a part of the same costs). Forward-only and
-- idempotent (IF NOT EXISTS, DROP POLICY IF EXISTS): a re-run is a no-op.
--
--   cost_view_rules  one row per (workspace, label, match): what part of the
--                    estate's costs that workspace shows for one label, in
--                    basis points. label cloud takes a match: '*' (every GCP
--                    project and every cloud cost entry) or '<prefix>*' (the
--                    GCP projects whose id starts with <prefix>); persons and
--                    tokens take match ''. A view, not a partition: the
--                    shares of one label across workspaces need not sum to
--                    10000. A workspace's rules are written whole, in one
--                    transaction, through PUT /v1/operator/cost-view-rules
--                    (row R2), never seeded. The overlap check of section 3.1
--                    (two Cloud matches of one workspace) is the hub's.
--
-- Operator scope only, the pattern of rdb 0275 cost_allocations and 0293
-- cost_splits: no tenant_id; workspace_id names whose view it is and is never
-- an RLS key. created_by is the caller's hub id.
--
-- Live-data safety: one new empty table (its FK takes SHARE ROW EXCLUSIVE on
-- tenants until COMMIT, hence lock_timeout). No existing table changes.
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that reads this table (wf 20 does).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS cost_view_rules (
    workspace_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    label         text        NOT NULL CHECK (label IN ('cloud', 'persons', 'tokens')),
    match         text        NOT NULL CHECK (match = '' OR match = '*' OR match ~ '^[a-z0-9-]{1,60}\*$'),
    share_bp      integer     NOT NULL CHECK (share_bp BETWEEN 1 AND 10000),
    created_by    text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK ((label = 'cloud') = (match <> '')),
    PRIMARY KEY (workspace_id, label, match)
);

ALTER TABLE cost_view_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_view_rules FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON cost_view_rules;
CREATE POLICY operator_scope ON cost_view_rules
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
