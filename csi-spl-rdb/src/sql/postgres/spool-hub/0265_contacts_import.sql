-- 0265_contacts_import.sql - a contact's main attributes and its picture
-- (spec 154 v1.3 sections 11.3 and 11.4, build row B13, SPL-4909).
-- Forward-only, additive.
--
--   personal.contacts  gains company, job_title, birthday, notes (the owner's
--                      O6 = A) and in_only: true when a value from Google
--                      was over a cap and stored cut, so the sync's Out half
--                      never writes that person back. The CHECK "at least
--                      one of the four" of 0226 stays as it is.
--                      birthday is YYYY-MM-DD, or --MM-DD without a year;
--                      the spec's CHECK text ([0-9]{4}|--)-... would take
--                      ---MM-DD instead, so the dash sits inside the group.
--   personal.contact_photos  one picture per contact, the bytes in the row
--                      (64 KiB cap): a table of spec 119's realm (rdb 0168),
--                      person_id first with the FK to humans, no tenant_id,
--                      ENABLE + FORCE and the one policy person_scope, the
--                      exact text of 0168. No member, admin, workspace owner
--                      or operator reads it, and no realm role holds a grant
--                      on it: the purge door's DELETE of a contact takes the
--                      picture by the FK's ON DELETE CASCADE, which Postgres
--                      runs as the table owner and outside its row policies
--                      (TestRLSContactsPhotoPurge, case C38).
--
-- roles/runtime-grants.sql grants the new table to the runtime by name.
-- No personal data, no secret.

ALTER TABLE personal.contacts
    ADD COLUMN IF NOT EXISTS company   text    NOT NULL DEFAULT '' CHECK (length(company) <= 200),
    ADD COLUMN IF NOT EXISTS job_title text    NOT NULL DEFAULT '' CHECK (length(job_title) <= 200),
    ADD COLUMN IF NOT EXISTS birthday  text    NULL
        CHECK (birthday IS NULL OR birthday ~ '^([0-9]{4}-|--)[0-9]{2}-[0-9]{2}$'),
    ADD COLUMN IF NOT EXISTS notes     text    NOT NULL DEFAULT '' CHECK (length(notes) <= 8000),
    ADD COLUMN IF NOT EXISTS in_only   boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS personal.contact_photos (
    person_id       text        NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                                CHECK (person_id ~ '^HUM-[0-9]+$'),
    contact_id      uuid        NOT NULL PRIMARY KEY
                                REFERENCES personal.contacts (contact_id) ON DELETE CASCADE,
    mime            text        NOT NULL CHECK (mime IN ('image/png', 'image/jpeg', 'image/webp')),
    bytes           bytea       NOT NULL CHECK (octet_length(bytes) BETWEEN 1 AND 65536),
    sha256          text        NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    source_url_hash text        NOT NULL CHECK (source_url_hash ~ '^[0-9a-f]{64}$'),
    fetched_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS contact_photos_person ON personal.contact_photos (person_id);

ALTER TABLE personal.contact_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE personal.contact_photos FORCE ROW LEVEL SECURITY;
-- person_scope: the exact text of 0168 (TestRLSPersonalCatalogue pins it).
DROP POLICY IF EXISTS person_scope ON personal.contact_photos;
CREATE POLICY person_scope ON personal.contact_photos
    USING (person_id = NULLIF(current_setting('app.person_id', true), '')
           AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
           AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
    WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
           AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
           AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator');
