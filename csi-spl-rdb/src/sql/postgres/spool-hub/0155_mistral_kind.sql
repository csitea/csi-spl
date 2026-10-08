-- 0155_mistral_kind.sql — mistral is the 5th agent kind, ids m-NNN (spec 110
-- section 3.6, T001). Forward-only; 0101, 0102, 0109, 0110 and 0149 are not
-- edited, this file supersedes their [acgq] grammar and four-kind lists.
--
-- Spec 061 section 0 grammar becomes ^[acgmq]-[0-9]{3}$. Every CHECK that
-- names the letters is re-made with m, everything else in it unchanged:
--
--   roster_agent_id_check                       0101 (BOX- still forbidden)
--   issues_assignee_check                       0102 (<ID> or <ID>@<box>)
--   fleet_lanes_agent_id_check                  0101
--   fleet_asks_{from_agent,acked_by,closed_by}  0101
--   agent_id_aliases_new_id_check               0101 (kind stays the four
--                                               legacy kinds: no MST- ids)
--   messages_claim_defaults()                   0110 (responsible, OD seats)
--   tenants.agent_split_mistral                 next to 0109's four, default
--                                               0, so every row keeps sum 100
--   tenants_fleet_agent_kinds_off_check         0149, plus 'mistral'
--
-- No data UPDATE of any workspace's split (spec 110 3.6): moving grok's
-- points to mistral is the workspace admin's act on the settings screen.
-- Every statement re-runs cleanly (DROP ... IF EXISTS, ADD COLUMN IF NOT
-- EXISTS, CREATE OR REPLACE). Widening a CHECK fails no existing row.
-- DEPLOY ORDER: apply on dev AND prd BEFORE any m- agent registers.

ALTER TABLE roster DROP CONSTRAINT IF EXISTS roster_agent_id_check;
ALTER TABLE roster ADD CONSTRAINT roster_agent_id_check
    CHECK (agent_id ~ '^([acgmq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]+)$' AND agent_id !~ '^BOX-');

ALTER TABLE issues DROP CONSTRAINT IF EXISTS issues_assignee_check;
ALTER TABLE issues ADD CONSTRAINT issues_assignee_check
    CHECK (assignee = '' OR assignee ~ '^([acgmq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]+)(@[a-z0-9][a-z0-9-]{0,31})?$');

ALTER TABLE fleet_lanes DROP CONSTRAINT IF EXISTS fleet_lanes_agent_id_check;
ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_agent_id_check
    CHECK (agent_id ~ '^([acgmq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})$');

ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_from_agent_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_from_agent_check
    CHECK (from_agent ~ '^([acgmq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?$');
ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_acked_by_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_acked_by_check
    CHECK (acked_by ~ '^(([acgmq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?)?$');
ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_closed_by_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_closed_by_check
    CHECK (closed_by ~ '^(([acgmq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?)?$');

ALTER TABLE agent_id_aliases DROP CONSTRAINT IF EXISTS agent_id_aliases_new_id_check;
ALTER TABLE agent_id_aliases ADD CONSTRAINT agent_id_aliases_new_id_check
    CHECK (new_id ~ '^[acgmq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})$');

-- 0110's insert-time defaults, the letters widened. The trigger is unchanged.
CREATE OR REPLACE FUNCTION messages_claim_defaults() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.responsible IS NULL
       AND NEW.to_id ~ '^([acgmq]-[0-9]{3}|(CLE|AGY|GRK|QWN)-[0-9]+)$' AND NEW.to_id !~ '-000$' THEN
        NEW.responsible := NEW.to_id || '@' || NEW.to_box;
    END IF;
    IF NEW.to_id = 'peers' THEN
        NEW.needs_peer := true;
    ELSIF NEW.responsible IS NULL AND NEW.from_box = 'box-wui' AND NEW.from_id LIKE 'HUM-%'
          AND NEW.to_id = 'ALL-0'
          AND EXISTS (SELECT 1 FROM roster r
                      WHERE r.tenant_id = NEW.tenant_id AND r.agent_id ~ '^[acgmq]-00[1-4]$') THEN
        NEW.needs_peer := true;
    END IF;
    RETURN NEW;
END
$$;

-- 0110's back-fill for the new letter only: a retained message already sent
-- to an m- id (messages.to_id has no CHECK) names it responsible. Operator
-- scope: messages FORCEs RLS (0014).
SELECT set_config('app.rls_scope', 'operator', true);
UPDATE messages
SET responsible = to_id || '@' || to_box
WHERE responsible IS NULL
  AND expires_at > now()
  AND to_id ~ '^m-[0-9]{3}$' AND to_id !~ '-000$';

-- 0109's split, five-way. A constant default: catalog-only, no rewrite.
ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS agent_split_mistral smallint NOT NULL DEFAULT 0
        CONSTRAINT tenants_agent_split_mistral_check CHECK (agent_split_mistral BETWEEN 0 AND 100);

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_agent_split_sum_check;
ALTER TABLE tenants ADD CONSTRAINT tenants_agent_split_sum_check
    CHECK (agent_split_claude + agent_split_grok + agent_split_agy + agent_split_qwen + agent_split_mistral = 100);

-- 0149's instance kill switch learns the kind.
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_fleet_agent_kinds_off_check;
ALTER TABLE tenants ADD CONSTRAINT tenants_fleet_agent_kinds_off_check
    CHECK (fleet_agent_kinds_off <@ ARRAY['claude', 'grok', 'agy', 'qwen', 'mistral']::text[]);
