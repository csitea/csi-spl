-- 0245_cost_entries.sql - the Cloud infra and HR costs the operator types on
-- the Expenses page (SPL-4383, spec 143; owner HUM-10, t1 4f48f878 msg
-- b0ccc0aa: "different types for the INSERTION Of at least the following
-- type of costs - AI costs , cloud infra cost , HR costs"). AI costs stay in
-- fleet_token_paid_items (rdb 0205). Forward-only.
--
--   cost_entries  one row per cost the operator entered: its type (cloud or
--                 hr), a label, amount in currency, paid for the month that
--                 starts on period (always the 1st). Entered through
--                 /v1/operator/cost-entries, never seeded.
--
-- Operator scope only, the pattern of rdb 0205: no tenant_id, the rows are the
-- instance's estate. created_by is the operator caller's hub id (a member id
-- or the operator service account). An HR row is a cost line, not a person's
-- record: its label names the role or the contract.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that reads this table (wf 20 does).

CREATE TABLE cost_entries (
    id          uuid          PRIMARY KEY,
    type        text          NOT NULL CHECK (type IN ('cloud', 'hr')),
    label       text          NOT NULL CHECK (length(label) BETWEEN 1 AND 100),
    amount      numeric(14,4) NOT NULL CHECK (amount > 0),
    currency    text          NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    period      date          NOT NULL CHECK (extract(day FROM period) = 1),
    note        text          NOT NULL DEFAULT '' CHECK (length(note) <= 2000),
    created_by  text          NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX cost_entries_type_period ON cost_entries (type, period);

ALTER TABLE cost_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_entries FORCE ROW LEVEL SECURITY;
CREATE POLICY operator_scope ON cost_entries
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
