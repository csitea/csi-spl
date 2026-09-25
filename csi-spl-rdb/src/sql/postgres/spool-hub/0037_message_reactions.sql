-- 0037_message_reactions.sql — an emoji one person adds to one message.
-- Forward-only.
--
-- A reaction is hub metadata, like edited_at: it is not a field of the signed
-- v:1 body. The same table holds a reaction on an opening message (is_parent
-- 1, the middle card) and on a reply (is_parent 0, the right-hand topic
-- pane). is_parent is not stored here; the message row already has it.
--
-- One row is one actor's one emoji. Adding the same emoji again is a no-op
-- (the primary key). Removing it deletes that row. Deleting the message
-- takes the reactions with it.
--
-- RLS matches messages (0021 fail-closed NULLIF form). A reaction is exactly
-- as readable as the message it belongs to.

CREATE TABLE message_reactions (
    tenant_id  text        NOT NULL,
    msg_id     uuid        NOT NULL,
    -- The v:1 id of the member who added it (a HUM-* from the browser).
    actor      text        NOT NULL,
    emoji      text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, msg_id, actor, emoji),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);

-- The primary key's leading (tenant_id, msg_id) answers "every reaction on
-- this message, in the order they were added" once created_at is sorted.
-- No second index.

ALTER TABLE message_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_reactions FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON message_reactions
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON message_reactions
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
