-- share-grant.sql - spec 114 section 4: the PROPOSED share grant for model
-- (a), v0.2 (the review panel folded in, section 7). Bench input only,
-- applied on top of rdb 0157 in a throwaway postgres:16-alpine by
-- isolation-bench.sh. It is NOT a migration: the migration is written at
-- build time (tasks T002) from this file.
--
-- One row = one workspace (tenant_id) offering one other workspace
-- (to_tenant) read or edit access to one document. Never inserted by
-- default, and it opens nothing until the RECEIVING workspace accepts it
-- (accepted_at, c-714 #4). A grant is never deleted or edited: the receiver
-- stamps accepted_at once, the owner stamps revoked_at once, a role change is
-- revoke + a new grant, so the table is its own audit trail.

CREATE TABLE workspace_doc_share (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   text        NOT NULL,
    doc_id      uuid        NOT NULL,
    to_tenant   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    access      text        NOT NULL CHECK (access IN ('read', 'edit')),
    granted_by  text        NOT NULL CHECK (length(granted_by) BETWEEN 1 AND 200),
    granted_at  timestamptz NOT NULL DEFAULT now(),
    accepted_by text        NULL CHECK (length(accepted_by) BETWEEN 1 AND 200),
    accepted_at timestamptz NULL,
    revoked_by  text        NULL CHECK (length(revoked_by) BETWEEN 1 AND 200),
    revoked_at  timestamptz NULL,
    CONSTRAINT workspace_doc_share_not_self CHECK (to_tenant <> tenant_id),
    CONSTRAINT workspace_doc_share_accept_pair CHECK ((accepted_at IS NULL) = (accepted_by IS NULL)),
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

-- Two stamps, each once, each by its own side: the receiving workspace may
-- only stamp accepted_*, every other session (the owner, the operator) may
-- only stamp revoked_*. Nothing else on the row ever changes.
CREATE FUNCTION workspace_doc_share_revoke_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.id, NEW.tenant_id, NEW.doc_id, NEW.to_tenant, NEW.access, NEW.granted_by, NEW.granted_at)
       IS DISTINCT FROM
       (OLD.id, OLD.tenant_id, OLD.doc_id, OLD.to_tenant, OLD.access, OLD.granted_by, OLD.granted_at) THEN
        RAISE EXCEPTION 'workspace_doc_share_revoke_only: grant % may only be accepted or revoked, once', OLD.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_share_revoke_only';
    END IF;
    IF OLD.to_tenant = NULLIF(current_setting('app.tenant_id', true), '') THEN
        IF OLD.accepted_at IS NOT NULL OR OLD.revoked_at IS NOT NULL OR NEW.accepted_at IS NULL
           OR (NEW.revoked_at, NEW.revoked_by) IS DISTINCT FROM (OLD.revoked_at, OLD.revoked_by) THEN
            RAISE EXCEPTION 'workspace_doc_share_revoke_only: grant % may only be accepted by its receiver, once', OLD.id
                USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_share_revoke_only';
        END IF;
    ELSIF OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL
          OR (NEW.accepted_at, NEW.accepted_by) IS DISTINCT FROM (OLD.accepted_at, OLD.accepted_by) THEN
        RAISE EXCEPTION 'workspace_doc_share_revoke_only: grant % may only be revoked, once', OLD.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_share_revoke_only';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER workspace_doc_share_revoke_only
    BEFORE UPDATE ON workspace_doc_share
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_share_revoke_only();

-- The grant row: both workspaces see it, only the owning one creates it, the
-- receiving one may accept it (the trigger above limits that to one stamp).
ALTER TABLE workspace_doc_share ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_share FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc_share
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY share_seen_by_receiver ON workspace_doc_share FOR SELECT
    USING (to_tenant = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY share_accept ON workspace_doc_share FOR UPDATE
    USING (to_tenant = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (to_tenant = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_doc_share
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- The documents: 0157's tenant_scope and operator_scope stay as they are.
-- These policies are ADDED (permissive, so OR-ed). The doc ids come from an
-- ARRAY(..) sub-select: an InitPlan computed once per statement, so the
-- planner can still use an index on doc_id / id (bench M4). Only an ACCEPTED,
-- live grant opens anything.
CREATE POLICY share_read ON workspace_doc FOR SELECT
    USING (id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)));
CREATE POLICY share_read ON workspace_doc_item FOR SELECT
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)));
-- The rev log only from the grant on (c-714 #7): who worked on the document
-- before it was shared is not disclosed.
CREATE POLICY share_read ON workspace_doc_rev_log FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM workspace_doc_share s
         WHERE s.doc_id = workspace_doc_rev_log.doc_id
           AND s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL
           AND workspace_doc_rev_log.created_at >= s.granted_at));

