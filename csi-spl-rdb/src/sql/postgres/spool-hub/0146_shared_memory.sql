-- 0146_shared_memory.sql - the shared memory of the agents (spec 102 v1.0
-- section 12, task T020). Forward-only, idempotent (a second apply changes
-- nothing).
--
-- One memory per workspace in the hub, scoped to HOW TO WORK in the spool
-- hub: traps, commands, conventions. Not task state. An agent adds a lesson
-- with `spool memory add --title <t> --text <t>`; a lesson whose NORMALISED
-- title (store.LessonKey: lower case, runs of white space as one space,
-- trailing punctuation dropped) already exists is merged into it - the new
-- text appended once - instead of piling up a second row. Each seed reads
-- the index (`spool memory index`: titles and one line), never the bodies;
-- `spool memory show <title>` reads one.
--
--   title_key   the normalised title, the merge key
--   title       the title as its first writer spelled it
--   body        every distinct text added under the key, oldest first
--   merges      how many adds were merged into the first one
--   writer_box  the box that last changed the row (from the authenticated
--               hello; an audit column the client cannot choose)
--
-- The bounds are the Go checks' (store.CheckLesson, LessonBodyMax): a write
-- the hub would refuse is a 400 there, never a CHECK violation here.
-- Runtime grants: the default privileges of spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: before the hub that reads it (a hub without the table answers
-- the memory ops with 500 and nothing else changes).

CREATE TABLE IF NOT EXISTS shared_memory_lessons (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    title_key  text        NOT NULL CHECK (length(title_key) BETWEEN 1 AND 120),
    title      text        NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
    body       text        NOT NULL CHECK (length(body) BETWEEN 1 AND 16000),
    merges     integer     NOT NULL DEFAULT 0 CHECK (merges >= 0),
    writer_box text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, title_key)
);

-- RLS in the 0021 fail-closed NULLIF shape: a tenant reads and writes only
-- its own lessons; the operator scope (spool migrate) sees everything.
ALTER TABLE shared_memory_lessons ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_memory_lessons FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON shared_memory_lessons;
CREATE POLICY tenant_scope ON shared_memory_lessons
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON shared_memory_lessons;
CREATE POLICY operator_scope ON shared_memory_lessons
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
