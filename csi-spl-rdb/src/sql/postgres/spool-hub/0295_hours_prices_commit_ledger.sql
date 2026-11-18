-- 0295_hours_prices_commit_ledger.sql - each person's hourly price and a
-- commit's human time (spec 107 sections 21.5, 21.6, 21.8; task T071,
-- SPL-5913; owner HUM-10 poll e47404d1 msg a7ec216c, Q29 B poll 221a0f08
-- msg a935328b). Forward-only, additive. After rdb 0294 (T078, the
-- hours.prices permission).
--
--   member_hourly_prices  one row per (workspace, member, start day): the
--                         price the biz owner set, in force from valid_from
--                         (the priced person's local day) to the next row.
--                         set_by names the biz owner who wrote it. No route
--                         reads or writes it yet (T072).
--   commit_human_time     a landed commit's approved human minutes per
--                         (day, currency), and their amount in that
--                         currency. currency NULL holds the minutes of the
--                         members with no price (amount NULL: unpriced).
--                         No member column (spec 21.7, P0). Written by the
--                         hours sweep (T075), in the operator scope only.
--   hours_entries_approved_target
--                         the counter read (spec 21.2): approved entries per
--                         (workspace, target).
--
-- RLS:
--   member_hourly_prices  the 3.2 shape (tenant_scope with the NULLIF guard,
--                         operator_scope), plus the 3.4 RESTRICTIVE
--                         member_scope guard of rdb 0176: app.member_id
--                         unset or '' is TRUE (the biz owner's and the
--                         time-accountant's list read every member); set, a
--                         row passes only when it is that member's, so
--                         GET /v1/me/hours/price (spec 21.5 rule 8) reads
--                         no other member's price even without its filter.
--   commit_human_time     the final form of commit_token_burn (spec 171
--                         section 3.3.3, owner Q5 msg 331b339b): read in the
--                         workspace's own scope (FOR SELECT, NULLIF guard),
--                         written ONLY in the operator scope. Its foreign
--                         key is release_notes' key (tenant_id, repo_slug,
--                         sha, rdb 0281), which needs the tenant_id. Who of
--                         the workspace may see the minutes and the money
--                         (operator admins; money with hours.rates, spec
--                         21.4 step 7) is the route's gate (T075).
--
-- The ledger key is a UNIQUE index NULLS NOT DISTINCT (PG 15+, as rdb 0166),
-- so the unpriced row of a (commit, day) is one row and the sweep UPSERTs.
--
-- Live-data safety: two new empty tables; the index on hours_entries takes a
-- SHARE lock for one scan (dev and prd hold few rows), hence lock_timeout.
-- No price is seeded: none exists on master to carry (spec 21.5). Runtime
-- grants: the default privileges of spool-hub-roles/runtime-grants.sql.
-- Runs under the operator RLS scope (spool migrate, rdb 0014). No secret.
-- DEPLOY ORDER: none; the running hub reads neither table.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS member_hourly_prices (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id     text        NOT NULL CHECK (length(member_id) BETWEEN 1 AND 64),
    valid_from    date        NOT NULL,
    amount_micros bigint      NOT NULL CHECK (amount_micros > 0),
    currency      char(3)     NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    set_by        text        NOT NULL CHECK (length(set_by) BETWEEN 1 AND 64),
    set_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id, valid_from)
);

CREATE TABLE IF NOT EXISTS commit_human_time (
    tenant_id     text        NOT NULL,
    repo_slug     text        NOT NULL,
    sha           text        NOT NULL,
    day_bucket    date        NOT NULL,
    currency      char(3)     NULL CHECK (currency ~ '^[A-Z]{3}$'),
    issue_key     text        NOT NULL CHECK (length(issue_key) BETWEEN 1 AND 64),
    minutes       integer     NOT NULL CHECK (minutes >= 0),
    amount_micros bigint      NULL CHECK (amount_micros >= 0),
    written_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT commit_human_time_unpriced CHECK (currency IS NOT NULL OR amount_micros IS NULL),
    CONSTRAINT commit_human_time_note_fk FOREIGN KEY (tenant_id, repo_slug, sha)
        REFERENCES release_notes (tenant_id, repo_slug, sha) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS commit_human_time_key ON commit_human_time
    (tenant_id, repo_slug, sha, day_bucket, currency) NULLS NOT DISTINCT;

CREATE INDEX IF NOT EXISTS hours_entries_approved_target ON hours_entries (tenant_id, target)
    WHERE state = 'approved';

ALTER TABLE member_hourly_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_hourly_prices FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON member_hourly_prices;
CREATE POLICY tenant_scope ON member_hourly_prices
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON member_hourly_prices;
CREATE POLICY operator_scope ON member_hourly_prices
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
-- rdb 0176's member_scope, the unset test spelled as 0169's channel_scope
DROP POLICY IF EXISTS member_scope ON member_hourly_prices;
CREATE POLICY member_scope ON member_hourly_prices AS RESTRICTIVE
    USING (CASE WHEN NULLIF(current_setting('app.member_id', true), '') IS NULL THEN 1 END IS NOT NULL
           OR member_id = current_setting('app.member_id', true))
    WITH CHECK (CASE WHEN NULLIF(current_setting('app.member_id', true), '') IS NULL THEN 1 END IS NOT NULL
           OR member_id = current_setting('app.member_id', true));

ALTER TABLE commit_human_time ENABLE ROW LEVEL SECURITY;
ALTER TABLE commit_human_time FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS commit_human_time_tenant_read ON commit_human_time;
CREATE POLICY commit_human_time_tenant_read ON commit_human_time
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON commit_human_time;
CREATE POLICY operator_scope ON commit_human_time
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
