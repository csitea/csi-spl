-- 0309_tenant_agent_model.sql - the default model per agent kind (spec 184
-- row H1, contract 7.1.5; owner HUM-10 msg 0d33aa83, Q2 bo and N1).
-- Forward-only, additive; two new tables, no seed rows.
--
--   tenant_agent_model     a workspace's override of the cnf
--                          env.box.agent_model: one model per (vendor, kind),
--                          kind '*' = the vendor's default. No row = not set
--                          (the resolver falls back to the cnf). Written by
--                          PATCH /v1/tenant/settings (field agent_models).
--   agent_model_reading    the latest live list (spec 184 7.1.6) a box read
--                          of a vendor's CLI, with that CLI's version. Written
--                          by PUT /v1/boxes/{box}/agent-models/{vendor}; a
--                          newer read_at replaces the row. Display only (N1):
--                          the WUI picker's choices, never a gate.
--
-- The CHECKs mirror the hub's (store/agent_model.go), so the database stays
-- the last word:
--   *_vendor_check   the six vendors of tenant_agent_split_kind (0283)
--   *_kind_check     the seven split kinds (0178), or '*'
--   *_model_check    contract 7.1.2's syntax, ^[A-Za-z0-9._:/-]{1,80}$
--   *_models_check   every listed model in that syntax, at most 500
-- RLS in the 0163 shape: tenant_scope + operator_scope, ENABLE + FORCE.
-- Every statement re-runs cleanly.
-- DEPLOY ORDER: apply on dev AND prd BEFORE the hub that reads it (the hub
-- deploy migrates before it rolls).

CREATE TABLE IF NOT EXISTS tenant_agent_model (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    vendor     text        NOT NULL,
    kind       text        NOT NULL,
    model      text        NOT NULL,
    updated_by text        NOT NULL DEFAULT '' CHECK (length(updated_by) <= 200),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tenant_agent_model_pkey PRIMARY KEY (tenant_id, vendor, kind),
    CONSTRAINT tenant_agent_model_vendor_check
        CHECK (vendor IN ('claude', 'grok', 'agy', 'qwen', 'mistral', 'codex')),
    CONSTRAINT tenant_agent_model_kind_check
        CHECK (kind IN ('*', 'specs_and_docs', 'tests', 'simple_coding', 'complex_coding', 'i18n',
                        'secret', 'orchestration')),
    CONSTRAINT tenant_agent_model_model_check
        CHECK (model ~ '^[A-Za-z0-9._:/-]{1,80}$')
);

ALTER TABLE tenant_agent_model ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_agent_model FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON tenant_agent_model;
CREATE POLICY tenant_scope ON tenant_agent_model
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON tenant_agent_model;
CREATE POLICY operator_scope ON tenant_agent_model
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- agent_model_list_ok: at most 500 models, none NULL, each in the 7.1.2
-- syntax. Checked per element: a joined string would let a separator inside
-- one model ('Gemini 3.8') read as two good ones.
CREATE OR REPLACE FUNCTION agent_model_list_ok(models text[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT cardinality(models) <= 500
       AND NOT EXISTS (SELECT 1 FROM unnest(models) m
                        WHERE m IS NULL OR m !~ '^[A-Za-z0-9._:/-]{1,80}$')
$$;

CREATE TABLE IF NOT EXISTS agent_model_reading (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    box         text        NOT NULL CHECK (length(box) BETWEEN 1 AND 64),
    vendor      text        NOT NULL,
    cli_version text        NOT NULL DEFAULT '' CHECK (length(cli_version) <= 80),
    models      text[]      NOT NULL DEFAULT '{}',
    read_at     timestamptz NOT NULL,
    CONSTRAINT agent_model_reading_pkey PRIMARY KEY (tenant_id, box, vendor),
    CONSTRAINT agent_model_reading_vendor_check
        CHECK (vendor IN ('claude', 'grok', 'agy', 'qwen', 'mistral', 'codex')),
    CONSTRAINT agent_model_reading_models_check CHECK (agent_model_list_ok(models))
);

ALTER TABLE agent_model_reading ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_model_reading FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON agent_model_reading;
CREATE POLICY tenant_scope ON agent_model_reading
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON agent_model_reading;
CREATE POLICY operator_scope ON agent_model_reading
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
