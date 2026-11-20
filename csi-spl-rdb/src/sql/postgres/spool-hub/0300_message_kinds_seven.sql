-- 0300_message_kinds_seven.sql — seven new message kinds (SPL-5884, spec 033
-- section K.5, build row T020). Forward-only.
--
-- Owner HUM-10, t1 f4165bc3 (msg 890eadfb): new kinds in the same menu,
-- "feature; bug; alert; question; idea; decision; docs". The hub
-- (internal/msg validKinds) accepts them; this widens the two CHECKs that
-- list the kinds: messages.kind (0058) and message_kind_changes.kind_to
-- (0060). kind_from has no CHECK and keeps none: it holds whatever the
-- message had. No data change: existing rows keep their kind. The file rolls
-- before the image that writes a new kind, as 0060 did.

ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check;

ALTER TABLE messages ADD CONSTRAINT messages_kind_check
    CHECK (kind IN ('task', 'result', 'note', 'reject', 'blocker', 'msg',
                    'feature', 'bug', 'alert', 'question', 'idea', 'decision', 'docs'));

ALTER TABLE message_kind_changes DROP CONSTRAINT IF EXISTS message_kind_changes_kind_to_check;

ALTER TABLE message_kind_changes ADD CONSTRAINT message_kind_changes_kind_to_check
    CHECK (kind_to IN ('task', 'result', 'note', 'reject', 'blocker', 'msg',
                       'feature', 'bug', 'alert', 'question', 'idea', 'decision', 'docs'));
