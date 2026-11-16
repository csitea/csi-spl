-- 0288_note_agent_ask.sql - the provenance of a note an agent adds on a
-- person's ask (spec 155 v1.5 section 2.11 and section 4, build row B11,
-- SPL-5708; owner HUM-10, t1 8c2954b3 msg 13772c97: "the agents shoud be
-- able to create a note for me when I ask"; poll 03dbcb6b OQ-1..OQ-5).
-- Forward-only, additive, idempotent: a second apply changes nothing.
--
--   added_by_agent    the acting agent as <agent>@<box>, e.g. a-1@box-a
--   ask_msg_id        the person's message that asked for the note
--   ask_workspace_id  the workspace that message lives in (plain text, no FK,
--                     like personal.note_links.workspace_id: a realm table
--                     has no tenant_id column and no FK to a workspace table)
--
-- All three are NULL on a note the person made and all three are set on a
-- note an agent made (notes_agent_ask_all_or_none). No unique index on
-- ask_msg_id: one ask may back several notes (OQ-3, "No restrictions.").
-- The person_scope policy of rdb 0225 and the table grant of
-- roles/runtime-grants.sql already cover the new columns.
--
-- Live-data safety: three nullable columns with no default are catalog-only;
-- the CHECKs scan a small table (at most 2 000 notes a person) under a short
-- lock. DEPLOY ORDER: apply BEFORE the hub that writes them (wf 20 does).

SET LOCAL lock_timeout = '5s';

ALTER TABLE personal.notes
    ADD COLUMN IF NOT EXISTS added_by_agent text NULL
        CONSTRAINT notes_added_by_agent_len CHECK (added_by_agent IS NULL OR length(added_by_agent) BETWEEN 1 AND 64),
    ADD COLUMN IF NOT EXISTS ask_msg_id uuid NULL,
    ADD COLUMN IF NOT EXISTS ask_workspace_id text NULL
        CONSTRAINT notes_ask_workspace_len CHECK (ask_workspace_id IS NULL OR length(ask_workspace_id) BETWEEN 1 AND 200);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'personal.notes'::regclass AND conname = 'notes_agent_ask_all_or_none') THEN
        ALTER TABLE personal.notes ADD CONSTRAINT notes_agent_ask_all_or_none CHECK (
            (added_by_agent IS NULL) = (ask_msg_id IS NULL)
            AND (added_by_agent IS NULL) = (ask_workspace_id IS NULL)
        );
    END IF;
END
$$;
