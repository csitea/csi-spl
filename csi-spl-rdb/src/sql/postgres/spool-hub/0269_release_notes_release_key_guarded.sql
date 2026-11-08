-- 0269_release_notes_release_key_guarded.sql - the release key index of a hub
-- that scopes release notes by workspace (spec 171 section 3.3.1 step 4, spec
-- 143 releases-projects.md build row B-2, SPL-5108). Forward-only.
--
-- rdb 0114's index cast every version to int[], so a tag the relaxed CHECK of
-- 0267 admits ('v1.2.') failed the insert. This one leads on tenant_id and
-- casts only csi-spl's own shape, v<X.Y.Z>[-c<N>]; any other tag has a NULL key
-- and lists after the keyed versions (releaseKeySQL is the same expression).
--
-- release_notes_pkey (sha) stays: row B-3 swaps it, once this row's hub serves
-- dev and prd.
--
-- Live-data safety: the CI order is migrate, then the new revision, so between
-- the two the old hub's list matches this index neither on tenant_id nor on the
-- CASE and seq-scans (R7 of SPL-4983 on 9,348 notes, n=7: about 6 ms to 592 ms).
-- The build holds a write lock for its seconds on that table size; the
-- deploy-time ingest is the only writer.
-- DEPLOY ORDER: apply BEFORE the hub of row B-2.

DROP INDEX IF EXISTS release_notes_release_key;

CREATE INDEX release_notes_release_key ON release_notes (
    tenant_id,
    (CASE WHEN version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$'
          THEN array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1),
                    string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[]) END) DESC NULLS LAST,
    coalesce(released_at, committed_at) DESC,
    committed_at DESC,
    sha
) WHERE version IS NOT NULL;
