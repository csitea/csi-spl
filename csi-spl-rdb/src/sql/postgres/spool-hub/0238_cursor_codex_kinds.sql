-- 0238_cursor_codex_kinds.sql — cursor and codex are the 6th and 7th agent
-- kinds, ids u-NNN and o-NNN (spec 161 section 3.1 and row B1; the owner
-- chose o for Codex, msg 4ae81b56). Forward-only; 0155 is not edited, this
-- file supersedes its [acgmq] grammar and five-kind list.
--
-- The grammar becomes ^[acgmoqu]-[0-9]{3}$. Every CHECK 0155 re-made with the
-- letters is re-made again, only the letter class changed:
--
--   roster_agent_id_check                       0155 (BOX- still forbidden)
--   issues_assignee_check                       0155 (<ID> or <ID>@<box>)
--   fleet_lanes_agent_id_check                  0155
--   fleet_asks_{from_agent,acked_by,closed_by}  0155
--   agent_id_aliases_new_id_check               0155
--   messages_claim_defaults()                   0155 (responsible, OD seats)
--   tenants_fleet_agent_kinds_off_check         0155, plus 'cursor', 'codex'
--
-- No split column: cursor and codex in the workspace split are row B8.
-- Every statement re-runs cleanly (DROP ... IF EXISTS, CREATE OR REPLACE).
-- Widening a CHECK fails no existing row.
-- DEPLOY ORDER: apply on dev AND prd BEFORE any u- or o- agent registers.

ALTER TABLE roster DROP CONSTRAINT IF EXISTS roster_agent_id_check;
ALTER TABLE roster ADD CONSTRAINT roster_agent_id_check
    CHECK (agent_id ~ '^([acgmoqu]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]+)$' AND agent_id !~ '^BOX-');

ALTER TABLE issues DROP CONSTRAINT IF EXISTS issues_assignee_check;
ALTER TABLE issues ADD CONSTRAINT issues_assignee_check
    CHECK (assignee = '' OR assignee ~ '^([acgmoqu]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]+)(@[a-z0-9][a-z0-9-]{0,31})?$');

ALTER TABLE fleet_lanes DROP CONSTRAINT IF EXISTS fleet_lanes_agent_id_check;
ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_agent_id_check
    CHECK (agent_id ~ '^([acgmoqu]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})$');

ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_from_agent_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_from_agent_check
    CHECK (from_agent ~ '^([acgmoqu]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?$');
ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_acked_by_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_acked_by_check
    CHECK (acked_by ~ '^(([acgmoqu]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?)?$');
ALTER TABLE fleet_asks DROP CONSTRAINT IF EXISTS fleet_asks_closed_by_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_closed_by_check
    CHECK (closed_by ~ '^(([acgmoqu]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?)?$');

ALTER TABLE agent_id_aliases DROP CONSTRAINT IF EXISTS agent_id_aliases_new_id_check;
ALTER TABLE agent_id_aliases ADD CONSTRAINT agent_id_aliases_new_id_check
    CHECK (new_id ~ '^[acgmoqu]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})$');

-- 0155's insert-time defaults, the letters widened. The trigger is unchanged.
CREATE OR REPLACE FUNCTION messages_claim_defaults() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.responsible IS NULL
       AND NEW.to_id ~ '^([acgmoqu]-[0-9]{3}|(CLE|AGY|GRK|QWN)-[0-9]+)$' AND NEW.to_id !~ '-000$' THEN
        NEW.responsible := NEW.to_id || '@' || NEW.to_box;
    END IF;
    IF NEW.to_id = 'peers' THEN
        NEW.needs_peer := true;
    ELSIF NEW.responsible IS NULL AND NEW.from_box = 'box-wui' AND NEW.from_id LIKE 'HUM-%'
          AND NEW.to_id = 'ALL-0'
          AND EXISTS (SELECT 1 FROM roster r
                      WHERE r.tenant_id = NEW.tenant_id AND r.agent_id ~ '^[acgmoqu]-00[1-4]$') THEN
        NEW.needs_peer := true;
    END IF;
    RETURN NEW;
END
$$;

-- 0155's back-fill for the new letters only: a retained message already sent
-- to a u- or o- id (messages.to_id has no CHECK) names it responsible.
-- Operator scope: messages FORCEs RLS (0014).
SELECT set_config('app.rls_scope', 'operator', true);
UPDATE messages
SET responsible = to_id || '@' || to_box
WHERE responsible IS NULL
  AND expires_at > now()
  AND to_id ~ '^[uo]-[0-9]{3}$' AND to_id !~ '-000$';

-- 0149's instance kill switch learns the two kinds.
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_fleet_agent_kinds_off_check;
ALTER TABLE tenants ADD CONSTRAINT tenants_fleet_agent_kinds_off_check
    CHECK (fleet_agent_kinds_off <@ ARRAY['claude', 'grok', 'agy', 'qwen', 'mistral', 'cursor', 'codex']::text[]);
