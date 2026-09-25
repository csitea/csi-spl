-- 0034_messages_is_parent.sql — UI parent flag on every message.
-- Forward-only. NOT NULL DEFAULT 0 so a box or agent send, and every
-- row already stored, is 0. The browser sends 1 when the topics tab is
-- not selected or the topic pane is not visible, and 0 when both are
-- true (the pane is open and the topics list is the selected tab).

ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_parent smallint NOT NULL DEFAULT 0;

ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_is_parent_chk;

ALTER TABLE messages ADD CONSTRAINT messages_is_parent_chk CHECK (is_parent IN (0, 1));
