-- 0005_pin_identity.sql — identity hardening (specs/004-spool-identity-routing,
-- tasks T019, T020). Forward-only.

-- T019: BOX- is forbidden as an agent-id prefix at every layer, not only in Go
-- (contracts/identifiers.md §2).
ALTER TABLE roster DROP CONSTRAINT roster_agent_id_check;
ALTER TABLE roster ADD CONSTRAINT roster_agent_id_check
    CHECK (agent_id ~ '^[A-Z]{2,4}-[0-9]+$' AND agent_id !~ '^BOX-');

-- T020: the client ts of the last tenant-root-signed op (pin / force / revoke)
-- that changed this pin. A state-changing op must carry a strictly later ts, so
-- a captured request cannot be replayed (contracts/pin-semantics.md §5).
-- NULL = no op recorded yet (rows from before this migration).
ALTER TABLE pins ADD COLUMN last_op_ts timestamptz NULL;
