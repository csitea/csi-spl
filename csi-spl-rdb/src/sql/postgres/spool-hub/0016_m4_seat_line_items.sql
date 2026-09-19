-- 0016_m4_seat_line_items.sql — M4 seats sold on the M2 payment rails
-- (specs/009-spool-m4 T002 monthly period, T004 seat line items, T005 the
-- project_id stamp at the paid webhook). Forward-only.
--
-- payment_checkouts gains the checkout's LINE ITEMS: seats_users /
-- seats_bots bought (0 = none; the M2 SKU always carries 0, 009 FR-001) and,
-- for a dedicated SKU, the buyer's org / app codes (NULL = hosted, no
-- project_id). amount_cents (0003) stays the total the rail charged.
--
-- tenant_seat_periods is the MONTHLY period of paid seats (009 D-4: the
-- period is the 006 UTC calendar month): one row per tenant per month, written
-- by the paid transition in the SAME transaction that writes the caps
-- (tenants.seats_users / seats_bots, 0012). period_start is the first day of
-- the UTC month of the paid event.
--
-- RLS as 0014 (tenant_scope + operator_scope, FORCE): the paid webhook writes
-- it as operator; a tenant-scoped read sees only its own rows.

ALTER TABLE payment_checkouts
    ADD COLUMN seats_users int  NOT NULL DEFAULT 0 CHECK (seats_users >= 0),
    ADD COLUMN seats_bots  int  NOT NULL DEFAULT 0 CHECK (seats_bots >= 0),
    ADD COLUMN org         text NULL CHECK (org IS NULL OR org ~ '^[a-z]{3}$'),
    ADD COLUMN app         text NULL CHECK (app IS NULL OR app ~ '^[a-z]{3}$'),
    ADD CONSTRAINT payment_checkouts_org_app_pair CHECK ((org IS NULL) = (app IS NULL));

CREATE TABLE tenant_seat_periods (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    period_start date        NOT NULL CHECK (extract(day FROM period_start) = 1),
    seats_users  int         NOT NULL CHECK (seats_users >= 0),
    seats_bots   int         NOT NULL CHECK (seats_bots >= 0),
    checkout_id  text        NOT NULL,
    amount_cents int         NOT NULL CHECK (amount_cents >= 0),
    paid_at      timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, period_start)
);

ALTER TABLE tenant_seat_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_seat_periods FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON tenant_seat_periods
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY operator_scope ON tenant_seat_periods
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
