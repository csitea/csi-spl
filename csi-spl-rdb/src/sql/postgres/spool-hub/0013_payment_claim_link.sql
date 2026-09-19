-- 0013_payment_claim_link.sql — 006 FR-014 as amended by 017 T008 / SEC-03:
-- the tenant root private key is NEVER emailed and never stored. It is minted
-- at the first successful claim and shown once in the browser. The email
-- carries a single-use, short-TTL claim LINK whose token is kept here only as
-- its SHA-256 (mail_claim_hash); the buyer's browser token stays in
-- claim_hash (0011). Both burn on the first claim; both die at
-- claim_expires_at. 0011's sealed_root_key is no longer written (always NULL).
-- Forward-only.

ALTER TABLE payment_checkouts
    ADD COLUMN mail_claim_hash  bytea CHECK (mail_claim_hash IS NULL OR octet_length(mail_claim_hash) = 32),
    ADD COLUMN claim_expires_at timestamptz;
