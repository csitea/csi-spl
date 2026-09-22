-- 0026_message_revisions.sql — editing a sent message keeps every body it ever
-- had (specs/032 FR-ED-002/003, CLE-3443). Forward-only.
--
-- The owner asked for the edit and, in the same breath, for the register:
-- "both the old and the new msg should be stored ( for later feature to be
-- able to compare those msgs )". So an edit is NOT an overwrite. messages.body
-- / .msg / .env are rewritten to the current text, and every body the message
-- has ever had — the original included — lives here, one row per revision.
--
-- APPEND-ONLY: an edit INSERTs. revision 1 is the body as first sent, captured
-- at the FIRST edit (before that, a message has no rows here at all, which is
-- what makes "was this edited?" a cheap question). Each later edit inserts one
-- row. Nothing in this table is ever UPDATEd, and the only DELETE is the
-- retention cascade below.
--
-- Full bodies, not diffs: the compare feature the owner named will diff them,
-- and a chain of diffs cannot be read without replaying every link. A body is
-- at most 64 KiB (specs/020 message-schema-v2 §1) and only an edited message
-- has rows, so the table is bounded by how much people actually edit.
--
-- messages.edited_at / .edited_by are the marker the WUI renders (contract
-- §2.1). Both NULL = never edited; they always describe the LATEST edit, and
-- the register holds the history. They are two nullable columns, so the running
-- image ignores them: this file rolls BEFORE the image that writes them
-- (contract §8) and every intermediate state is safe.
--
-- ON DELETE CASCADE ties the register to its message, so the retention sweep
-- (postgres.go Sweep, DELETE FROM messages WHERE expires_at <= now) purges the
-- revisions with it and nothing has to remember this table exists (FR-ED-011).
-- Referential actions bypass row security, and the sweep runs asOperator in any
-- case.
--
-- RLS: the 0021 fail-closed form (NULLIF: a pooled connection reads the GUC as
-- '' after any transaction-local set_config, never NULL), matching messages.
-- A revision is exactly as readable as the message it belongs to.

ALTER TABLE messages
    ADD COLUMN edited_at timestamptz NULL,
    ADD COLUMN edited_by text        NULL;

CREATE TABLE message_revisions (
    tenant_id text        NOT NULL,
    msg_id    uuid        NOT NULL,
    -- 1 = the body as first sent; 2..n = one per edit, in order.
    revision  integer     NOT NULL
                          CONSTRAINT message_revisions_revision_check CHECK (revision >= 1),
    body      text        NOT NULL,
    -- The v:1 agent id that wrote THIS revision (revision 1 = messages.from_id).
    edited_by text        NOT NULL,
    -- When it was written (revision 1 = the message's received_at).
    edited_at timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, msg_id, revision),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);

-- No extra index: the primary key's btree on (tenant_id, msg_id, revision)
-- already answers both questions this table gets — every revision of one
-- message in order, and its highest revision.

ALTER TABLE message_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_revisions FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON message_revisions
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON message_revisions
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