-- Edit: the receiver writes rows that keep the OWNER's tenant_id. The doc
-- row needs UPDATE (rev bump, and the FOR UPDATE lock every op and the 0157
-- tree trigger take); items need INSERT/UPDATE/DELETE; the rev log INSERT.
CREATE POLICY share_edit ON workspace_doc FOR UPDATE
    USING (id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)))
    WITH CHECK (id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)));
CREATE POLICY share_edit ON workspace_doc_item
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)))
    WITH CHECK (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)));
-- The receiver writes rev-log entries only under its own actor
-- (<member>@<receiver>, c-714 #2); right() rather than LIKE, so a workspace id
-- holding % or _ matches literally.
CREATE POLICY share_edit ON workspace_doc_rev_log FOR INSERT
    WITH CHECK (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL))
        AND right(actor, length(NULLIF(current_setting('app.tenant_id', true), '')) + 1)
            = '@' || NULLIF(current_setting('app.tenant_id', true), ''));

-- RLS cannot restrict columns, so this trigger is the column boundary for an
-- edit receiver (c-714 #1). For everyone: id, tenant_id, created_by and
-- created_at never change (the hub's only UPDATE of workspace_doc is the
-- bump, workspace_docs.go line 192). For a receiver (a tenant scope other
-- than the row's): rev moves by exactly +1, so title and updated_at are all
-- else it can touch, and it cannot jump rev to pre-claim rev-log slots.
CREATE FUNCTION workspace_doc_share_edit_cols() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.id, NEW.tenant_id, NEW.created_by, NEW.created_at)
       IS DISTINCT FROM (OLD.id, OLD.tenant_id, OLD.created_by, OLD.created_at) THEN
        RAISE EXCEPTION 'workspace_doc_share_edit_cols: doc % id, tenant_id, created_by, created_at never change', OLD.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_share_edit_cols';
    END IF;
    IF current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator'
       AND OLD.tenant_id IS DISTINCT FROM NULLIF(current_setting('app.tenant_id', true), '')
       AND NEW.rev <> OLD.rev + 1 THEN
        RAISE EXCEPTION 'workspace_doc_share_edit_cols: a receiver moves doc % rev by +1 only (% -> %)', OLD.id, OLD.rev, NEW.rev
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_share_edit_cols';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER workspace_doc_share_edit_cols
    BEFORE UPDATE ON workspace_doc
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_share_edit_cols();

-- A rev-log entry only for a rev the document has reached, checked at commit
-- (c-714 #2, its fix.sql). With the +1 rule above nobody can pre-fill a
-- future slot and freeze the owner's next bump. Deferred, because inside the
-- hub's bump CTE (workspace_docs.go lines 191-194) the INSERT's own checks see
-- the pre-UPDATE snapshot; at commit the doc row shows the new rev.
CREATE FUNCTION workspace_doc_rev_log_reached() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM workspace_doc WHERE id = NEW.doc_id AND rev >= NEW.rev;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'workspace_doc_rev_log_reached: rev % of doc % not reached', NEW.rev, NEW.doc_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_rev_log_reached';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER workspace_doc_rev_log_reached
    AFTER INSERT ON workspace_doc_rev_log
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_rev_log_reached();

-- One RESTRICTIVE fence per table (c-714 #5): every permissive policy, today's
-- or a later one, is AND-ed with "a scope is set". The exact policy set is
-- pinned by P12 (share-proof.sql), so a new policy fails that pin until it is
-- changed in the same commit.
CREATE POLICY scope_fence ON workspace_doc AS RESTRICTIVE
    USING (current_setting('app.rls_scope', true) = 'operator'
           OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL);
CREATE POLICY scope_fence ON workspace_doc_item AS RESTRICTIVE
    USING (current_setting('app.rls_scope', true) = 'operator'
           OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL);
CREATE POLICY scope_fence ON workspace_doc_rev_log AS RESTRICTIVE
    USING (current_setting('app.rls_scope', true) = 'operator'
           OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL);
CREATE POLICY scope_fence ON workspace_doc_share AS RESTRICTIVE
    USING (current_setting('app.rls_scope', true) = 'operator'
           OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL);
