-- 0111_message_answers.sql - answer once (spec 068 section 4.2, build lane
-- L2). Forward-only.
--
-- Spec 068 puts four orchestrator dispatchers (ODs) per box on every message
-- with no single orchestrator: each locks the messages it takes (rdb 0110,
-- messages.responsible / responsible_gen). The lock decides WHO; this table
-- makes the answer happen ONCE. An agent post that carries answers=<msg_id>
-- (a send frame field, outside the signed envelope) is accepted only from the
-- answered message's responsible seat on its current responsible_gen, and
-- only once:
--
--   message_answers  one row per answered message: the agent post that
--                    answered it, and the seat (<id>@<box>) and gen it
--                    answered on. The primary key (tenant_id, answers) is the
--                    "unique on (tenant, answers) for agent posts": a second
--                    answer is refused 409 naming this row.
--
-- A separate table, not a column on messages: the guard is one INSERT ... ON
-- CONFLICT DO NOTHING and never touches the messages insert path. The row
-- goes with the answered message (ON DELETE CASCADE), so retention needs
-- nothing new. The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: after 0110 (the guard reads its columns), before the hub
-- that writes this table.

CREATE TABLE message_answers (
    tenant_id     text        NOT NULL,
    answers       uuid        NOT NULL,
    answer_msg_id uuid        NOT NULL CHECK (answer_msg_id <> answers),
    seat          text        NOT NULL CHECK (length(seat) BETWEEN 3 AND 100 AND seat LIKE '%_@_%'),
    gen           bigint      NOT NULL CHECK (gen >= 0),
    answered_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, answers),
    FOREIGN KEY (tenant_id, answers) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);

-- RLS in the 0021 fail-closed NULLIF shape: a tenant reads and writes only
-- its own rows; the operator scope (spool migrate) sees everything.
ALTER TABLE message_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_answers FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON message_answers
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON message_answers
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
