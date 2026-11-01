-- 0249_messages_copied_from.sql - messages.copied_from (spec 169 v0.9
-- section 7, build row T3, SPL-4580; owner HUM-10, t1 537d51e9, Q1 = A: a
-- copy is a snapshot). Forward-only, additive, idempotent. The spec names
-- "<head+2>": the prefix after 0248_channel_move_journal.sql when it lands.
--
--   messages.copied_from  the msg_id in <SRC> a copied row was made from. A
--                     copy (T11) gives every row new task and msg ids in
--                     <DST> and keeps the original env / env_sig, which still
--                     name the OLD ids, as provenance; this column says so.
--                     NULL on every row that is not a copy. No FK: the
--                     source row lives in another workspace and may move or
--                     go; the column records where the copy came from, not
--                     a link that must resolve.
--
-- Catalog-only: nullable with no default, so Postgres adds it without
-- rewriting messages (the hub's largest table) and every existing row reads
-- NULL. RLS is unchanged: the messages policies cover the new column. No
-- index: nothing looks a row up by it yet.
-- DEPLOY ORDER: no hub reads or writes it yet; apply on dev and prd before a
-- hub with T11 rolls.

SET LOCAL lock_timeout = '5s';

ALTER TABLE messages ADD COLUMN IF NOT EXISTS copied_from uuid NULL;
