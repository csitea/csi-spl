-- 0058_message_kinds.sql — two new message kinds (SPL-952, spec 020).
-- Forward-only.
--
-- Owner, 2026-09-26 (topic fa1a9fcd): a bot that "needs input and without the
-- input he cannot proceed" posts a blocker; "there should be a simple msg type
-- as well". The hub (internal/msg validKinds) accepts both; this widens the
-- CHECK 0001 put on messages.kind so the insert does not refuse them. Existing
-- rows keep their kind.

ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check;

ALTER TABLE messages ADD CONSTRAINT messages_kind_check
    CHECK (kind IN ('task', 'result', 'note', 'reject', 'blocker', 'msg'));
