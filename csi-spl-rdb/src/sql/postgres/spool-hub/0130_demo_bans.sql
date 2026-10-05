-- 0130_demo_bans.sql - the demo workspace's ban list (spec 077 3.6 "ban",
-- T016 part B). Forward-only, idempotent.
--
-- A moderator (members.invite: admin, biz_owner; never demo_user) removing a
-- demo_user from the demo workspace bans it: the membership goes, and every
-- identity of that human leaves its digests here, in the same transaction:
--
--   demo_bans  one row per (tenant, key): key is "acct:" sha256 of
--              (provider, subject), or "mail:" sha256 of the lowercased
--              address the IdP asserted; never the raw account or address.
--
-- The open demo admission refuses an identity whose account or address
-- digest is listed, before the live cap and the T010 counters, and writes
-- nothing. A digest, not a human id: the expiry sweep drops the visitor's
-- human (and its identities) at the end of a stay, so the ban must outlive
-- both. The nightly wipe (do_spl_demo_wipe) leaves this table alone. The rows
-- go with the tenant (ON DELETE CASCADE); the runtime grants come from the
-- default privileges of spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: before the hub that reads this table.

CREATE TABLE IF NOT EXISTS demo_bans (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    key       text        NOT NULL CHECK (key ~ '^(acct|mail):[0-9a-f]{64}$'),
    banned_by text        NOT NULL CHECK (length(banned_by) BETWEEN 1 AND 200),
    banned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, key)
);

-- RLS in the 0021 fail-closed NULLIF shape, like quota_counts.
ALTER TABLE demo_bans ENABLE ROW LEVEL SECURITY;
ALTER TABLE demo_bans FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON demo_bans;
CREATE POLICY tenant_scope ON demo_bans
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON demo_bans;
CREATE POLICY operator_scope ON demo_bans
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
