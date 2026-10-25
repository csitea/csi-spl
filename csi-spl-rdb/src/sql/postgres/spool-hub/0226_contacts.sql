-- 0226_contacts.sql - a person's contacts and the Google Contacts binding
-- (spec 154 v1.1 sections 2.6 and 3, build row B1, SPL-3256). Forward-only,
-- additive. The spec names 0223; 0223 and 0224 were taken on master first.
--
--   gcal_connections.granted_scopes  the scopes the Google grant holds (149's
--                                    connection asks the contacts scope too)
--   personal.contacts  the person's own list (owner O5 = B: one list per
--                      person, the same in every workspace). A table of spec
--                      119's realm (rdb 0168): person_id first with the FK
--                      to humans, no tenant_id, ENABLE + FORCE and the one
--                      policy person_scope, the exact text of 0168. No
--                      member, admin, workspace owner or operator reads it.
--   contacts_sync      one binding's sync state: a workspace table in the
--                      0187 shape (tenant_scope + operator_scope), no
--                      contact value. Its primary key human_id is "one
--                      binding per person"; its two FKs on (tenant_id,
--                      human_id) end it on a disconnect or a leave.
--
-- The 30-day purge of soft-deleted contacts reaches every person's rows, and
-- the operator scope reads none of them, so it goes through one SECURITY
-- DEFINER door, the realm's precedent (0168 personal.due_receipts):
--
--   spool_realm_contacts_purger  NOLOGIN NOBYPASSRLS; owns
--                      personal.purge_deleted_contacts(before): deletes the
--                      rows soft-deleted before `before` and returns each
--                      person once, with pending_google = a purged row held
--                      a member's delete never sent to Google. Column SELECT
--                      (person_id, deleted_at, deleted_by, google_resource)
--                      and DELETE on personal.contacts, its two policies on
--                      soft-deleted rows; no grant on any other table.
--
-- EXECUTE is revoked from PUBLIC; the migrator holds it WITH GRANT OPTION and
-- roles/runtime-grants.sql grants it, and the table, to the runtime by name.
-- No personal data, no secret.

