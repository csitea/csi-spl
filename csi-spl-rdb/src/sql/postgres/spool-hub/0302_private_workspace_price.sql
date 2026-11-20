-- 0302_private_workspace_price.sql - the private-workspace price (spec 181
-- row B1, sections 0.2 and 4, gap G4 and the ledger half of G6). Forward-only,
-- additive.
--
-- Owner HUM-10, t1 b12055b5: we sell the harness at "cloud costs + 33% ...
-- and nothing else" (4f17f3da) and never resell tokens (be43a039, Q-10 A).
-- The answers that set the lines: Q-6 A (9 per month per human member,
-- agents are not seats), Q-7 A (EUR), Q-8 A (the VM only: compute, disk and
-- traffic), Q-9 A (drawn from the prepaid balance of 121 R7), Q-11 A (one
-- rate, 33%).
--
-- 1. price_plans: one plan per workspace. kind 'private_vm' is the only kind
--    (spec 181); currency 'EUR' the only currency (Q-7 A).
-- 2. price_plan_lines: what the plan charges, one row per line. Exactly two
--    lines exist: 'seat_member' (cents per human member per month) and
--    'vm_cost' (the VM's cloud cost + margin_pct %). A token line cannot be
--    written (P5): the line CHECK lists the two, and the no-token CHECK names
--    the rule so a later widening of the list still refuses any llm_ or
--    token line.
-- 3. usage_events.kind gains 'vm_cost': the VM's day cost drawn from the
--    prepaid balance. units = the cost in micros of EUR, unit_cost_micros =
--    (100 + margin_pct) / 100, so units * unit_cost_micros, the sum the
--    token_budgets balance subtracts (store/token_budget.go budgetUseSQL), is
--    the cost + 33%, and the raw cost stays readable. turn_id names the VM
--    and the day, so the unique (tenant, turn, kind) index makes a re-run of
--    a day a conflict, never a second charge.
--
-- RLS: both new tables in the 0171 shape with the NULLIF guard; store
-- TestRLSPoliciesFailClosed reads them from the catalogue and
-- TestCrossTenantEveryTable seeds them (price_plans_test.go). No
-- channel_scope policy: a visitor never reads a price plan.
--
-- Live-data safety: two new empty tables (the FKs take SHARE ROW EXCLUSIVE
-- on tenants until COMMIT, hence lock_timeout). The usage_events CHECK is
-- swapped in the 0300 way: the new list is a superset of the old one, added
-- NOT VALID (no scan under ACCESS EXCLUSIVE) and validated after. No running
-- hub writes 'vm_cost' before the image that reads this file. Runs under the
-- operator RLS scope (spool migrate, rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

CREATE TABLE price_plans (
    tenant_id  text        PRIMARY KEY REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    kind       text        NOT NULL CHECK (kind = 'private_vm'),
    currency   text        NOT NULL DEFAULT 'EUR' CHECK (currency = 'EUR'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE price_plan_lines (
    tenant_id       text     NOT NULL REFERENCES price_plans (tenant_id) ON DELETE CASCADE,
    line            text     NOT NULL CHECK (line IN ('seat_member', 'vm_cost')),
    cents_per_month bigint   NULL CHECK (cents_per_month >= 0),
    margin_pct      smallint NULL CHECK (margin_pct BETWEEN 0 AND 100),
    PRIMARY KEY (tenant_id, line),
    CONSTRAINT price_plan_lines_no_token_check CHECK (line NOT LIKE 'llm\_%' AND line NOT LIKE '%token%'),
    CONSTRAINT price_plan_lines_shape_check CHECK (CASE line
        WHEN 'seat_member' THEN cents_per_month IS NOT NULL AND margin_pct IS NULL
        ELSE margin_pct IS NOT NULL AND cents_per_month IS NULL END)
);

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['price_plans', 'price_plan_lines'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;

ALTER TABLE usage_events DROP CONSTRAINT IF EXISTS usage_events_kind_check;

ALTER TABLE usage_events ADD CONSTRAINT usage_events_kind_check
    CHECK (kind IN ('llm_tokens_in', 'llm_tokens_out', 'llm_tokens_cache_read', 'llm_tokens_cache_write',
                    'agent_seconds', 'storage_bytes', 'cloud_share', 'unmetered', 'vm_cost')) NOT VALID;

ALTER TABLE usage_events VALIDATE CONSTRAINT usage_events_kind_check;
