-- 0109_tenant_agent_split.sql — workspace guideline for how new agent
-- work is shared across vendors (owner t1 e837eeab). Forward-only.
--
-- The admin sets, out of 100, how much new agent work should go to each
-- kind. The numbers are a guideline, not a quota: the hub stores them and
-- does not refuse a spawn that drifts. The owner's current split is
-- claude 40 (the most demanding tasks), grok 50, agy 10. qwen is 0 so the
-- four kinds sum to 100; an admin can move points to qwen later. About
-- five points either way is the expected wobble, not a second stored range.
--
-- Existing workspaces receive the defaults with the columns. A later change
-- is one UPDATE of all four, and the sum CHECK keeps them at 100.
-- Applied by spool migrate before a hub that reads the columns is served.

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS agent_split_claude smallint NOT NULL DEFAULT 40
        CONSTRAINT tenants_agent_split_claude_check CHECK (agent_split_claude BETWEEN 0 AND 100),
    ADD COLUMN IF NOT EXISTS agent_split_grok smallint NOT NULL DEFAULT 50
        CONSTRAINT tenants_agent_split_grok_check CHECK (agent_split_grok BETWEEN 0 AND 100),
    ADD COLUMN IF NOT EXISTS agent_split_agy smallint NOT NULL DEFAULT 10
        CONSTRAINT tenants_agent_split_agy_check CHECK (agent_split_agy BETWEEN 0 AND 100),
    ADD COLUMN IF NOT EXISTS agent_split_qwen smallint NOT NULL DEFAULT 0
        CONSTRAINT tenants_agent_split_qwen_check CHECK (agent_split_qwen BETWEEN 0 AND 100);

ALTER TABLE tenants
    ADD CONSTRAINT tenants_agent_split_sum_check
    CHECK (agent_split_claude + agent_split_grok + agent_split_agy + agent_split_qwen = 100);
