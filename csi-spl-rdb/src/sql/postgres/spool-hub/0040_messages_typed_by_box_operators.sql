-- 0040_messages_typed_by_box_operators.sql — a terminal-typed line shows as
-- the HUMAN who typed it (specs/036 FR-009..FR-012). Forward-only.
--
-- A box signs with its box key and can never mint a human's identity, so the
-- message's `from` stays the agent and the attribution is a separate claim the
-- hub VERIFIES: the box sends `typed_by` on its WS send frame (never in the
-- signed envelope), and the hub accepts it only when a box_operators row says
-- that human operates that box. A tenant owner / admin grants the row (the
-- orc action do_spl_box_operator_grant) - never the box.
--
-- messages.typed_by: the HUM-* the hub accepted for this row; NULL = the
-- agent itself wrote it (every row stored before this migration). Hub
-- metadata like edited_by: not a field of the signed v:1 body, never in a
-- frame to a box.

ALTER TABLE messages ADD COLUMN IF NOT EXISTS typed_by text NULL;

ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_typed_by_chk;

ALTER TABLE messages ADD CONSTRAINT messages_typed_by_chk CHECK (typed_by IS NULL OR typed_by ~ '^HUM-[0-9]+$');

-- One row = this member operates this box's terminals. Removing the member
-- takes the binding with it (the FK), so a removed human can never be
-- attributed again. The box is not an FK: a binding may be granted before the
-- box's first pin, and the hub checks the sending box's pin on every send.
CREATE TABLE IF NOT EXISTS box_operators (
    tenant_id  text        NOT NULL,
    box_id     text        NOT NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    human_id   text        NOT NULL,
    -- The owner / admin HUM-* who granted it, or 'operator' for the orc action.
    granted_by text        NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, box_id, human_id),
    FOREIGN KEY (tenant_id, human_id) REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE
);

-- The primary key answers the hub's one question (is (tenant, box, human)
-- bound?). No second index.

ALTER TABLE box_operators ENABLE ROW LEVEL SECURITY;
ALTER TABLE box_operators FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON box_operators
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON box_operators
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