ALTER TABLE gcal_connections
    ADD COLUMN IF NOT EXISTS granted_scopes text NOT NULL DEFAULT ''
        CHECK (length(granted_scopes) <= 2000);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_realm_contacts_purger') THEN
        BEGIN
            CREATE ROLE spool_realm_contacts_purger NOLOGIN NOBYPASSRLS;
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            NULL; -- created by a concurrent migrator of another database
        END;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_auth_members
                   WHERE roleid = 'spool_realm_contacts_purger'::regrole
                     AND member = current_user::regrole
                     AND set_option AND NOT inherit_option) THEN
        BEGIN
            GRANT spool_realm_contacts_purger TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
        EXCEPTION WHEN unique_violation THEN
            NULL; -- granted by a concurrent migrator of another database
        END;
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS personal.contacts (
    person_id       text        NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                                CHECK (person_id ~ '^HUM-[0-9]+$'),
    contact_id      uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    first_name      text        NOT NULL DEFAULT '' CHECK (length(first_name) <= 100),
    last_name       text        NOT NULL DEFAULT '' CHECK (length(last_name) <= 100),
    email           text        NULL
        CHECK (email IS NULL OR (email = lower(email) AND length(email) BETWEEN 3 AND 320)),
    phone           text        NULL
        CHECK (phone IS NULL OR phone ~ '^[+0-9 ().-]{3,40}$'),
    google_account  text        NULL
        CHECK (google_account IS NULL OR (google_account = lower(google_account) AND length(google_account) BETWEEN 3 AND 320)),
    google_resource text        NULL CHECK (google_resource IS NULL OR length(google_resource) <= 200),
    google_etag     text        NOT NULL DEFAULT '' CHECK (length(google_etag) <= 200),
    sync_hash       text        NULL CHECK (sync_hash IS NULL OR length(sync_hash) = 64),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz NULL,
    deleted_by      text        NULL CHECK (deleted_by IS NULL OR deleted_by IN ('member', 'google-sync')),
    CHECK ((google_account IS NULL) = (google_resource IS NULL)),
    CHECK (first_name <> '' OR last_name <> '' OR email IS NOT NULL OR phone IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS contacts_person ON personal.contacts (person_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS contacts_google ON personal.contacts (person_id, google_account, google_resource)
    WHERE google_resource IS NOT NULL;

ALTER TABLE personal.contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE personal.contacts FORCE ROW LEVEL SECURITY;
-- person_scope: the exact text of 0168 (TestRLSPersonalCatalogue pins it).
DROP POLICY IF EXISTS person_scope ON personal.contacts;
CREATE POLICY person_scope ON personal.contacts
    USING (person_id = NULLIF(current_setting('app.person_id', true), '')
           AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
           AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator')
    WITH CHECK (person_id = NULLIF(current_setting('app.person_id', true), '')
           AND NULLIF(current_setting('app.tenant_id', true), '') IS NULL
           AND current_setting('app.rls_scope', true) IS DISTINCT FROM 'operator');

-- The purger: USAGE + CREATE on the schema (CREATE only so the migrator, as
-- the role, can create its function; as 0168 for its two roles), and only
-- the columns its function touches.
GRANT USAGE, CREATE ON SCHEMA personal TO spool_realm_contacts_purger;
GRANT SELECT (person_id, deleted_at, deleted_by, google_resource), DELETE ON personal.contacts TO spool_realm_contacts_purger;

-- Its two policies, soft-deleted rows only. Permissive policies OR
-- together; these are TO spool_realm_contacts_purger alone.
DROP POLICY IF EXISTS realm_contacts_purger_read ON personal.contacts;
CREATE POLICY realm_contacts_purger_read ON personal.contacts FOR SELECT TO spool_realm_contacts_purger
    USING (deleted_at IS NOT NULL);
DROP POLICY IF EXISTS realm_contacts_purger_delete ON personal.contacts;
CREATE POLICY realm_contacts_purger_delete ON personal.contacts FOR DELETE TO spool_realm_contacts_purger
    USING (deleted_at IS NOT NULL);

-- As the owner role, then back to the migrator's own role: CREATE OR REPLACE
-- on a second run is the owner's own replace, never an OWNER TO.
DO $$
DECLARE
    me text := current_user;
BEGIN
    SET LOCAL ROLE spool_realm_contacts_purger;
    CREATE OR REPLACE FUNCTION personal.purge_deleted_contacts(before timestamptz)
        RETURNS TABLE (person_id text, pending_google boolean)
        LANGUAGE sql VOLATILE SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
    AS $fn$
        WITH gone AS (
            DELETE FROM personal.contacts c
            WHERE c.deleted_at IS NOT NULL AND c.deleted_at < purge_deleted_contacts.before
            RETURNING c.person_id, (c.deleted_by = 'member' AND c.google_resource IS NOT NULL) AS pending
        )
        SELECT g.person_id, bool_or(g.pending) FROM gone g
        GROUP BY g.person_id ORDER BY g.person_id
    $fn$;
    REVOKE ALL ON FUNCTION personal.purge_deleted_contacts(timestamptz) FROM PUBLIC;
    EXECUTE format('GRANT EXECUTE ON FUNCTION personal.purge_deleted_contacts(timestamptz) TO %I WITH GRANT OPTION', me);
    EXECUTE format('SET LOCAL ROLE %I', me);
END
$$;

-- The binding's sync state: a workspace table, no contact value.
CREATE TABLE contacts_sync (
    human_id         text        NOT NULL PRIMARY KEY,
    tenant_id        text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, human_id) REFERENCES gcal_connections (tenant_id, human_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, human_id) REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE,
    enabled          boolean     NOT NULL DEFAULT true,
    sync_token       text        NULL,
    out_cursor       timestamptz NULL,
    due_at           timestamptz NOT NULL DEFAULT now(),
    sync_lease_until timestamptz NULL,
    backoff_until    timestamptz NULL,
    status_detail    text        NOT NULL DEFAULT '' CHECK (length(status_detail) <= 500),
    last_synced_at   timestamptz NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX contacts_sync_due ON contacts_sync (due_at) WHERE enabled;

ALTER TABLE contacts_sync ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts_sync FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON contacts_sync
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON contacts_sync
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
