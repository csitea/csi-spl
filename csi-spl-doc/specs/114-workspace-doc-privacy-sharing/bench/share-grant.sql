-- share-grant.sql - spec 114 section 4: the PROPOSED share grant for model
-- (a). Bench input only, applied on top of rdb 0157 in a throwaway
-- postgres:16-alpine by isolation-bench.sh. It is NOT a migration: the
-- migration is written at build time (tasks T002) from this file.
--
-- One row = one workspace (tenant_id) letting one other workspace
-- (to_tenant) read or edit one document. Never inserted by default. A grant
-- is never deleted or edited: revoke stamps revoked_at once, a role change is
-- revoke + a new grant, so the table is its own audit trail.

CREATE TABLE workspace_doc_share (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   text        NOT NULL,
    doc_id      uuid        NOT NULL,
    to_tenant   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    access      text        NOT NULL CHECK (access IN ('read', 'edit')),
    granted_by  text        NOT NULL CHECK (length(granted_by) BETWEEN 1 AND 200),
    granted_at  timestamptz NOT NULL DEFAULT now(),
    revoked_by  text        NULL CHECK (length(revoked_by) BETWEEN 1 AND 200),
    revoked_at  timestamptz NULL,
    CONSTRAINT workspace_doc_share_not_self CHECK (to_tenant <> tenant_id),
    CONSTRAINT workspace_doc_share_revoke_pair CHECK ((revoked_at IS NULL) = (revoked_by IS NULL)),
    -- FK checks bypass RLS (spec 113 seat 5#2): carrying tenant_id makes a
    -- grant on another workspace's doc_id an FK violation.
    CONSTRAINT workspace_doc_share_doc_fk FOREIGN KEY (tenant_id, doc_id)
        REFERENCES workspace_doc (tenant_id, id) ON DELETE CASCADE
);
-- at most one live grant per (doc, receiving workspace)
CREATE UNIQUE INDEX workspace_doc_share_live ON workspace_doc_share (doc_id, to_tenant) WHERE revoked_at IS NULL;
-- the receiving side's lookup, used by every share policy below
CREATE INDEX workspace_doc_share_to ON workspace_doc_share (to_tenant, doc_id) WHERE revoked_at IS NULL;

-- Only a revoke may change a row, and only once.
CREATE FUNCTION workspace_doc_share_revoke_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.revoked_at IS NOT NULL
       OR NEW.revoked_at IS NULL
       OR (NEW.id, NEW.tenant_id, NEW.doc_id, NEW.to_tenant, NEW.access, NEW.granted_by, NEW.granted_at)
          IS DISTINCT FROM
          (OLD.id, OLD.tenant_id, OLD.doc_id, OLD.to_tenant, OLD.access, OLD.granted_by, OLD.granted_at) THEN
        RAISE EXCEPTION 'workspace_doc_share_revoke_only: grant % may only be revoked, once', OLD.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_share_revoke_only';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER workspace_doc_share_revoke_only
    BEFORE UPDATE ON workspace_doc_share
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_share_revoke_only();

-- The grant row: both workspaces see it, only the owning one writes it.
ALTER TABLE workspace_doc_share ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_share FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc_share
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY share_seen_by_receiver ON workspace_doc_share FOR SELECT
    USING (to_tenant = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_doc_share
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- The documents: 0157's tenant_scope and operator_scope stay as they are.
-- These policies are ADDED (permissive, so OR-ed). The doc ids come from an
-- ARRAY(..) sub-select: an InitPlan computed once per statement, so the
-- planner can still use an index on doc_id / id (bench M4).
CREATE POLICY share_read ON workspace_doc FOR SELECT
    USING (id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.revoked_at IS NULL)));
CREATE POLICY share_read ON workspace_doc_item FOR SELECT
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.revoked_at IS NULL)));
CREATE POLICY share_read ON workspace_doc_rev_log FOR SELECT
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.revoked_at IS NULL)));

-- Edit: the receiver writes rows that keep the OWNER's tenant_id. The doc
-- row needs UPDATE (rev bump, and the FOR UPDATE lock every op and the 0157
-- tree trigger take); items need INSERT/UPDATE/DELETE; the rev log INSERT.
CREATE POLICY share_edit ON workspace_doc FOR UPDATE
    USING (id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.revoked_at IS NULL)))
    WITH CHECK (id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.revoked_at IS NULL)));
CREATE POLICY share_edit ON workspace_doc_item
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.revoked_at IS NULL)))
    WITH CHECK (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.revoked_at IS NULL)));
CREATE POLICY share_edit ON workspace_doc_rev_log FOR INSERT
    WITH CHECK (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.revoked_at IS NULL)));
