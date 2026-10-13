-- 0192_workspace_doc_acl.sql - Layer 2 of the doc permissions: capability
-- grants on a folder or document node, inherited down the nested set (spec
-- 137 T021, section 4.3.3; owner HUM-10 t1 bed3ed0a msg 0e9d17b5 "later on
-- complex permissions"). Forward-only, additive.
--
--   workspace_doc_acl    one grant: a subject may (allow) or may not (deny)
--                        take an action on a node and everything under it.
--                        subject is 'user:<id>', 'agent:<id>', 'role:<name>'
--                        or 'workspace:*'; action read, edit, manage, share.
--   workspace_doc_acl_effect(tenant, node, subjects, action)
--                        the rule of section 4.3.3 over the node and its
--                        ancestors (up.lft <= node.lft AND up.rgt >= node.rgt):
--                        a matching deny anywhere = 'deny'; else a matching
--                        allow = 'allow'; else NULL = no grant applies and
--                        the caller falls back to Layer 1, the workspace RBAC
--                        of spec 025 (docs.read / docs.write / docs.admin).
--                        SECURITY INVOKER: it reads under the caller's RLS.
--
-- The table starts empty, so every check is NULL and Layer 1 decides as
-- before: it is inert until a grant is inserted.
-- FK checks bypass RLS (0157), so the node FK carries the tenant; a node
-- delete drops its grants. workspace_doc_node_tenant_node is that FK's key.
-- DEPLOY ORDER: any. Nothing reads the table yet.

ALTER TABLE workspace_doc_node
    ADD CONSTRAINT workspace_doc_node_tenant_node UNIQUE (tenant_id, id);

CREATE TABLE workspace_doc_acl (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    node_id    uuid        NOT NULL,
    subject    text        NOT NULL CHECK (
        subject = 'workspace:*' OR subject ~ '^(user|agent|role):[A-Za-z0-9@._+-]{1,200}$'),
    action     text        NOT NULL CHECK (action IN ('read', 'edit', 'manage', 'share')),
    effect     text        NOT NULL DEFAULT 'allow' CHECK (effect IN ('allow', 'deny')),
    created_by text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 200),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT workspace_doc_acl_node_fk FOREIGN KEY (tenant_id, node_id)
        REFERENCES workspace_doc_node (tenant_id, id) ON DELETE CASCADE,
    -- One grant per (node, subject, action): an allow and a deny of the same
    -- grant cannot both stand. Its prefix is the node lookup.
    CONSTRAINT workspace_doc_acl_one UNIQUE (tenant_id, node_id, subject, action)
);

-- RLS in the 0157 shape, and the system tenant's grants readable like its
-- docs (0191).
ALTER TABLE workspace_doc_acl ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_acl FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc_acl
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_doc_acl
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
CREATE POLICY doc_acl_select_repo ON workspace_doc_acl
    FOR SELECT USING (tenant_id = 'system');

CREATE FUNCTION workspace_doc_acl_effect(p_tenant text, p_node uuid, p_subjects text[], p_action text)
    RETURNS text
    LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN bool_or(a.effect = 'deny') THEN 'deny'
                WHEN bool_or(a.effect = 'allow') THEN 'allow' END
      FROM workspace_doc_node n
      JOIN workspace_doc_node up
        ON up.tenant_id = n.tenant_id AND up.lft <= n.lft AND up.rgt >= n.rgt
      JOIN workspace_doc_acl a
        ON a.tenant_id = up.tenant_id AND a.node_id = up.id
     WHERE n.tenant_id = p_tenant AND n.id = p_node
       AND a.action = p_action AND a.subject = ANY (p_subjects)
$$;
