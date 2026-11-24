-- 0321_messages_mc_id.sql - the multicast id on messages (spec 186 row M1,
-- section 7.1.3). Forward-only, additive, idempotent.
--
-- mc_id is a client-minted UUID shared by every copy of one multicast, stored
-- on each copy; NULL on every other message. The hub writes it (row M2); this
-- file only adds the column and its index.
--
-- No FK, no default: the id names no row of another table. RLS unchanged:
-- messages keeps its policies, the new column is read and written under them.
--
-- The index is partial (WHERE mc_id IS NOT NULL): only multicast copies are
-- indexed, so the existing rows add nothing to it.
--
-- Live-data safety: ADD COLUMN with no default is a catalogue change, no
-- table rewrite; the index build reads messages once and indexes no
-- existing row.
-- DEPLOY ORDER: apply BEFORE the hub that writes mc_id (wf 20 does).

SET LOCAL lock_timeout = '5s';

ALTER TABLE messages ADD COLUMN IF NOT EXISTS mc_id uuid NULL;

CREATE INDEX IF NOT EXISTS messages_mc_id ON messages (tenant_id, mc_id) WHERE mc_id IS NOT NULL;
