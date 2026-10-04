-- 0114_release_note_cycle.sql - release_notes.version is the full release
-- key, cycle included (spec 065 section 4.2, owner t1 1c5b6d53). Forward-only.
--
-- Owner: "if the scheme reaches 9.9.9 than start all over , but from 1.0.1".
-- The mint (do_release_version) then claims tag v1.0.1-c2: cycle 1 is
-- v<X.Y.Z>, cycle N>=2 is v<X.Y.Z>-c<N> (the cycle lives in the tag name
-- only; /version and the WUI show plain X.Y.Z). release_notes.version keeps
-- that full tag, so cycle-2 v1.0.1-c2 rows never merge with cycle-1 v1.0.1
-- rows, and the modal pages newest first by cycle, then X.Y.Z.
--
-- store/release_note.go's releaseVersionRe and releaseKeySQL are the Go side
-- of this CHECK and index expression; a store test pins them together.
-- Every existing row is cycle 1 and passes the wider CHECK unchanged.
-- DEPLOY ORDER: apply BEFORE the first cycle-2 tag is ingested (after 9.9.9).

ALTER TABLE release_notes DROP CONSTRAINT release_notes_version_check;
ALTER TABLE release_notes ADD CONSTRAINT release_notes_version_check
    CHECK (version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$');

-- The modal's page: release keys newest first, compared as numbers
-- {cycle, X, Y, Z} (v1.0.1-c2 is newer than v9.9.9, v7.10.0 than v7.9.0).
DROP INDEX release_notes_version;
CREATE INDEX release_notes_release_key ON release_notes
    ((array_prepend(coalesce(substring(version from '-c([0-9]+)$')::int, 1),
                    string_to_array(substring(version from '^v([0-9.]+)'), '.')::int[])) DESC,
     committed_at DESC)
    WHERE version IS NOT NULL;
