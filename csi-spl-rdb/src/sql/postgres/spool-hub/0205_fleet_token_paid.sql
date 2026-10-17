-- 0205_fleet_token_paid.sql - what the operator PAID for the fleet's AI
-- vendors, so the hub can turn the token burn of rdb 0199 into an effective
-- price per token (SPL-2342; owner HUM-10, t1 e8ae0aad msg 9f549412: "I
-- should report the paid subscriptions and you would calculate the price per
-- token"). Forward-only.
--
--   fleet_token_paid_items  one row per paid item the operator entered: a
--                           subscription or a top-up of one vendor, quantity
--                           units at amount each (total = amount * quantity),
--                           in currency, paying for the UTC days
--                           [period_start, period_end). The hub spreads the
--                           total evenly over those days and divides the
--                           shares by the tokens burned on them
--                           (store.FleetPaidEffective). Entered through
--                           /v1/operator/fleet-tokens/paid, never seeded.
--
-- Operator scope only, the pattern of rdb 0199: no tenant_id, the rows are the
-- instance's estate. No personal data: created_by is the operator caller's
-- hub id (a member id or the operator service account).
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that reads this table (wf 20 does).

CREATE TABLE fleet_token_paid_items (
    id           uuid          PRIMARY KEY,
    vendor       text          NOT NULL CHECK (vendor IN ('claude', 'mistral', 'grok', 'agy', 'qwen')),
    kind         text          NOT NULL CHECK (kind IN ('subscription', 'topup')),
    plan_label   text          NOT NULL CHECK (length(plan_label) BETWEEN 1 AND 100),
    quantity     integer       NOT NULL DEFAULT 1 CHECK (quantity BETWEEN 1 AND 1000),
    amount       numeric(14,4) NOT NULL CHECK (amount > 0),
    currency     text          NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    period_start date          NOT NULL,
    period_end   date          NOT NULL,
    note         text          NOT NULL DEFAULT '' CHECK (length(note) <= 2000),
    created_by   text          NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT fleet_token_paid_period_check CHECK (period_end > period_start)
);
CREATE INDEX fleet_token_paid_vendor_period ON fleet_token_paid_items (vendor, period_start, period_end);

ALTER TABLE fleet_token_paid_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleet_token_paid_items FORCE ROW LEVEL SECURITY;
CREATE POLICY operator_scope ON fleet_token_paid_items
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
