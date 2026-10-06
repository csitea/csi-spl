-- 0140_box_facts.sql - the last fact sheet each box sent on its hello (OS,
-- run-times, system, network), so the Boxes page keeps it across a hub
-- restart. Forward-only.
--
-- Owner HUM-10, t1 950d5562: "the sat box has a lot of box info unreported,
-- fix that". The hub held the sheet in process memory only
-- (hub/box_facts.go): a Cloud Run roll leaves every box socket on the OLD
-- revision, and the NEW one, which answers every fresh roster read, said
-- "not reported yet" until each box redialled onto it.
--
--   box_facts   one row per (tenant, box), overwritten on a hello whose sheet
--               is newer. sheet is the hub's CLEANED copy (printable ASCII,
--               capped lists), never the box's raw bytes; reported_at is when
--               the box collected it.
--
-- No personal data: host names, versions and private addresses of the
-- workspace's own machines. Never public (public-dataset-allow-list.tst.sh).
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that writes this table (wf 20 does).

CREATE TABLE box_facts (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    box_id      text        NOT NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    reported_at timestamptz NOT NULL,
    sheet       jsonb       NOT NULL CHECK (jsonb_typeof(sheet) = 'object' AND octet_length(sheet::text) <= 16384),
    PRIMARY KEY (tenant_id, box_id)
);

-- RLS in the 0106 shape, with the empty-setting guard (NULLIF).
ALTER TABLE box_facts ENABLE ROW LEVEL SECURITY;
ALTER TABLE box_facts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON box_facts
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON box_facts
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
