-- 0213_box_locks.sql — the box owner lock's data (spec 025 box-owner-lock.md
-- section 6.1, row B1, SPL-2952; owner HUM-10, workspace owner topic e41cba27).
-- Forward-only, additive, idempotent.
--
--   box_locks       one row per locked (workspace, box): its owners (HUM-*),
--                   the K_lock public key, the K_box it accepts, peer boxes,
--                   hide_posts, a version, and signed_body + signature: the
--                   canonical JSON of the columns before it, signed by K_lock.
--                   The hub re-verifies the signature, and that signed_body
--                   equals the row, on every cache load
--                   (store/box_locks.go VerifyBoxLock): a row edited without
--                   K_lock loads as tampered = locked to nobody.
--   box_lock_audit  every refusal (bumped per box, human or from_box, path
--                   and minute), create, change, lift, sealed hello and
--                   tamper finding.
--
-- RLS: FORCE, the fail-closed tenant policy of 0021 (NULLIF), FOR ALL: the
-- lock routes (row B2) write in the workspace's own scope after the K_lock
-- signature check. The operator scope is there only for the break-glass
-- (section 8.3, row B6); no other code path uses it on these tables.
--
-- DEPLOY ORDER: apply this file BEFORE the hub that bundles it. The store
-- probes the catalogue for box_locks (store/box_locks_postgres.go), so a hub
-- on a database without it reads every box as unlocked, as before.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS box_locks (
    tenant_id    text        NOT NULL,
    box_id       text        NOT NULL,
    lock_pubkey  text        NOT NULL,
    box_pubkey   text        NOT NULL,
    owners       text[]      NOT NULL,
    peer_boxes   text[]      NOT NULL DEFAULT '{}',
    hide_posts   boolean     NOT NULL DEFAULT true,
    version      bigint      NOT NULL,
    signed_body  text        NOT NULL,
    signature    text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_box_locks PRIMARY KEY (tenant_id, box_id),
    CONSTRAINT fk_box_locks_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_box_locks_owners CHECK (cardinality(owners) >= 1),
    CONSTRAINT chk_box_locks_version CHECK (version >= 1)
);
-- No index on tenant_id: it leads the primary key.

CREATE TABLE IF NOT EXISTS box_lock_audit (
    audit_id   bigint      GENERATED ALWAYS AS IDENTITY,
    tenant_id  text        NOT NULL,
    box_id     text        NOT NULL,
    human_id   text        NULL,
    from_box   text        NULL,
    path       text        NOT NULL,
    verdict    text        NOT NULL,
    first_at   timestamptz NOT NULL,
    last_at    timestamptz NOT NULL,
    count      integer     NOT NULL DEFAULT 1,
    CONSTRAINT pk_box_lock_audit PRIMARY KEY (audit_id),
    CONSTRAINT fk_box_lock_audit_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_box_lock_audit_verdict
        CHECK (verdict IN ('refused', 'created', 'changed', 'lifted', 'sealed_hello', 'tampered')),
    CONSTRAINT chk_box_lock_audit_count CHECK (count >= 1)
);
-- The per-minute bump and the owner's read (GET /v1/boxes/{box}/lock) both
-- look up one box's newest rows.
CREATE INDEX IF NOT EXISTS ix_box_lock_audit_box_last
    ON box_lock_audit (tenant_id, box_id, last_at DESC);

-- RLS, fail-closed (NULLIF): the workspace reads and writes its own rows;
-- the operator scope is the break-glass only.
ALTER TABLE box_locks ENABLE ROW LEVEL SECURITY;
ALTER TABLE box_locks FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON box_locks;
CREATE POLICY tenant_scope ON box_locks
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON box_locks;
CREATE POLICY operator_scope ON box_locks
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE box_lock_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE box_lock_audit FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON box_lock_audit;
CREATE POLICY tenant_scope ON box_lock_audit
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON box_lock_audit;
CREATE POLICY operator_scope ON box_lock_audit
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
