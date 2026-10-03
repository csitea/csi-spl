-- 0108_release_note.sql - the release notes table, one row per commit
-- (spec 065 section 4.2, build lane L3). Forward-only.
--
-- Owner, t1 a9df2f55: "Create proper release notes table , where each agent
-- must properly exlain first il lay non tecnical germs what their commit does
-- , how and why and than have the same questions in technical terms".
--
--   release_notes  one row per trunk commit: the six Lay-* / Tech-* trailers
--                  of its message (spec 4.1), the first v<X.Y.Z> tag that
--                  carries it, and a state (ok / missing / skip / revert /
--                  backfill). Written by the hub's deploy-time ingest (L4/L5),
--                  read by every signed-in user (Q11).
--
-- Estate-wide, NOT per tenant: every tenant runs the same code, so the table
-- has no tenant_id and no row security, like rbac_permissions (0021). It holds
-- no personal data; the ingest runs the distribution-hygiene filter on the
-- trailer text before a row is written (spec 3, option C).
--
-- Each CHECK is store/release_note.go's allowed set or shape; a store test
-- pins the two together. The runtime grants come from the default privileges
-- of spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that writes this table.

CREATE TABLE release_notes (
    sha          text        PRIMARY KEY CHECK (sha ~ '^[0-9a-f]{40}$'),
    version      text        NULL CHECK (version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$'),
    committed_at timestamptz NOT NULL,
    kind         text        NOT NULL DEFAULT '' CHECK (kind ~ '^[a-z]{0,16}$'),
    area         text        NOT NULL DEFAULT '' CHECK (length(area) <= 64),
    subject      text        NOT NULL CHECK (length(subject) BETWEEN 1 AND 300),
    lay_what     text        NOT NULL DEFAULT '' CHECK (length(lay_what) <= 500),
    lay_how      text        NOT NULL DEFAULT '' CHECK (length(lay_how) <= 500),
    lay_why      text        NOT NULL DEFAULT '' CHECK (length(lay_why) <= 500),
    tech_what    text        NOT NULL DEFAULT '' CHECK (length(tech_what) <= 500),
    tech_how     text        NOT NULL DEFAULT '' CHECK (length(tech_how) <= 500),
    tech_why     text        NOT NULL DEFAULT '' CHECK (length(tech_why) <= 500),
    state        text        NOT NULL CHECK (state IN ('ok', 'missing', 'skip', 'revert', 'backfill')),
    reverts      text        NULL CHECK (reverts ~ '^[0-9a-f]{40}$'),
    link         text        NOT NULL DEFAULT '' CHECK (link = '' OR (link ~ '^https://[^[:space:]]+$' AND length(link) <= 300)),
    ingested_at  timestamptz NOT NULL DEFAULT now()
);
-- The modal's page: versions newest first, compared as numbers (v7.10.0 is
-- newer than v7.9.0).
CREATE INDEX release_notes_version ON release_notes
    ((string_to_array(substr(version, 2), '.')::int[]) DESC, committed_at DESC)
    WHERE version IS NOT NULL;
