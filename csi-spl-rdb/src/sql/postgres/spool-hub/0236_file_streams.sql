-- 0237_file_streams.sql - the hub half of spec 160 file streams (row B2,
-- SPL-3888; owner HUM-10, t1 c168784c, GO msgs 44ec2e44 and 5c6686f2).
-- Forward-only, additive, idempotent. The spec names "the next free number
-- at build time": 0234 and 0235 were on master, 0236 held by another lane.
--
--   file_streams       one row per (workspace, box, stream key) a box
--                      announced: its path as the box's cnf names it (never
--                      resolved), its state (following | missing | refused |
--                      gone), when its last line came, and running counts.
--                      lines_kept / bytes_kept are the lines of the stream
--                      the hub holds now and their text bytes: the push
--                      keeps them in the same transaction as its insert and
--                      its prune, so the workspace caps (spec 160 3.7: 500 000
--                      lines, 256 MiB of text) are a sum over a few rows,
--                      never a count over the lines. redactions is the
--                      per-kind count the box's masking removed; never what
--                      was removed.
--   file_stream_lines  one masked line: (tenant, stream, seq) is its key, so
--                      a push re-sent after a lost ack stores nothing twice.
--                      search_tsv is a STORED generated column in
--                      spool_search, the shape of rdb 0227, so a word matches
--                      a log line as it matches a message (row B4 reads it).
--                      (tenant_id, at) serves the prune of the workspace's
--                      oldest lines and the retention sweep (row B6).
--
-- No GIN: the table is FORCE RLS and ts_match_vq is not LEAKPROOF (rdb 0122,
-- 0227). RLS: the 0187 shape, tenant_scope with NULLIF + operator_scope; a
-- statement without a tenant reads and writes no row (spec 160 C30). The
-- runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, as every table since 017. A box's
-- lines are masked on the box before they leave it (spec 160 3.1); the hub
-- stores what the box sends. No secret, no personal data by design.
-- DEPLOY ORDER: wf 20 applies this file before it rolls the hub that writes
-- either table.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS file_streams (
    tenant_id     text        NOT NULL,
    id            uuid        NOT NULL,
    box_id        text        NOT NULL,
    stream_key    text        NOT NULL CHECK (stream_key ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    path          text        NOT NULL CHECK (length(path) BETWEEN 1 AND 1024),
    state         text        NOT NULL CHECK (state IN ('following', 'missing', 'refused', 'gone')),
    reason        text        NOT NULL DEFAULT '' CHECK (length(reason) <= 200),
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    announced_at  timestamptz NOT NULL DEFAULT now(),
    last_line_at  timestamptz NULL,
    last_seq      bigint      NOT NULL DEFAULT 0 CHECK (last_seq >= 0),
    lines_total   bigint      NOT NULL DEFAULT 0 CHECK (lines_total >= 0),
    lines_dropped bigint      NOT NULL DEFAULT 0 CHECK (lines_dropped >= 0),
    lines_kept    bigint      NOT NULL DEFAULT 0 CHECK (lines_kept >= 0),
    bytes_kept    bigint      NOT NULL DEFAULT 0 CHECK (bytes_kept >= 0),
    redactions    jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(redactions) = 'object'),
    CONSTRAINT pk_file_streams PRIMARY KEY (tenant_id, id),
    CONSTRAINT uq_file_streams_box_key UNIQUE (tenant_id, box_id, stream_key),
    CONSTRAINT fk_file_streams_box FOREIGN KEY (tenant_id, box_id)
        REFERENCES boxes (tenant_id, box_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS file_stream_lines (
    tenant_id  text        NOT NULL,
    stream_id  uuid        NOT NULL,
    seq        bigint      NOT NULL CHECK (seq > 0),
    at         timestamptz NOT NULL,
    text       text        NOT NULL CHECK (octet_length(text) <= 2080),
    marker     boolean     NOT NULL DEFAULT false,
    search_tsv tsvector    GENERATED ALWAYS AS (to_tsvector('spool_search'::regconfig, text)) STORED,
    CONSTRAINT pk_file_stream_lines PRIMARY KEY (tenant_id, stream_id, seq),
    CONSTRAINT fk_file_stream_lines_stream FOREIGN KEY (tenant_id, stream_id)
        REFERENCES file_streams (tenant_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ix_file_stream_lines_tenant_at
    ON file_stream_lines (tenant_id, at, stream_id, seq);

ALTER TABLE file_streams ENABLE ROW LEVEL SECURITY;
ALTER TABLE file_streams FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON file_streams;
CREATE POLICY tenant_scope ON file_streams
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON file_streams;
CREATE POLICY operator_scope ON file_streams
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE file_stream_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE file_stream_lines FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON file_stream_lines;
CREATE POLICY tenant_scope ON file_stream_lines
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON file_stream_lines;
CREATE POLICY operator_scope ON file_stream_lines
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
