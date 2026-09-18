-- 0003_payment.sql — M2 payment copy (specs/006-spool-hub-rental/contracts/payment.md).
-- Forward-only. Paid webhook → tenants.billing_status = active. Hub never
-- stores a card number or the tenant root private key. Duplicate delivery
-- ids are a 200 no-op (webhook_events_seen).

-- Checkout rows (one tenant plan purchase). root_pubkey is the PUBLIC half
-- generated at checkout so a first-payment webhook can create the tenant
-- if the unpaid row is not there yet. The private half is returned once
-- and never written here.
CREATE TABLE payment_checkouts (
    intent_id    text        PRIMARY KEY,
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    provider     text        NOT NULL,
    amount_cents int         NOT NULL CHECK (amount_cents >= 0),
    currency     text        NOT NULL,
    status       text        NOT NULL CHECK (status IN ('pending', 'paid', 'failed', 'cancelled')),
    root_pubkey  bytea       NOT NULL CHECK (octet_length(root_pubkey) = 32),
    created_at   timestamptz NOT NULL DEFAULT now(),
    paid_at      timestamptz
);
CREATE INDEX payment_checkouts_tenant ON payment_checkouts (tenant_id, status);

-- Idempotency for inbound payment webhooks. (provider, event_id) is the
-- dedup key; INSERT ON CONFLICT DO NOTHING is the replay guard.
CREATE TABLE webhook_events_seen (
    provider    text        NOT NULL,
    event_id    text        NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, event_id)
);
CREATE INDEX webhook_events_seen_received ON webhook_events_seen (received_at DESC);
