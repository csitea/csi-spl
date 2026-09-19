-- 0011_payment_hold.sql — M2 checkout (specs/006 contracts/checkout-v1.md).
-- Forward-only. A checkout HOLDS a slug before any tenants row exists: the
-- tenant is created only by a verified paid event, so nothing answers on an
-- unpaid slug. The root private key is kept only SEALED under the buyer's
-- claim token (the hub stores its SHA-256, never the token) and is wiped on
-- the first claim.

ALTER TABLE payment_checkouts DROP CONSTRAINT IF EXISTS payment_checkouts_tenant_id_fkey;

ALTER TABLE payment_checkouts
    ADD COLUMN plan_id         text NOT NULL DEFAULT 'default',
    ADD COLUMN email           text,
    ADD COLUMN provider_ref    text,
    ADD COLUMN sealed_root_key bytea,
    ADD COLUMN claim_hash      bytea CHECK (claim_hash IS NULL OR octet_length(claim_hash) = 32),
    ADD COLUMN claimed_at      timestamptz;

-- One live hold per slug; an expired hold is cancelled before a new one.
CREATE UNIQUE INDEX payment_checkouts_one_hold ON payment_checkouts (tenant_id)
    WHERE status = 'pending';
