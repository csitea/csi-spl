-- 0262_agent_split_kind_agy_codes.sql - agy takes coding work (spec 115
-- section 2 G2 lifted; owner HUM-10, t1 71b557a8, msg dc673043, SPL-4826).
-- Forward-only; 0163 is not edited, this file drops one of its CHECKs:
--
--   tenant_agent_split_kind_no_agy_coding   dropped: agy may be weighted and
--                                           be the backup in tests,
--                                           simple_coding, complex_coding
--
-- The data rule is unchanged: tenant_agent_split_kind_secret_vendors (0178)
-- still refuses agy (and qwen) in secret and orchestration. Dropping a CHECK
-- only widens, so no existing row fails; the statement re-runs cleanly.
-- DEPLOY ORDER: apply on dev AND prd BEFORE the hub that accepts agy in a
-- coding kind (the hub deploy migrates before it rolls).

ALTER TABLE tenant_agent_split_kind DROP CONSTRAINT IF EXISTS tenant_agent_split_kind_no_agy_coding;
