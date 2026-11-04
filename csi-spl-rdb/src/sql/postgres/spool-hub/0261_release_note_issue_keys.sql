-- 0261_release_note_issue_keys.sql - each release note names the issues its
-- commit message cites and the workspace that owns them (SPL-4789, spec 016).
-- Forward-only.
--
-- Owner HUM-10, t1 ef94396b (msg 61bf7791): an agent's commit "must add at
-- least 1 link for an issue , which was used to justify the work of the
-- commit and at least 1 discussion where this issue originated from and the
-- links must be clickable" in Reporting -> Releases.
--
--   issue_tenant  the workspace whose issues the keys are (the ingest sends
--                 it from cnf hub.commit_issue_tenant), NULL until a deploy's
--                 ingest re-sends the row
--   issue_keys    the keys of that workspace's issue prefix found in the
--                 message, subject first, then the body (Closes:, Refs:),
--                 de-duplicated, at most 20
--
-- The discussions are not copied here: the read joins issue_discussions of
-- issue_tenant, so a link added later shows without a re-ingest. The table
-- stays estate-wide; the keys are already public in the subject.
-- store/release_note.go's ReleaseIssueKeysMax and releaseIssueKeyRe are the
-- Go side of the CHECK; a store test pins them together.
-- Live-data safety: two ADD COLUMNs with constant defaults, no rewrite.
-- DEPLOY ORDER: apply BEFORE the hub that writes these columns.

ALTER TABLE release_notes
    ADD COLUMN issue_tenant text NULL CHECK (length(issue_tenant) BETWEEN 1 AND 64),
    ADD COLUMN issue_keys text[] NOT NULL DEFAULT '{}'
        CHECK (cardinality(issue_keys) <= 20
               AND array_to_string(issue_keys, ',') ~ '^([A-Z][A-Z0-9]{0,9}-[0-9]{1,9}(,|$))*$');
