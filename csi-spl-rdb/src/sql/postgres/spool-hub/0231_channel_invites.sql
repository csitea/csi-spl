-- 0231_channel_invites.sql — a pending channel membership for a person who
-- has not joined the workspace yet (spec 025 section 11, SPL-3686; owner
-- HUM-10, t1 b602f8b4 msg 4a3ec33a: "it should be possible to add persons to
-- channels even if they have not yet joined"). Forward-only, additive,
-- idempotent.
--
--   channel_invites  one row per (workspace, channel, invited address). The
--                    channel owner (the channel_humans add rule) put the
--                    address of an open workspace invite (tenant_invites) in
--                    the channel. The row grants nothing: the read door reads
--                    channel_humans only. When the invite is accepted
--                    (store acceptInviteTx / ProvisionMember) the row moves
--                    to channel_humans for the new member and is deleted.
--
-- The invite FK cascades: a revoked invite (DELETE FROM tenant_invites)
-- takes its pending channel rows with it, and a deleted channel takes its
-- own. An expired invite keeps its rows inert (they are neither listed nor
-- moved, both read expires_at), and a re-invite of a lapsed or accepted
-- address clears them first (store PutInvite), so a typo never leaves a
-- membership nothing cleans up.
--
-- RLS: FORCE, the fail-closed tenant policy of 0021 (NULLIF), FOR ALL; the
-- operator scope is the break-glass only.
--
-- DEPLOY ORDER: wf 20 applies this file on each database before it rolls
-- the hub that bundles it; the admission path writes it without a probe.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS channel_invites (
    tenant_id  text        NOT NULL,
    channel_id text        NOT NULL,
    email      text        NOT NULL,
    added_by   text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_channel_invites PRIMARY KEY (tenant_id, channel_id, email),
    CONSTRAINT fk_channel_invites_channel FOREIGN KEY (tenant_id, channel_id)
        REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE,
    CONSTRAINT fk_channel_invites_invite FOREIGN KEY (tenant_id, email)
        REFERENCES tenant_invites (tenant_id, email) ON DELETE CASCADE
);
-- Acceptance and revoke look the rows up by address.
CREATE INDEX IF NOT EXISTS ix_channel_invites_email
    ON channel_invites (tenant_id, email);

ALTER TABLE channel_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_invites FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON channel_invites;
CREATE POLICY tenant_scope ON channel_invites
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON channel_invites;
CREATE POLICY operator_scope ON channel_invites
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
