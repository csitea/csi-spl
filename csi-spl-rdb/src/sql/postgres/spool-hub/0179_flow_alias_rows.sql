-- 0179_flow_alias_rows.sql - delete the flow_events rows keyed to an alias
-- as if it were an agent (spec 130 FR-007). Forward-only, data only.
--
-- 72d89a947 (spec 130 L1) admitted every participant with a box as an agent
-- flow member, so a channel line to the everyone-alias ALL-0 (to_box
-- box-wui) wrote a `mention` row keyed 'ALL-0@box-wui': 9 rows on prd t1,
-- 0 on dev, measured 2026-10-11. The hub no longer writes them
-- (store.IsFlowAgent / flowAgentSQL take an agent id only); this removes the
-- ones already stored. Every row with an '@' whose id part is not an agent
-- id (store.flowAgentSQL, agentid.IsAgent) is one of them. Nobody reads them:
-- no seat or agent signs in as an alias. flow_watches holds only seats.
--
-- Operator scope: flow_events FORCEs RLS (0104).

SELECT set_config('app.rls_scope', 'operator', true);
DELETE FROM flow_events
WHERE member_id LIKE '%@%'
  AND member_id !~ '^([acgmq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|(CLE|AGY|GRK|QWN)-[0-9]+)@[a-z0-9][a-z0-9-]{0,31}$';
