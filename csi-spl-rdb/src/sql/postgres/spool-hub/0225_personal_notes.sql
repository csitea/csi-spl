-- 0225_personal_notes.sql - the Notes section's three realm tables (spec 155
-- v1.1 section 4, build row B2; SPL-3257). Forward-only, additive,
-- idempotent: the whole file can run a second time and changes nothing.
--
-- A note is its writer's own and the same list shows in every workspace the
-- person belongs to (D1), so the notes live in spec 119's personal realm
-- (rdb 0168) and follow its rule exactly:
--
--   notes       title, body, pinned, the person's own order, archived_at
--   note_items  a note's checklist lines (D6)
--   note_links  a note's typed refs (D7, spec 2.3): msg, topic, issue,
--               event, doc and channel carry their workspace; url carries
--               none and only an http(s) address
--
-- Every table: person_id first (FK to humans, ON DELETE CASCADE: the account
-- erase reaches the notes), no column named tenant_id and no FK to a table
-- carrying one (note_links.workspace_id is plain text, like
-- personal.receipt_due's). ENABLE + FORCE row level security and the one
-- person_scope policy of 0168, quoted here, so a workspace scope, the
-- operator scope and an unset person read 0 rows and write none.
--
-- The runtime gets SELECT, INSERT, UPDATE, DELETE on the three by name in
-- roles/runtime-grants.sql: no default privileges in `personal`. No new role,
-- no function: the 2 000-note cap is the store's, in the insert's
-- transaction. The tables start empty. No personal data, no secret.

CREATE TABLE IF NOT EXISTS personal.notes (
    person_id   text             NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                                 CHECK (person_id ~ '^HUM-[0-9]+$'),
    note_id     uuid             NOT NULL DEFAULT gen_random_uuid(),
    title       text             NOT NULL DEFAULT '' CHECK (length(title) <= 200),
    body        text             NOT NULL DEFAULT '' CHECK (length(body) <= 20000),
    pinned      boolean          NOT NULL DEFAULT false,
    position    double precision NOT NULL,
    archived_at timestamptz      NULL,
    created_at  timestamptz      NOT NULL DEFAULT now(),
    updated_at  timestamptz      NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, note_id)
);

CREATE TABLE IF NOT EXISTS personal.note_items (
    person_id text             NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                               CHECK (person_id ~ '^HUM-[0-9]+$'),
    note_id   uuid             NOT NULL,
    item_id   uuid             NOT NULL DEFAULT gen_random_uuid(),
    text      text             NOT NULL CHECK (length(text) <= 500),
    done      boolean          NOT NULL DEFAULT false,
    position  double precision NOT NULL,
    PRIMARY KEY (person_id, note_id, item_id),
    FOREIGN KEY (person_id, note_id) REFERENCES personal.notes (person_id, note_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS personal.note_links (
    person_id    text             NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                                  CHECK (person_id ~ '^HUM-[0-9]+$'),
    note_id      uuid             NOT NULL,
    link_id      uuid             NOT NULL DEFAULT gen_random_uuid(),
    kind         text             NOT NULL CHECK (kind IN ('msg', 'topic', 'issue', 'event', 'doc', 'channel', 'url')),
    workspace_id text             NULL CHECK (length(workspace_id) BETWEEN 1 AND 200),
    ref          text             NOT NULL CHECK (length(ref) BETWEEN 1 AND 2048),
    day          date             NULL,
    label        text             NOT NULL DEFAULT '' CHECK (length(label) <= 200),
    position     double precision NOT NULL,
    created_at   timestamptz      NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, note_id, link_id),
    FOREIGN KEY (person_id, note_id) REFERENCES personal.notes (person_id, note_id) ON DELETE CASCADE,
    CONSTRAINT note_links_url_no_workspace CHECK ((kind = 'url') = (workspace_id IS NULL)),
    CONSTRAINT note_links_url_http CHECK (kind <> 'url' OR ref ~ '^https?://'),
    CONSTRAINT note_links_event_day CHECK ((kind = 'event') = (day IS NOT NULL))
);

-- 0168 7.4: the one policy, the same on every realm table.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['notes', 'note_items', 'note_links'] LOOP
        EXECUTE format('ALTER TABLE personal.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE personal.%I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS person_scope ON personal.%I', t);
        EXECUTE format($p$CREATE POLICY person_scope ON personal.%I
            USING (person_id = NULLIF(current_setting('app.person_id', true), '')
                   AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                   AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
            WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
                   AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
                   AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')$p$, t);
    END LOOP;
END
$$;
