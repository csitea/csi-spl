-- 0267_release_notes_deploys_expand.sql - the expand half of scoping commits
-- and deploys by workspace and repo (spec 171 section 3.3.0 Step A, with
-- spec 143 releases-projects.md v0.2.0 section 4.3; build row B-1, SPL-4983).
-- Forward-only.
--
-- The hub that runs when this applies still writes ON CONFLICT (sha) and reads
-- both tables with no scope. So this file keeps release_notes_pkey (sha), adds
-- no foreign key and turns on no row security: the contract migration (row
-- B-3, Step C) does those once row B-2's hub serves dev and prd. Until then
-- the pkey on sha holds, so no workspace but t1 may register or sync, and
-- `EXPECT_RLS=1 do_spl_db_rls_check` exits 4 on release_notes by design.
--
--   tenant_id, repo_slug    default to t1's one repo, so the old hub's inserts
--                           and every existing row land there.
--   release_notes_tenant_repo_sha  a UNIQUE INDEX, not a UNIQUE constraint:
--                           B-3's ADD PRIMARY KEY USING INDEX refuses an index
--                           that belongs to a constraint.
--   body                    a trailer-free commit's message (A6, spec 171 Q4).
--   issue_tenant            the rows no ingest has re-sent yet name t1.
--   the version and component CHECKs  another repo tags and deploys in its own
--                           shape; the Go side narrows them until B-2.
--   release_notes_release_key  rebuilt with the key guarded, or a tag like
--                           'v1.2.' fails its int[] cast and refuses the row.
--
-- Live-data safety: ADD COLUMN with constant defaults does not rewrite; the
-- UPDATE, the index builds and the CHECK scans hold their locks for this one
-- transaction, on tables of one row per commit and per deploy.
-- DEPLOY ORDER: apply BEFORE the hub of row B-2 (the CI order: migrate, then
-- the new revision). The old hub is unaffected except its release key order no
-- longer matches the rebuilt index: it sorts those rows itself.

ALTER TABLE release_notes
    ADD COLUMN tenant_id text NOT NULL DEFAULT 't1',
    ADD COLUMN repo_slug text NOT NULL DEFAULT 'csitea/csi-spl',
    ADD COLUMN body      text NOT NULL DEFAULT '' CHECK (length(body) <= 2000);

UPDATE release_notes SET issue_tenant = 't1' WHERE issue_tenant IS NULL;

CREATE UNIQUE INDEX release_notes_tenant_repo_sha ON release_notes (tenant_id, repo_slug, sha);
CREATE INDEX release_notes_tenant_repo_time ON release_notes (tenant_id, repo_slug, committed_at DESC);

ALTER TABLE release_notes DROP CONSTRAINT release_notes_version_check;
ALTER TABLE release_notes ADD CONSTRAINT release_notes_version_check
    CHECK (version IS NULL OR (length(version) BETWEEN 1 AND 64 AND version ~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'));

DROP INDEX IF EXISTS release_notes_release_key;
CREATE INDEX release_notes_release_key ON release_notes (
    tenant_id,
    (CASE
        WHEN version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$'
        THEN array_prepend(
            coalesce(substring(version from '-c([0-9]+)$')::int, 1),
            string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]
        )
    END) DESC NULLS LAST,
    coalesce(released_at, committed_at) DESC,
    committed_at DESC,
    sha
) WHERE version IS NOT NULL;
CREATE INDEX release_notes_tenant_released_idx ON release_notes (
    tenant_id,
    coalesce(released_at, committed_at) DESC,
    committed_at DESC
) WHERE version IS NOT NULL;

ALTER TABLE estate_deploys
    ADD COLUMN tenant_id text NOT NULL DEFAULT 't1',
    ADD COLUMN repo_slug text NOT NULL DEFAULT 'csitea/csi-spl';

CREATE INDEX estate_deploys_tenant_deployed_idx ON estate_deploys (tenant_id, deployed_at DESC);
CREATE INDEX estate_deploys_tenant_env_comp_idx ON estate_deploys (tenant_id, env, component, deployed_at DESC);

ALTER TABLE estate_deploys DROP CONSTRAINT estate_deploys_component_check;
ALTER TABLE estate_deploys ADD CONSTRAINT estate_deploys_component_check
    CHECK (component ~ '^[a-z0-9][a-z0-9_-]{0,31}$');
ALTER TABLE estate_deploys DROP CONSTRAINT estate_deploys_version_check;
ALTER TABLE estate_deploys ADD CONSTRAINT estate_deploys_version_check
    CHECK (version = '' OR (length(version) BETWEEN 1 AND 64 AND version ~ '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$'));
