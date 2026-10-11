-- 0178_agent_split_kind_orchestration.sql - a seventh task kind,
-- orchestration (dispatching and orchestrating), and grok in the
-- secret-class kinds (spec 115 sections 2 and 3.2). Forward-only; 0163 is
-- not edited, this file supersedes two of its CHECKs:
--
--   tenant_agent_split_kind_kind_check      the six kinds + orchestration
--                                           (owner HUM-10, msgs a1e5c678,
--                                           ff1baf01)
--   tenant_agent_split_kind_secret_vendors  secret AND orchestration (the
--                                           secret-class kinds): only claude,
--                                           grok and mistral may be non-zero
--                                           or the backup (the data rule,
--                                           owner msgs 26117740, 474f32a0)
--
-- No seed rows: a workspace with no orchestration row reads the default
-- (claude 65 / grok 35, backup grok). Every statement re-runs cleanly (DROP
-- ... IF EXISTS). Both CHECKs only widen, except that orchestration rows
-- cannot exist before this file, so no existing row fails.
-- DEPLOY ORDER: apply on dev AND prd BEFORE the hub that writes the kind
-- (the hub deploy migrates before it rolls).

ALTER TABLE tenant_agent_split_kind DROP CONSTRAINT IF EXISTS tenant_agent_split_kind_kind_check;
ALTER TABLE tenant_agent_split_kind ADD CONSTRAINT tenant_agent_split_kind_kind_check
    CHECK (kind IN ('specs_and_docs', 'tests', 'simple_coding', 'complex_coding', 'i18n', 'secret', 'orchestration'));

ALTER TABLE tenant_agent_split_kind DROP CONSTRAINT IF EXISTS tenant_agent_split_kind_secret_vendors;
ALTER TABLE tenant_agent_split_kind ADD CONSTRAINT tenant_agent_split_kind_secret_vendors
    CHECK (kind NOT IN ('secret', 'orchestration') OR vendor IN ('claude', 'grok', 'mistral')
           OR (weight = 0 AND NOT is_backup));
