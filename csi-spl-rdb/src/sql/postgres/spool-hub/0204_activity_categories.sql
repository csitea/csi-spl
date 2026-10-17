-- 0204_activity_categories.sql - the tree of activity categories, and the
-- work kind and category a spawn request carries (spec 143 sections 4.2,
-- 4.3, task T003, SPL-2347). Forward-only.
--
-- Owner HUM-10, token burn topic e8ae0aad: "not all tokens are equal"
-- (msg 1b2269f7), the tree "has to be expandable in the future" (msg
-- 52fddc9d). Seed: poll 2 of t1 af25a1f3 (msg a8bfcdd0), the 5 areas with
-- their sub-categories of spec 4.2.1.
--
-- activity_categories  one row per node, path notation 'parent/child'. A
--                      finer category is one INSERT, no code change. The
--                      parent is always the path minus its last segment
--                      (CHECK), so the tree cannot disagree with its paths.
--                      dimensions holds the node's defaults for the four
--                      splits (kind, class, role, issue); the seed names the
--                      work kind where the node implies one.
--                      Estate-wide: every scope reads, the operator writes.
-- fleet_asks.work_kind      the lane kind of do_spl_lane_mix; '' = not given.
-- fleet_asks.category_path  the category the dispatcher gave the request;
--                      NULL = not given, reported as 'uncategorised' (old
--                      rows are never backfilled). Spec 4.3 drafts it NOT
--                      NULL DEFAULT '' with the FK, but '' names no node, so
--                      every existing ask would break the FK: NULL is the
--                      FK's "no category".
--
-- Live-data safety: one new table of 16 rows; two constant-default columns
-- on fleet_asks (catalogue-only, no rewrite; the FK and CHECK scan it once
-- under an ACCESS EXCLUSIVE lock until COMMIT, ~1,300 rows). The running hub
-- names its fleet_asks columns, so the new ones stay at their defaults until
-- a hub writes them (spec 143 4.4).

CREATE TABLE activity_categories (
    category_path text        PRIMARY KEY CHECK (category_path ~ '^[a-z0-9_]+(/[a-z0-9_]+)*$'),
    parent_path   text        NULL REFERENCES activity_categories (category_path) ON DELETE CASCADE,
    title         text        NOT NULL CHECK (length(title) BETWEEN 1 AND 100),
    description   text        NOT NULL DEFAULT '' CHECK (length(description) <= 500),
    dimensions    jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(dimensions) = 'object'),
    is_active     boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT activity_categories_parent_check CHECK (
        parent_path IS NOT DISTINCT FROM NULLIF(regexp_replace(category_path, '/[^/]+$', ''), category_path))
);

CREATE INDEX activity_categories_parent ON activity_categories (parent_path);

ALTER TABLE activity_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_categories FORCE ROW LEVEL SECURITY;

CREATE POLICY activity_categories_read ON activity_categories
    FOR SELECT TO PUBLIC USING (true);

CREATE POLICY operator_scope ON activity_categories
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- Spec 4.2.1, parents before children (the FK). spool migrate runs under the
-- operator scope (rdb 0014).
INSERT INTO activity_categories (category_path, parent_path, title, description, dimensions) VALUES
    ('coding', NULL, 'Coding', 'Writing and changing code', '{}'),
    ('review', NULL, 'Review', 'Reviewing work and triaging gates', '{"kind": "review"}'),
    ('specs_and_docs', NULL, 'Specs and docs', 'Specs, plans and documentation', '{"kind": "specs_and_docs"}'),
    ('tests', NULL, 'Tests', 'Writing and running tests', '{"kind": "tests"}'),
    ('dispatch', NULL, 'Dispatch', 'Routing the owner''s work to lanes', '{"kind": "dispatch"}'),
    ('coding/simple', 'coding', 'Simple coding', 'Small bug fixes, routine edits, minor tweaks', '{"kind": "simple_coding"}'),
    ('coding/hard', 'coding', 'Hard coding', 'Complex features, algorithmic work, large refactors', '{"kind": "complex_coding"}'),
    ('coding/i18n', 'coding', 'Translations', 'Translations, locale sync, untranslated gates', '{"kind": "i18n"}'),
    ('review/r7', 'review', 'Peer review', 'R7 peer review rounds', '{"kind": "review"}'),
    ('review/gate', 'review', 'Gate triage', 'Pre-push verification, CI gate triage', '{"kind": "review"}'),
    ('specs_and_docs/spec', 'specs_and_docs', 'Specs', 'System architecture specs, spec-kit plans', '{"kind": "specs_and_docs"}'),
    ('specs_and_docs/doc', 'specs_and_docs', 'Docs', 'Developer guide, user manuals, release documentation', '{"kind": "specs_and_docs"}'),
    ('tests/unit', 'tests', 'Unit tests', 'Go, JS and TS unit tests', '{"kind": "tests"}'),
    ('tests/e2e', 'tests', 'End-to-end tests', 'Playwright e2e, integration verification', '{"kind": "tests"}'),
    ('dispatch/triage', 'dispatch', 'Triage', 'Topic triage, issue filing, owner clarification', '{"kind": "dispatch"}'),
    ('dispatch/placement', 'dispatch', 'Placement', 'Lane placement, queue scheduling', '{"kind": "dispatch"}');

ALTER TABLE fleet_asks ADD COLUMN work_kind text NOT NULL DEFAULT ''
    CHECK (work_kind IN ('', 'specs_and_docs', 'tests', 'simple_coding', 'complex_coding', 'i18n', 'secret', 'review', 'dispatch'));

ALTER TABLE fleet_asks ADD COLUMN category_path text NULL
    REFERENCES activity_categories (category_path);

CREATE INDEX fleet_asks_category ON fleet_asks (category_path) WHERE category_path IS NOT NULL;
