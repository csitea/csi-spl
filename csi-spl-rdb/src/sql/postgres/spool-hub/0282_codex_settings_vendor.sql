-- 0282_codex_settings_vendor.sql - codex (OpenAI Codex CLI, o-NNN, spec 161)
-- becomes a vendor in every workspace setting that names the other agent
-- vendors (SPL-5454, owner HUM-10 t1 9130912f: "put here the OpenAI app
-- as well as an AI client"). Forward-only; 0109, 0155, 0163, 0174 and 0212
-- are not edited. 0238 already let codex be an agent id and a kind off.
--
--   tenants.agent_split_codex                   the flat split, default 0;
--                                               the sum CHECK takes it in
--   tenant_agent_split_kind_vendor_check        0163, plus 'codex'
--   chk_tenant_agent_caps_vendor                0212, plus 'codex'
--   workspace_vendor_keys_kind_check            0174, plus 'codex' (the hub's
--   workspace_vendor_key_audit_kind_check       VendorKeyAvailable still
--                                               refuses a codex key PUT)
--
-- Unchanged on purpose: tenant_agent_split_kind_secret_vendors (0178) keeps
-- codex at 0 and never the backup in secret and orchestration (the data
-- rule, spec 161 section 5.1, owner msg 1fe6abcf).
-- Every statement re-runs cleanly; widening a CHECK fails no existing row,
-- and a new column at 0 keeps every stored split at 100.
-- DEPLOY ORDER: apply on dev AND prd BEFORE the hub that reads it (the hub
-- deploy migrates its env first).

SET LOCAL lock_timeout = '5s';

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS agent_split_codex smallint NOT NULL DEFAULT 0
        CONSTRAINT tenants_agent_split_codex_check CHECK (agent_split_codex BETWEEN 0 AND 100);

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_agent_split_sum_check;
ALTER TABLE tenants ADD CONSTRAINT tenants_agent_split_sum_check
    CHECK (agent_split_claude + agent_split_grok + agent_split_agy + agent_split_qwen + agent_split_mistral
           + agent_split_codex = 100);

ALTER TABLE tenant_agent_split_kind DROP CONSTRAINT IF EXISTS tenant_agent_split_kind_vendor_check;
ALTER TABLE tenant_agent_split_kind ADD CONSTRAINT tenant_agent_split_kind_vendor_check
    CHECK (vendor IN ('claude', 'grok', 'agy', 'qwen', 'mistral', 'codex'));

ALTER TABLE tenant_agent_caps DROP CONSTRAINT IF EXISTS chk_tenant_agent_caps_vendor;
ALTER TABLE tenant_agent_caps ADD CONSTRAINT chk_tenant_agent_caps_vendor
    CHECK (vendor IN ('claude', 'grok', 'mistral', 'agy', 'qwen', 'codex'));

ALTER TABLE workspace_vendor_keys DROP CONSTRAINT IF EXISTS workspace_vendor_keys_kind_check;
ALTER TABLE workspace_vendor_keys ADD CONSTRAINT workspace_vendor_keys_kind_check
    CHECK (kind IN ('claude', 'grok', 'agy', 'mistral', 'qwen', 'codex'));

ALTER TABLE workspace_vendor_key_audit DROP CONSTRAINT IF EXISTS workspace_vendor_key_audit_kind_check;
ALTER TABLE workspace_vendor_key_audit ADD CONSTRAINT workspace_vendor_key_audit_kind_check
    CHECK (kind IN ('claude', 'grok', 'agy', 'mistral', 'qwen', 'codex'));
