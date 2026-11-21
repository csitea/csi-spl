-- 0305_cost_entry_covers.sql - which cost entry is the invoice of the GCP
-- billing export, and which billing account each export read was of
-- (SPL-6086, spec 143 costs-workspace-views.md section 4.2, row R1; owner
-- HUM-10, csitea bc9956bf msg 3046f23e: the manual Google Cloud amount must
-- not duplicate the export). Forward-only, additive, idempotent.
--
--   cost_entries.covers_source   NULL, or 'gcp': this entry is the invoice
--                                of what that source exports, so the month
--                                read shows the export lines plus the rest
--                                of the invoice instead of both (section
--                                4.1, row R3). Set only through PATCH
--                                /v1/operator/cost-entries/{id} or the
--                                invoice import (row R3), never by label.
--   cost_coverage.account_last4  NULL, or the last 4 characters of the
--                                billing account id the ingest run read
--                                (the export table's name ends with it);
--                                filled by the ingest from row R3 on. Only
--                                the last 4, never the whole id.
--
-- The one-entry-per-month rule and the account match of section 4.2 are the
-- hub's 409 checks (row R3), not constraints here.
--
-- Live-data safety: two nullable columns with no default and each CHECK
-- added NOT VALID, so neither table is rewritten or scanned under the
-- ACCESS EXCLUSIVE lock (one transaction per file, rdb 0302's lesson); every
-- existing row is NULL, which the CHECK admits, and every new row is
-- checked. lock_timeout bounds the wait for the lock. No row changes.

SET LOCAL lock_timeout = '5s';

ALTER TABLE cost_entries ADD COLUMN IF NOT EXISTS covers_source text;
ALTER TABLE cost_entries DROP CONSTRAINT IF EXISTS cost_entries_covers_source_check;
ALTER TABLE cost_entries ADD CONSTRAINT cost_entries_covers_source_check
    CHECK (covers_source IS NULL OR covers_source = 'gcp') NOT VALID;

ALTER TABLE cost_coverage ADD COLUMN IF NOT EXISTS account_last4 text;
ALTER TABLE cost_coverage DROP CONSTRAINT IF EXISTS cost_coverage_account_last4_check;
ALTER TABLE cost_coverage ADD CONSTRAINT cost_coverage_account_last4_check
    CHECK (account_last4 IS NULL OR account_last4 ~ '^[A-Za-z0-9]{4}$') NOT VALID;
