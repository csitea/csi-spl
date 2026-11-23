-- 0315_private_workspace_invoices.sql - the private workspace's monthly
-- invoice and its one reminder (spec 181 row B12, gaps G6 and G13).
-- Forward-only, additive.
--
-- Owner HUM-10, t1 b12055b5: one invoice per month in arrears for the seats
-- and the VM cost + 33%, no prepaid balance (Q-9 B, Q-16 B, msg 6768e241);
-- paid by bank transfer (Q-18 C); due 14 days net from the invoice date, and
-- an unpaid one gets one reminder on day 15 (Q-19 A, msg 67b12564); a
-- reminder only, the agents keep running, the owner decides each case by
-- hand (Q-17 B, msg 43573325). No AI token is ever sold (P5, Q-10 A): the
-- row has no token column.
--
-- private_workspace_invoices: one row per workspace per month (the primary
-- key), the month's quote as rdb 0302's plan prices it (store QuoteMonth):
-- seat cents, the VM's month cost and its price in micros, the total in
-- micros. In arrears: issued_on is on or after the month's end, and due_on
-- is issued_on + 14; both held by CHECKs. paid_at is set by the
-- operator on the bank transfer (row B13); reminded_at is set once, by the
-- reminder tick's claim (WHERE reminded_at IS NULL), so the reminder goes
-- out once however many ticks or hub instances run.
--
-- RLS: the 0171 shape with the NULLIF guard, as rdb 0302; store
-- TestRLSPoliciesFailClosed reads it from the catalogue and
-- TestCrossTenantEveryTable seeds it (invoices_test.go). No channel_scope
-- policy: a visitor never reads an invoice.
--
-- Live-data safety: one new empty table (the FK takes SHARE ROW EXCLUSIVE on
-- tenants until COMMIT, hence lock_timeout). No existing table changes.
-- Runs under the operator RLS scope (spool migrate, rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

CREATE TABLE private_workspace_invoices (
    tenant_id       text          NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    month           date          NOT NULL CHECK (month = date_trunc('month', month)::date),
    currency        text          NOT NULL DEFAULT 'EUR' CHECK (currency = 'EUR'),
    humans          bigint        NOT NULL CHECK (humans >= 0),
    seat_cents      bigint        NOT NULL CHECK (seat_cents >= 0),
    vm_cost_micros  bigint        NOT NULL CHECK (vm_cost_micros >= 0),
    vm_price_micros numeric(20,6) NOT NULL CHECK (vm_price_micros >= 0),
    total_micros    numeric(20,6) NOT NULL CHECK (total_micros >= 0),
    issued_on       date          NOT NULL,
    due_on          date          NOT NULL,
    paid_at         timestamptz   NULL,
    reminded_at     timestamptz   NULL,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, month),
    CONSTRAINT private_workspace_invoices_due_check CHECK (due_on = issued_on + 14),
    CONSTRAINT private_workspace_invoices_arrears_check CHECK (issued_on >= (month + interval '1 month')::date)
);

-- The reminder tick's scan: unpaid, not yet reminded, by due date.
CREATE INDEX private_workspace_invoices_due_idx ON private_workspace_invoices (due_on)
    WHERE paid_at IS NULL AND reminded_at IS NULL;

ALTER TABLE private_workspace_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE private_workspace_invoices FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON private_workspace_invoices
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON private_workspace_invoices
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
