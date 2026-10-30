-- 0242_file_stream_globs.sql - spec 160 section 3.8 row B9 (SPL-4294; owner
-- HUM-10, t1 c168784c, poll 376e9435 answer B msg d925f9a3, poll 900699dd
-- msg 369e7bfa): file globs typed in the web page by a workspace owner or
-- admin, for one box. Forward-only, additive, idempotent. The spec names "the
-- next free number at build time": the next prefix on master when it lands
-- (renumbered on rebase).
--
--   file_stream_globs       one glob PATTERN for one box (3.8.4). The hub
--                           never opens, lists or resolves it (3.8.1): it
--                           checks the syntax, stores it and hands it to the
--                           box when the box pulls (lane op file_streams_globs).
--                           removed_at set = removed (3.8.8); the key is
--                           unique among a box's live globs only. box_state ..
--                           reported_at are the box's own last report from its
--                           announce ('pending' until the box reports it).
--   file_stream_glob_audit  one row per add, remove and hub refusal of an add
--                           (3.8.9), with the actor's human id and the reason
--                           code. Kept SPOOL_HUB_FILE_STREAMS_GLOB_AUDIT_RETENTION
--                           (365 days), pruned by the hub's sweeper.
--   file_stream_folders     the allowed folders a box last announced (3.8.2,
--                           3.8.5), each allowed or refused by the box's own
--                           check. The hub reads them only to show them and to
--                           refuse an obvious miss early (400 outside_folders);
--                           the gate is the box (3.8.1). An announce that
--                           carries folders replaces the box's rows.
--
-- RLS: the 0237 shape, tenant_scope with NULLIF + operator_scope; a statement
-- without a tenant reads and writes no row. The runtime grants come from the
-- default privileges of spool-hub-roles/runtime-grants.sql, as every table
-- since 017. No secret, no personal data beyond the actor's human id.
-- DEPLOY ORDER: wf 20 applies this file before it rolls the hub that writes
-- any of the three tables.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS file_stream_globs (
    tenant_id   text        NOT NULL,
    id          uuid        NOT NULL,
    box_id      text        NOT NULL,
    key         text        NOT NULL CHECK (key ~ '^[a-z0-9][a-z0-9-]{0,23}$'),
    glob        text        NOT NULL CHECK (octet_length(glob) BETWEEN 1 AND 512),
    created_by  text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    removed_at  timestamptz NULL,
    box_state   text        NOT NULL DEFAULT 'pending'
        CHECK (box_state IN ('pending', 'following', 'partial', 'none', 'refused')),
    box_reason  text        NOT NULL DEFAULT '' CHECK (length(box_reason) <= 200),
    matched     integer     NOT NULL DEFAULT 0 CHECK (matched >= 0),
    followed    integer     NOT NULL DEFAULT 0 CHECK (followed >= 0),
    over_cap    integer     NOT NULL DEFAULT 0 CHECK (over_cap >= 0),
    reported_at timestamptz NULL,
    CONSTRAINT pk_file_stream_globs PRIMARY KEY (tenant_id, id),
    CONSTRAINT fk_file_stream_globs_box FOREIGN KEY (tenant_id, box_id)
        REFERENCES boxes (tenant_id, box_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_file_stream_globs_live_key
    ON file_stream_globs (tenant_id, box_id, key) WHERE removed_at IS NULL;

CREATE TABLE IF NOT EXISTS file_stream_glob_audit (
    tenant_id text        NOT NULL,
    id        uuid        NOT NULL,
    glob_id   uuid        NULL,
    box_id    text        NOT NULL CHECK (length(box_id) <= 200),
    action    text        NOT NULL CHECK (action IN ('add', 'remove', 'refused')),
    key       text        NOT NULL DEFAULT '' CHECK (length(key) <= 200),
    glob      text        NOT NULL DEFAULT '' CHECK (octet_length(glob) <= 1024),
    actor     text        NOT NULL,
    reason    text        NOT NULL DEFAULT '' CHECK (length(reason) <= 64),
    at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_file_stream_glob_audit PRIMARY KEY (tenant_id, id)
);
CREATE INDEX IF NOT EXISTS ix_file_stream_glob_audit_tenant_at
    ON file_stream_glob_audit (tenant_id, at, id);

CREATE TABLE IF NOT EXISTS file_stream_folders (
    tenant_id   text        NOT NULL,
    box_id      text        NOT NULL,
    path        text        NOT NULL CHECK (length(path) BETWEEN 1 AND 1024),
    state       text        NOT NULL CHECK (state IN ('allowed', 'refused')),
    reason      text        NOT NULL DEFAULT '' CHECK (length(reason) <= 200),
    reported_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_file_stream_folders PRIMARY KEY (tenant_id, box_id, path),
    CONSTRAINT fk_file_stream_folders_box FOREIGN KEY (tenant_id, box_id)
        REFERENCES boxes (tenant_id, box_id) ON DELETE CASCADE
);

ALTER TABLE file_stream_globs ENABLE ROW LEVEL SECURITY;
ALTER TABLE file_stream_globs FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON file_stream_globs;
CREATE POLICY tenant_scope ON file_stream_globs
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON file_stream_globs;
CREATE POLICY operator_scope ON file_stream_globs
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE file_stream_glob_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE file_stream_glob_audit FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON file_stream_glob_audit;
CREATE POLICY tenant_scope ON file_stream_glob_audit
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON file_stream_glob_audit;
CREATE POLICY operator_scope ON file_stream_glob_audit
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE file_stream_folders ENABLE ROW LEVEL SECURITY;
ALTER TABLE file_stream_folders FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON file_stream_folders;
CREATE POLICY tenant_scope ON file_stream_folders
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON file_stream_folders;
CREATE POLICY operator_scope ON file_stream_folders
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
