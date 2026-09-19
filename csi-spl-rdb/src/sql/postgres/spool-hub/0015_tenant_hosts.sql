-- 0015_tenant_hosts.sql — the per-tenant host queue (specs/022 FR-001..003,
-- owner 2026-09-19 "automate per tenant"). With no wildcard, every tenant
-- host <tenant>.<fqdn> is one Cloud Run domain mapping (iac 032) + one ghs
-- CNAME (025), applied by terraform. The hub never runs terraform: it only
-- records here that a tenant needs a host, and reads the status back for the
-- claim page. csi-spl-orc do_spl_tenant_host_reconcile (run by the scheduled
-- workflow 40_tenant-host-reconcile.yml) provisions the open rows and marks
-- them ready once the host answers with its own certificate.
--
--   pending  - the tenant exists, its host is not provisioned yet
--   ready    - mapping + record applied, cert provisioned, host probed
--   failed   - the last attempt failed (detail says why); retried
--   removing - the tenant row was deleted; the reconcile takes the host down
--   removed  - deprovisioned
--
-- No FK to tenants: the row must outlive a deleted tenant so the reconcile
-- can take its host down. Rows are queued by TRIGGERS on tenants, so every
-- creation path (the paid webhook, fake-pay, CreateTenant, `spool
-- hub-tenant` / do_spl_tenant_create) queues its host in the SAME transaction
-- as the tenant row, and no Go path can forget it. Existing tenants are
-- queued once, below: the reconcile adopts the ones terraform already serves
-- (a no-op apply plus a probe) and maps the rest.
-- Forward-only.

CREATE TABLE tenant_hosts (
    tenant_id    text        PRIMARY KEY
                             CHECK (tenant_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    status       text        NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'ready', 'failed', 'removing', 'removed')),
    detail       text        NOT NULL DEFAULT '',
    requested_at timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX tenant_hosts_open ON tenant_hosts (status)
    WHERE status IN ('pending', 'failed', 'removing');

-- The same row level security as every tenant table (0014).
ALTER TABLE tenant_hosts ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_hosts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON tenant_hosts
    USING (tenant_id = current_setting('app.tenant_id', true))
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY operator_scope ON tenant_hosts
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- A (re-)created tenant queues its host. A host that is pending or ready stays
-- as it is (a re-created slug keeps a mapping that never went away).
CREATE FUNCTION tenant_hosts_queue() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO tenant_hosts (tenant_id) VALUES (NEW.tenant_id)
    ON CONFLICT (tenant_id) DO UPDATE
        SET status = 'pending', detail = '', requested_at = now(), updated_at = now()
        WHERE tenant_hosts.status IN ('removing', 'removed', 'failed');
    RETURN NEW;
END
$$;

CREATE FUNCTION tenant_hosts_release() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE tenant_hosts SET status = 'removing', detail = '', updated_at = now()
    WHERE tenant_id = OLD.tenant_id;
    RETURN OLD;
END
$$;

CREATE TRIGGER tenants_queue_host AFTER INSERT ON tenants
    FOR EACH ROW EXECUTE FUNCTION tenant_hosts_queue();
CREATE TRIGGER tenants_release_host AFTER DELETE ON tenants
    FOR EACH ROW EXECUTE FUNCTION tenant_hosts_release();

INSERT INTO tenant_hosts (tenant_id) SELECT tenant_id FROM tenants ON CONFLICT DO NOTHING;
