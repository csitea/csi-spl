-- 0248_channel_move_journal.sql - the channel move journal and the
-- hub-wide redirect table (spec 169 v0.9 sections 8.3 and 11.1 Q2, build
-- row T2, SPL-4580; owner HUM-10, t1 3a618e79). Forward-only, additive,
-- idempotent. The spec names "<head+1>": the next prefix on master when it
-- lands (renumbered on rebase).
--
--   channel_move_journal    one row per move or copy of a channel INTO this
--                     workspace (tenant_id = <DST>): the record that the
--                     channel came from somewhere, kept where the channel
--                     now is (8.3). frozen holds the id lists plan froze,
--                     keyed by the channelmove.Binds names (channel, tasks,
--                     msgs, ...). go_msg_id is the owner's GO answer for
--                     THIS channel and target (8.1, C15): no journal row is
--                     written without it. channel_id is the channel's id in
--                     <DST> (TO_NAME may rename it), src_channel_id its id
--                     in <SRC>.
--   channel_move_steps      one row per step P1..P7 (8.2): started_at,
--                     done_at (NULL while the step runs: a re-run resumes
--                     at the first step not done, C17), counts, proofs (P7)
--                     and detail (the P2b probe msg ids, the P5 lane notes).
--                     It repeats channel_id under a composite FK, so the
--                     move catalogue finds a journal's steps by the channel
--                     alone: a later move of the same channel carries both.
--   channel_move_redirects  Q2 = A: for 30 days an old permalink, a post to a
--                     moved task and an old issue key in <SRC> resolve to
--                     <DST>; after that nothing does (404). Hub-wide, ids
--                     only: no channel id or name (C13). kind task / msg
--                     keeps the same uuid in old_ref and new_ref (a move
--                     changes no uuid, W3); kind issue maps <SRC>'s key to
--                     the new <DST> key (W4). A reader ignores a row past
--                     expires_at; deleting those is a sweep's job. move_id
--                     names the journal row with no FK: a journal moves on
--                     with its channel, and that <SRC> delete must not
--                     cascade here.
--
-- RLS: both journal tables are tenant tables in the 0240 shape
-- (tenant_scope with NULLIF + operator_scope): a statement without a tenant
-- reads and writes no row. channel_move_redirects has no tenant_id: only
-- the operator scope writes it (P4 runs asOperator), and a tenant scope
-- READS only the rows whose src_tenant_id is its own (the hub resolves an
-- old link of <SRC> inside <SRC>'s scope); <DST> and every other tenant read
-- none. The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, as every table since 017. No
-- change_stamp trigger, no personal data.
-- DEPLOY ORDER: no hub reads or writes these tables yet; apply on dev and
-- prd before a hub with the T5 / T7 rows rolls.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS channel_move_journal (
    tenant_id      text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    move_id        uuid        NOT NULL,
    mode           text        NOT NULL CHECK (mode IN ('move', 'copy')),
    src_tenant_id  text        NOT NULL CHECK (src_tenant_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    src_channel_id text        NOT NULL CHECK (src_channel_id ~ '^[a-z0-9][a-z0-9-]{0,63}$'),
    channel_id     text        NOT NULL CHECK (channel_id ~ '^[a-z0-9][a-z0-9-]{0,63}$'),
    frozen         jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(frozen) = 'object'),
    go_msg_id      uuid        NOT NULL,
    started_by     text        NOT NULL CHECK (length(started_by) BETWEEN 1 AND 64),
    created_at     timestamptz NOT NULL DEFAULT now(),
    done_at        timestamptz NULL,
    PRIMARY KEY (tenant_id, move_id),
    CONSTRAINT uq_channel_move_journal_channel UNIQUE (tenant_id, move_id, channel_id),
    CONSTRAINT ck_channel_move_journal_src CHECK (src_tenant_id <> tenant_id),
    CONSTRAINT ck_channel_move_journal_done CHECK (done_at IS NULL OR done_at >= created_at)
);
CREATE INDEX IF NOT EXISTS ix_channel_move_journal_channel
    ON channel_move_journal (tenant_id, channel_id);

CREATE TABLE IF NOT EXISTS channel_move_steps (
    tenant_id  text        NOT NULL,
    move_id    uuid        NOT NULL,
    channel_id text        NOT NULL,
    step       text        NOT NULL CHECK (step IN ('P1', 'P2', 'P2b', 'P3', 'P4', 'P5', 'P6', 'P7')),
    started_at timestamptz NOT NULL DEFAULT now(),
    done_at    timestamptz NULL,
    counts     jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(counts) = 'object'),
    proofs     jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(proofs) = 'object'),
    detail     jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(detail) = 'object'),
    PRIMARY KEY (tenant_id, move_id, step),
    CONSTRAINT fk_channel_move_steps_journal FOREIGN KEY (tenant_id, move_id, channel_id)
        REFERENCES channel_move_journal (tenant_id, move_id, channel_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT ck_channel_move_steps_done CHECK (done_at IS NULL OR done_at >= started_at)
);
CREATE INDEX IF NOT EXISTS ix_channel_move_steps_channel
    ON channel_move_steps (tenant_id, channel_id);

CREATE TABLE IF NOT EXISTS channel_move_redirects (
    src_tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    kind          text        NOT NULL CHECK (kind IN ('task', 'msg', 'issue')),
    old_ref       text        NOT NULL CHECK (length(old_ref) BETWEEN 1 AND 64),
    dst_tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    new_ref       text        NOT NULL CHECK (length(new_ref) BETWEEN 1 AND 64),
    move_id       uuid        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL DEFAULT now() + interval '30 days',
    PRIMARY KEY (src_tenant_id, kind, old_ref),
    CONSTRAINT ck_channel_move_redirects_tenants CHECK (dst_tenant_id <> src_tenant_id),
    CONSTRAINT ck_channel_move_redirects_expiry CHECK (expires_at > created_at),
    CONSTRAINT ck_channel_move_redirects_uuid CHECK (kind = 'issue' OR (
        old_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND new_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
);
CREATE INDEX IF NOT EXISTS ix_channel_move_redirects_expires_at
    ON channel_move_redirects (expires_at);
CREATE INDEX IF NOT EXISTS ix_channel_move_redirects_move_id
    ON channel_move_redirects (move_id);

ALTER TABLE channel_move_journal ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_move_journal FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON channel_move_journal;
CREATE POLICY tenant_scope ON channel_move_journal
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON channel_move_journal;
CREATE POLICY operator_scope ON channel_move_journal
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE channel_move_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_move_steps FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON channel_move_steps;
CREATE POLICY tenant_scope ON channel_move_steps
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON channel_move_steps;
CREATE POLICY operator_scope ON channel_move_steps
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE channel_move_redirects ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_move_redirects FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON channel_move_redirects;
CREATE POLICY operator_scope ON channel_move_redirects
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
DROP POLICY IF EXISTS src_read ON channel_move_redirects;
CREATE POLICY src_read ON channel_move_redirects
    FOR SELECT
    USING (src_tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
