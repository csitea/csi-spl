-- 0203_sql_query_audit.sql - every query a workspace admin ran, or tried to
-- run, in the Reporting SQL tab (spec 143 section 3.5, task T002, SPL-2347).
-- Forward-only.
--
-- One row per attempt, refused ones included (error_message says why).
-- Tenant-scoped, fail closed: the 0021 NULLIF shape, so a statement with no
-- workspace set reads 0 rows and writes none, and one workspace never reads
-- another's audit. The operator scope reads and writes all of it.
--
-- Spec 3.5 drafts a tenant policy FOR SELECT only. The catalogue gate
-- (store/rls_failclosed_test.go) asks every tenant table for a policy that
-- lets a workspace write its own row, so tenant_scope is FOR ALL and the
-- table is append-only instead, in the 0174 audit shape: an UPDATE is
-- refused always, a DELETE always except the cascade of a tenant delete
-- (pg_trigger_depth() > 1). A workspace may add its audit rows; nobody
-- edits or removes one.
--
-- query_text and client_ip are the admin's own input and address, kept for
-- the workspace's audit only.
--
-- Live-data safety: one new empty table; the FK takes a SHARE ROW EXCLUSIVE
-- lock on tenants until COMMIT. No running hub reads it yet (spec 143 T03x).

CREATE TABLE sql_query_audit (
    audit_id      text        PRIMARY KEY CHECK (audit_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    human_id      text        NOT NULL CHECK (length(human_id) BETWEEN 1 AND 200),
    query_text    text        NOT NULL CHECK (length(query_text) <= 100000),
    executed_at   timestamptz NOT NULL DEFAULT now(),
    duration_ms   integer     NOT NULL CHECK (duration_ms >= 0),
    row_count     integer     NOT NULL DEFAULT 0 CHECK (row_count >= 0),
    truncated     boolean     NOT NULL DEFAULT false,
    error_message text        NOT NULL DEFAULT '' CHECK (length(error_message) <= 2000),
    client_ip     text        NOT NULL DEFAULT '' CHECK (length(client_ip) <= 64)
);

CREATE INDEX sql_query_audit_tenant_time ON sql_query_audit (tenant_id, executed_at DESC);

ALTER TABLE sql_query_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE sql_query_audit FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_scope ON sql_query_audit
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));

CREATE POLICY operator_scope ON sql_query_audit
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- Append-only audit: no UPDATE ever; a DELETE only as a tenant delete's cascade.
CREATE FUNCTION sql_query_audit_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'sql_query_audit is append-only: % refused (only a tenant delete removes rows)', TG_OP;
END $$;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON sql_query_audit
    FOR EACH ROW EXECUTE FUNCTION sql_query_audit_append_only();
