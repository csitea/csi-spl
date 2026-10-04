-- 0119_agent_join_tokens.sql - agent join tokens (specs/073 T002). Forward-only,
-- additive.
--
-- Owner decisions on t1 e3310f01, msg b30cc1ef (spec 073 section 8): a tenant
-- admin mints a one-use, short-lived token in the WUI; `spool join` redeems it
-- and seats one box key, so a box joins with no tenant root key on it.
--
-- This file adds three things:
--   1. agent_join_tokens - one row per minted token. Only sha256(secret) hex
--      is stored (as password_reset_tokens, rdb 0009); the plain token is in
--      the mint response only. box_id NULL = unbound (the redeemer names it).
--      for_human: the member the token is for (Q3); membership end revokes the
--      token and the seat it created. NULL: membership end does not touch it.
--      consumed_box: the box the redeem seated. Rows past expires_at + 7 days
--      are pruned by the join-token sweeper (spec 4.8).
--   2. pins_history.reason += 'join' (seated by a token), 'wui-revoke' (seat
--      revoked from Tenant settings -> Agents) and 'membership-end' (seat
--      revoked because its for_human left the tenant).
--   3. agents.join - mint, list and revoke join tokens and revoke one seat from
--      the WUI, granted to admin ONLY (spec 4.7, Q1): the one permission
--      biz_owner does not hold. The rows MUST equal internal/rbac Defaults +
--      Permissions (store TestRBACSeedMatchesDefaults). Runs under the
--      operator RLS scope (spool migrate, rdb 0014).
--
-- No personal data: a HUM id, a box id, a label and a hash. No secret: the
-- hash of a one-use secret that is dead within its TTL (cnf, max 24h).
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

CREATE TABLE agent_join_tokens (
    token_hash   text        PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    created_by   text        NOT NULL,
    for_human    text        NULL CHECK (for_human IS NULL OR for_human ~ '^HUM-[0-9]+$'),
    label        text        NOT NULL DEFAULT '' CHECK (length(label) <= 80),
    box_id       text        NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    consumed_at  timestamptz NULL,
    consumed_box text        NULL,
    revoked_at   timestamptz NULL
);
CREATE INDEX agent_join_tokens_tenant  ON agent_join_tokens (tenant_id, created_at);
CREATE INDEX agent_join_tokens_human   ON agent_join_tokens (tenant_id, for_human) WHERE for_human IS NOT NULL;
CREATE INDEX agent_join_tokens_expires ON agent_join_tokens (expires_at);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF: a pooled
-- connection reads the GUC as '' after any transaction-local set_config, never
-- NULL; CLE-3416). A tenant reads and writes only its own rows; the operator
-- scope (the sweeper, spool migrate) sees everything.
ALTER TABLE agent_join_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_join_tokens FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON agent_join_tokens
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON agent_join_tokens
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE pins_history DROP CONSTRAINT pins_history_reason_check;
ALTER TABLE pins_history ADD CONSTRAINT pins_history_reason_check
    CHECK (reason IN ('pin', 'force', 'revoke', 'join', 'wui-revoke', 'membership-end'));

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('agents.join', 'mint, list and revoke agent join tokens, and revoke one seat from the WUI');

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('admin', 'agents.join');
