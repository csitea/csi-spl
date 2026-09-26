-- 0060_message_kind_changes.sql — a sent message's kind can be set after the
-- fact (SPL-952, topic d88a3fbb). Forward-only.
--
-- Owner, 2026-09-26: "the type of the msg should be clickable and settable
-- the same way the icons are settable". The kind lives inside the SIGNED
-- inner object, and an agent's envelope is signed by its box with a key the
-- hub does not hold, so a changed kind cannot be written back into the
-- envelope. It is HUB METADATA instead, like edited_at and typed_by:
--
--   messages.kind         rewritten to the current kind, so search (is:blocker)
--                         and the topic kind counts follow the change
--   messages.kind_set_by  the v:1 id that set it last; NULL = never changed,
--   messages.kind_set_at  and the view then carries no `kind` override
--
-- The envelope keeps the kind it was sent with. message_kind_changes is the
-- append-only register (the rdb 0026 pattern): one row per change, holding
-- the kind before and after. Nothing here is ever UPDATEd; the only DELETE is
-- the retention cascade. Two nullable columns plus a new table: the running
-- image ignores all three, so this file rolls before the image that writes them.
--
-- RLS: the 0021 fail-closed form, matching messages.

ALTER TABLE messages
    ADD COLUMN kind_set_by text        NULL,
    ADD COLUMN kind_set_at timestamptz NULL;

CREATE TABLE message_kind_changes (
    tenant_id text        NOT NULL,
    msg_id    uuid        NOT NULL,
    -- 1..n, one per change, in order.
    seq       integer     NOT NULL
                          CONSTRAINT message_kind_changes_seq_check CHECK (seq >= 1),
    kind_from text        NOT NULL,
    kind_to   text        NOT NULL
                          CONSTRAINT message_kind_changes_kind_to_check
                          CHECK (kind_to IN ('task', 'result', 'note', 'reject', 'blocker', 'msg')),
    set_by    text        NOT NULL,
    set_at    timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, msg_id, seq),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);

ALTER TABLE message_kind_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_kind_changes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON message_kind_changes
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON message_kind_changes
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
