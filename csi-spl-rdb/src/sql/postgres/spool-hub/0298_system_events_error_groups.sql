-- 0298_system_events_error_groups.sql - backend errors into the System log:
-- one row per error group, and the box reader's cursor (spec 162 v1.2
-- section 10.5, build row T2, SPL-5882 / SPL-6000). Forward-only, additive,
-- idempotent (a second apply changes nothing).
--
-- Owner HUM-10, t1 bfd5af01 (msg 0b7c9534): "we need a mechanism how-to trap
-- errors from the backend, collect and report them"; poll 00d28227 answer 4
-- (msg 4dda13ce): "Also in the Mine log of the person whose request failed".
--
--   system_events         gains the group columns. An error group is one
--                         row for life, keyed by its fingerprint (16 hex of
--                         evlog.Fingerprint): a new sighting adds to n and
--                         moves at, it never adds a row (store/
--                         log_events_postgres.go, UpsertSystemErrorGroup).
--                         A row that is not a group keeps fingerprint '',
--                         first_at NULL and n 1; the existing rows are such
--                         rows and are not grouped.
--     fingerprint         '' or 16 lowercase hex; unique when set.
--     first_at            the group's first sighting; NULL for a plain row.
--     n                   the sightings counted, >= 1.
--     issue_key           the issue filed for the group ('' = none) and
--     issue_n             n when it was linked (spec 162 10.7).
--     human_id            the person of the last sighting that had one, ''
--                         for none (Q4 B). No foreign key to humans: a group
--                         outlives a deleted person, and the trim keeps the
--                         table small.
--   system_events_cursor  one row per env: how far the box reader has read
--                         Cloud Logging (read_until) and its generation
--                         (gen). A reader's put is a compare-and-set on
--                         both (10.4.4), so two boxes reading one hour
--                         count it once. Hub-wide like system_events, no
--                         tenant_id, outside RLS.
--
-- Live-data safety: system_events gains columns with constant defaults (no
-- table rewrite on PostgreSQL 11+) and one partial unique index over the
-- rows with a fingerprint, which no row has yet. The cursor table is new and
-- empty. Runtime grants: the default privileges of
-- spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: wf 20 applies this file before it rolls the hub that writes
-- the new columns (spec 162 row T3).

SET LOCAL lock_timeout = '5s';

ALTER TABLE system_events
    ADD COLUMN IF NOT EXISTS fingerprint text        NOT NULL DEFAULT ''
        CONSTRAINT ck_system_events_fingerprint CHECK (fingerprint ~ '^([0-9a-f]{16})?$'),
    ADD COLUMN IF NOT EXISTS first_at    timestamptz,
    ADD COLUMN IF NOT EXISTS n           integer     NOT NULL DEFAULT 1
        CONSTRAINT ck_system_events_n CHECK (n >= 1),
    ADD COLUMN IF NOT EXISTS issue_key   text        NOT NULL DEFAULT ''
        CONSTRAINT ck_system_events_issue_key CHECK (issue_key ~ '^([A-Z][A-Z0-9]*-[0-9]+)?$' AND length(issue_key) <= 40),
    ADD COLUMN IF NOT EXISTS issue_n     integer     NOT NULL DEFAULT 0
        CONSTRAINT ck_system_events_issue_n CHECK (issue_n >= 0),
    ADD COLUMN IF NOT EXISTS human_id    text        NOT NULL DEFAULT ''
        CONSTRAINT ck_system_events_human_id CHECK (human_id ~ '^(HUM-[0-9]+)?$' AND length(human_id) <= 32);

CREATE UNIQUE INDEX IF NOT EXISTS ux_system_events_fingerprint
    ON system_events (fingerprint) WHERE fingerprint <> '';

CREATE TABLE IF NOT EXISTS system_events_cursor (
    env        text        PRIMARY KEY CHECK (env IN ('dev', 'prd')),
    read_until timestamptz NOT NULL,
    gen        bigint      NOT NULL DEFAULT 0 CHECK (gen >= 0),
    by_actor   text        NOT NULL DEFAULT '' CHECK (length(by_actor) <= 64)
);
