-- 0174_workspace_vendor_keys.sql - a workspace's own vendor keys (spec 127
-- v1.1 sections 4.2, 5.1, 7.2; lane D1). Forward-only, additive.
--
-- 1. workspace_vendor_keys: one key per (workspace, kind), the five kinds of
--    section 3. The hub seals the key before the INSERT (AES-256-GCM under a
--    fresh per-row DEK, additional data tenant_id|kind|key_id), so the row,
--    a statement log and a backup carry ciphertext only; wrapped_dek is that
--    DEK wrapped by Cloud KMS (kms_key_version names the KMS key version).
--    key_id is a random UUID, new on every set or replace (the hub's, no
--    default: a replace by UPDATE must not keep the old one). fingerprint is
--    the hex HMAC-SHA256 of the key under the hub's pepper, never a bare
--    hash. base_url is qwen's alone (https only).
--    RLS: tenant_scope ONLY, no operator_scope policy: the operator scope
--    reads 0 rows (the personal.profile shape of rdb 0168). Store
--    TestRLSVendorKeysCatalogue pins "policies are exactly tenant_scope", so
--    a later operator_scope policy turns it red.
-- 2. workspace_vendor_key_boxes: the boxes a workspace admin approved for
--    keys (5.1). No secret: tenant_scope + operator_scope.
-- 3. workspace_vendor_key_audit: every set, replace, remove, lease, box
--    approve / revoke and admin confirm. last4 at most, never the key.
--    Append-only in the 0171 shape: an UPDATE is refused always, a DELETE
--    always except the cascade of a tenant delete (pg_trigger_depth() > 1).
--    tenant_scope + operator_scope: an operator may see that a key was set,
--    never the key.
-- 4. usage_events.key_source (7.2): 'hub' | 'workspace'. Expand, then
--    contract (dispatch-bdc65df6 msg 7da7b68a): the running hub inserts
--    without the column, so it lands here WITH DEFAULT 'hub'; the hub then
--    names it on every insert, and a later migration drops the default once
--    that hub is live on dev and prd, reaching the spec's C12 state (NOT
--    NULL, no default). A constant default is catalogue-only (PG 11+): no
--    row is rewritten and the append-only trigger never fires; every row
--    already written is a hub-paid turn, so it reads 'hub'.
--
-- A tenant delete cascades all three tables (FK ON DELETE CASCADE; the RI
-- action passes the audit trigger at depth 2). Store tests:
-- vendor_keys_rls_test.go, crosstenant_test.go (seedVendorKeys),
-- rls_failclosed_test.go (from the catalogue). Runtime grants: the default
-- privileges of spool-hub-roles/runtime-grants.sql.
--
-- Live-data safety: three new empty tables; the FKs take a SHARE ROW
-- EXCLUSIVE lock on tenants and the new column an ACCESS EXCLUSIVE lock on
-- usage_events (the CHECK scans it once, no rewrite) until COMMIT, hence
-- lock_timeout. No running hub reads the new tables (spec 127 H1, H2 do,
-- later). DEPLOY ORDER: wf 20 applies this before the image that reads it.
-- Runs under the operator RLS scope (spool migrate, rdb 0014). No personal
-- data, no secret: the tables start empty.

SET LOCAL lock_timeout = '5s';

CREATE TABLE workspace_vendor_keys (
    tenant_id       text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    kind            text        NOT NULL CHECK (kind IN ('claude', 'grok', 'agy', 'mistral', 'qwen')),
    key_id          uuid        NOT NULL UNIQUE,
    ciphertext      bytea       NOT NULL CHECK (octet_length(ciphertext) BETWEEN 1 AND 8192),
    wrapped_dek     bytea       NOT NULL CHECK (octet_length(wrapped_dek) BETWEEN 1 AND 1024),
    kms_key_version text        NOT NULL CHECK (length(kms_key_version) BETWEEN 1 AND 512),
    last4           text        NOT NULL CHECK (length(last4) BETWEEN 1 AND 4),
    fingerprint     text        NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
    base_url        text        NULL CHECK (base_url ~ '^https://[^[:space:]]+$' AND length(base_url) <= 2048),
    set_by          text        NOT NULL CHECK (length(set_by) BETWEEN 1 AND 200),
    set_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, kind),
    CONSTRAINT workspace_vendor_keys_base_url_qwen_check CHECK (base_url IS NULL OR kind = 'qwen')
);

CREATE TABLE workspace_vendor_key_boxes (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    box_id      text        NOT NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    approved_by text        NOT NULL CHECK (length(approved_by) BETWEEN 1 AND 200),
    approved_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, box_id)
);

CREATE TABLE workspace_vendor_key_audit (
    id        bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    kind      text        NULL CHECK (kind IN ('claude', 'grok', 'agy', 'mistral', 'qwen')),
    action    text        NOT NULL CHECK (action IN ('set', 'replace', 'remove', 'lease', 'box_approve', 'box_revoke', 'admin_confirm')),
    actor     text        NOT NULL CHECK (length(actor) BETWEEN 1 AND 200),
    at        timestamptz NOT NULL DEFAULT now(),
    last4     text        NULL CHECK (length(last4) BETWEEN 1 AND 4),
    box_id    text        NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    -- A key action names its kind; a lease and a box action name the box.
    CONSTRAINT workspace_vendor_key_audit_key_kind_check CHECK (
        action NOT IN ('set', 'replace', 'remove', 'lease') OR kind IS NOT NULL),
    CONSTRAINT workspace_vendor_key_audit_box_named_check CHECK (
        action NOT IN ('lease', 'box_approve', 'box_revoke') OR box_id IS NOT NULL)
);
CREATE INDEX workspace_vendor_key_audit_tenant_at ON workspace_vendor_key_audit (tenant_id, at);

-- 4.2: the key table, tenant_scope ONLY.
ALTER TABLE workspace_vendor_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_vendor_keys FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_vendor_keys
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['workspace_vendor_key_boxes', 'workspace_vendor_key_audit'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;

-- Append-only audit: no UPDATE ever; a DELETE only as a tenant delete's cascade.
CREATE FUNCTION workspace_vendor_key_audit_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'workspace_vendor_key_audit is append-only: % refused (only a tenant delete removes rows)', TG_OP;
END $$;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON workspace_vendor_key_audit
    FOR EACH ROW EXECUTE FUNCTION workspace_vendor_key_audit_append_only();

-- 7.2, the expand step of 4. above.
ALTER TABLE usage_events ADD COLUMN key_source text NOT NULL DEFAULT 'hub'
    CONSTRAINT usage_events_key_source_check CHECK (key_source IN ('hub', 'workspace'));
