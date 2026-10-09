# Spec 114: Workspace document privacy and sharing (never default)

## 3. Sharing mechanics (never default)

### 3.1 Share-grant table

\[sql\]
CREATE TABLE workspace_doc_share (
    share_id     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    doc_id       uuid        NOT NULL,
    from_tenant  text        NOT NULL,
    to_tenant    text        NOT NULL,
    to_member    text        NULL,
    role         text        NOT NULL CHECK (role IN (\"read\", \"edit\")),
    granted_by   text        NOT NULL,
    granted_at   timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz NULL,
    CONSTRAINT workspace_doc_share_doc_fk FOREIGN KEY (from_tenant, doc_id)
        REFERENCES workspace_doc (tenant_id, id) ON DELETE CASCADE
);

ALTER TABLE workspace_doc_share ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_share FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc_share
    USING (from_tenant = NULLIF(current_setting(\pp.tenant_id\\, true), \\\))
    WITH CHECK (from_tenant = NULLIF(current_setting(\pp.tenant_id\\, true), \\\));
CREATE POLICY operator_scope ON workspace_doc_share
    USING (current_setting(\pp.rls_scope\\, true) = \\operator\\);
\[/sql\]


### 3.2 Audit trail

\[sql\]
CREATE TABLE workspace_doc_share_audit (
    audit_id     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    share_id     uuid        NOT NULL,
    op           text        NOT NULL CHECK (op IN (\"grant\", \"revoke\")),
    actor        text        NOT NULL,
    at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_share_audit_share_fk FOREIGN KEY (share_id)
        REFERENCES workspace_doc_share (share_id) ON DELETE CASCADE
);

ALTER TABLE workspace_doc_share_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_share_audit FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc_share_audit
    USING (current_setting(\pp.rls_scope\\, true) = \\operator\\ OR EXISTS (
        SELECT 1 FROM workspace_doc_share s
        WHERE s.share_id = workspace_doc_share_audit.share_id
        AND s.from_tenant = NULLIF(current_setting(\pp.tenant_id\\, true), \\\)));
\[/sql\]


### 3.3 RLS policies for sharing

\[sql\]
-- Read access: owner or recipient (workspace or member)
CREATE POLICY doc_read_share ON workspace_doc
    USING (
        tenant_id = NULLIF(current_setting(\pp.tenant_id\\, true), \\\) OR
        EXISTS (
            SELECT 1 FROM workspace_doc_share s
            WHERE s.doc_id = workspace_doc.id
            AND s.from_tenant = workspace_doc.tenant_id
            AND s.revoked_at IS NULL
            AND (
                s.to_tenant = NULLIF(current_setting(\pp.tenant_id\\, true), \\\) OR
                s.to_member = current_setting(\pp.member_id\\, true)
            )
        )
    );

-- Write access: owner only (edit role allows write)
CREATE POLICY doc_write_share ON workspace_doc
    USING (
        tenant_id = NULLIF(current_setting(\pp.tenant_id\\, true), \\\) OR
        EXISTS (
            SELECT 1 FROM workspace_doc_share s
            WHERE s.doc_id = workspace_doc.id
            AND s.from_tenant = workspace_doc.tenant_id
            AND s.revoked_at IS NULL
            AND s.role = \"edit\"
            AND (
                s.to_tenant = NULLIF(current_setting(\pp.tenant_id\\, true), \\\) OR
                s.to_member = current_setting(\pp.member_id\\, true)
            )
        )
    );
\[/sql\]


### 3.4 Receiving side

- Shared docs appear in a "Shared with me" view (WUI/API).
- Read-only unless `role=edit`.
- Revocation: set `revoked_at`; RLS excludes revoked shares.

## 4. Recommendation

**Model (a): Shared tables + tenant_id + FORCE RLS**.

### Why
- **Lowest cost**: 1 DB for 100 workspaces.
- **Simplest ops**: No per-workspace migrations, backups, or schema management.
- **Proven**: Live in spec 113; RLS enforces isolation.
- **Sharing**: Share-grant table + RLS policies; audit trail.
- **Search**: Full index; RLS-scoped queries.

### Changes to spec 113
- Add `workspace_doc_share` and `workspace_doc_share_audit` tables.
- Add RLS policies for sharing (section 3.3).
- No changes to `workspace_doc`, `workspace_doc_item`, or `workspace_doc_rev_log`.

## 5. Owner questions

1. **Isolation model**:
   - (a) Shared tables + RLS (recommended).
   - (b) Schema per workspace.
   - (c) Database per workspace.
   - (d) Hybrid: Shared tables + encryption.

2. **Sharing scope**:
   - (a) Share with another workspace (tenant_id).
   - (b) Share with a named member (human_id).

3. **Audit trail**:
   - (a) Append-only log (recommended).
   - (b) Full event sourcing.

4. **Migration path**:
   - (a) No migration (add share-grant table and RLS policies, recommended).
   - (b) Migrate to schema-per-workspace.
