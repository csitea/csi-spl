-- 0293_cost_splits.sql - the instance's splits of the paid AI items and of a
-- person's hr costs over the workspaces (SPL-5768, spec 143
-- costs-allocation.md section 7; owner HUM-10, csitea f655b326 msg 3440bf12:
-- "the admin and the business owner should be able to define percentages
-- for the division of the costs, both for the tokens and for the personnel
-- costs, on a percentage basis, divided for each workspace").
-- Forward-only and idempotent (IF NOT EXISTS, DROP POLICY IF EXISTS): a re-run is a no-op.
--
--   cost_splits  one row per (split, workspace): that workspace's share in
--                basis points. split_kind tokens (subject '') covers every
--                paid AI item; split_kind person (subject = hr_people.id)
--                covers every hr cost entry of that person. The rows of one
--                split sum to 10000; the hub writes them in one transaction.
--                A split has no month: it holds for every month. Written
--                through PUT /v1/operator/cost-splits, never seeded.
--
-- Operator scope only, the pattern of rdb 0275 cost_allocations: no
-- tenant_id; workspace_id names where the share goes and is never an RLS
-- key. created_by is the caller's hub id.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that reads this table (wf 20 does).

CREATE TABLE IF NOT EXISTS cost_splits (
    split_kind    text        NOT NULL CHECK (split_kind IN ('tokens', 'person')),
    subject       text        NOT NULL CHECK (length(subject) <= 200),
    workspace_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    share_bp      integer     NOT NULL CHECK (share_bp BETWEEN 1 AND 10000),
    created_by    text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK ((split_kind = 'tokens' AND subject = '') OR (split_kind = 'person' AND subject <> '')),
    PRIMARY KEY (split_kind, subject, workspace_id)
);

ALTER TABLE cost_splits ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_splits FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON cost_splits;
CREATE POLICY operator_scope ON cost_splits
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
