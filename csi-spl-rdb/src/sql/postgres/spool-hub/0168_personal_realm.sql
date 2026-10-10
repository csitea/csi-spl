-- 0168_personal_realm.sql - the personal realm (spec 119 v1.1 sections 7.3..7.5
-- and 8.1..8.3, tasks.md T001). Forward-only, additive, idempotent: the whole
-- file can run a second time and changes nothing. Owner HUM-10, t1 151d85fc.
-- Builds on 118 Q5 A (no span columns) and Q6 A (rev, last_open_from).
--
-- A person-level layer ABOVE the workspaces, in its own schema `personal`:
--
--   profile         time zone, locale, communication preferences (7.3; the
--                   name stays humans.display_name, OQ-10 A)
--   settings        the hours limits, one row per valid_from (118 C3)
--   hours_receipts  read-only copies of one's own past hours after leaving a
--                   workspace: hours only, never content (8.2 = 118 D4)
--   receipt_due     one row per (person, workspace) left, open while the last
--                   period may still become final (8.3)
--
-- Every table: person_id first (FK to humans, ON DELETE CASCADE), no column
-- named tenant_id and no FK to a table carrying one, so no tenant gate or
-- copied policy mistakes it for a workspace table. ENABLE + FORCE row level
-- security and ONE policy, person_scope (7.4): the row's person is the
-- session's app.person_id (NULLIF: unset or '' matches nothing), AND
-- app.tenant_id is unset (a workspace scope reads 0 realm rows and writes
-- none), AND not the operator scope. No operator_scope policy: asOperator
-- reads 0 realm rows (OQ-1 A).
--
-- Two NOLOGIN NOBYPASSRLS roles own the realm's two SECURITY DEFINER doors
-- (the rdb 0143 spool_search_reader precedent: the migrator is a member WITH
-- INHERIT FALSE, SET TRUE, so it can create a function as the role but never
-- holds its privileges by inheritance; nobody logs in as either):
--
--   spool_realm_sweeper  owns personal.due_receipts(now): the open
--                        receipt_due rows that are due, as (person_id,
--                        workspace_id) only. Column SELECT on receipt_due and
--                        the one sweeper policy; no grant on any other table.
--   spool_realm_eraser   owns personal.delete_my_receipts(workspace_id) (8.3,
--                        OQ-4 A): the one way a receipt row is removed, by its
--                        own person. It reads app.person_id itself, refuses
--                        an unset / '' / malformed one, a set app.tenant_id
--                        and the operator scope (42501), deletes every rev of
--                        that person's rows of that workspace and closes the
--                        receipt_due row. It has no policy of its own: the
--                        person_scope policy binds it too.
--
-- EXECUTE on both is revoked from PUBLIC; the migrator holds it WITH GRANT
-- OPTION, so roles/runtime-grants.sql (run as the owner after every migrate)
-- grants it, and the realm's table grants, to the runtime login by name. No
-- default privileges in `personal`: a later realm table is invisible to the
-- hub until it is granted by name (7.5).
--
-- No back-fill (OQ-9 A): the tables start empty. No personal data, no secret.

DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['spool_realm_sweeper', 'spool_realm_eraser'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            BEGIN
                EXECUTE format('CREATE ROLE %I NOLOGIN NOBYPASSRLS', r);
            EXCEPTION WHEN duplicate_object OR unique_violation THEN
                NULL; -- created by a concurrent migrator of another database
            END;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_auth_members
                       WHERE roleid = r::regrole
                         AND member = current_user::regrole
                         AND set_option AND NOT inherit_option) THEN
            BEGIN
                EXECUTE format('GRANT %I TO CURRENT_USER WITH INHERIT FALSE, SET TRUE', r);
            EXCEPTION WHEN unique_violation THEN
                NULL; -- granted by a concurrent migrator of another database
            END;
        END IF;
    END LOOP;
END
$$;

CREATE SCHEMA IF NOT EXISTS personal;
REVOKE ALL ON SCHEMA personal FROM PUBLIC;

CREATE TABLE IF NOT EXISTS personal.profile (
    person_id  text        NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                           CHECK (person_id ~ '^HUM-[0-9]+$'),
    time_zone  text        NULL CHECK (length(time_zone) BETWEEN 1 AND 64),
    locale     text        NULL CHECK (length(locale) BETWEEN 1 AND 35),
    comm_prefs jsonb       NOT NULL DEFAULT '{}'
                           CHECK (jsonb_typeof(comm_prefs) = 'object' AND octet_length(comm_prefs::text) <= 4096),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id)
);

CREATE TABLE IF NOT EXISTS personal.settings (
    person_id                text        NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                                         CHECK (person_id ~ '^HUM-[0-9]+$'),
    valid_from               date        NOT NULL,
    hours_limit_day_minutes  integer     NULL CHECK (hours_limit_day_minutes BETWEEN 60 AND 1440),
    hours_limit_week_minutes integer     NULL CHECK (hours_limit_week_minutes BETWEEN 60 AND 10080),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, valid_from)
);

CREATE TABLE IF NOT EXISTS personal.hours_receipts (
    person_id      text        NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                               CHECK (person_id ~ '^HUM-[0-9]+$'),
    workspace_id   text        NOT NULL CHECK (length(workspace_id) BETWEEN 1 AND 200),
    workspace_name text        NOT NULL CHECK (length(workspace_name) <= 200),
    day            date        NOT NULL,
    minutes        integer     NOT NULL CHECK (minutes BETWEEN 0 AND 1440),
    label          text        NOT NULL CHECK (length(label) BETWEEN 1 AND 200),
    kind           text        NOT NULL CHECK (kind IN ('work', 'travel', 'wait', 'absence')),
    period_start   date        NOT NULL,
    period_end     date        NOT NULL,
    approval_state text        NOT NULL CHECK (approval_state IN ('open', 'approved', 'frozen', 'final', 'returned')),
    approver_name  text        NULL CHECK (length(approver_name) <= 200),
    decided_at     timestamptz NULL,
    rev            smallint    NOT NULL DEFAULT 0 CHECK (rev IN (0, 1)),
    copied_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, workspace_id, day, label, kind, rev),
    CHECK (period_end >= period_start AND day BETWEEN period_start AND period_end)
);

CREATE TABLE IF NOT EXISTS personal.receipt_due (
    person_id      text        NOT NULL REFERENCES public.humans (human_id) ON DELETE CASCADE
                               CHECK (person_id ~ '^HUM-[0-9]+$'),
    workspace_id   text        NOT NULL CHECK (length(workspace_id) BETWEEN 1 AND 200),
    reason         text        NOT NULL CHECK (reason IN ('removed', 'access_until', 'workspace_deleted')),
    due_at         timestamptz NOT NULL DEFAULT now(),
    last_open_from date        NULL,
    done_at        timestamptz NULL,
    PRIMARY KEY (person_id, workspace_id)
);
CREATE INDEX IF NOT EXISTS receipt_due_open ON personal.receipt_due (due_at) WHERE done_at IS NULL;

-- 7.4: the one policy, the same on every table.
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['profile', 'settings', 'hours_receipts', 'receipt_due'] LOOP
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

-- The definer owners: USAGE + CREATE on the schema (CREATE only so the
-- migrator, as the role, can create the role's function; P0 G7 of rdb 0143),
-- and only the columns their function touches.
GRANT USAGE, CREATE ON SCHEMA personal TO spool_realm_sweeper, spool_realm_eraser;
GRANT SELECT (person_id, workspace_id, due_at, done_at) ON personal.receipt_due TO spool_realm_sweeper;
GRANT SELECT (person_id, workspace_id), DELETE ON personal.hours_receipts TO spool_realm_eraser;
GRANT SELECT (person_id, workspace_id, done_at), UPDATE (done_at) ON personal.receipt_due TO spool_realm_eraser;

-- As each owner role, then back to the migrator's own role: CREATE OR
-- REPLACE on the second run is the owner's own replace, never an OWNER TO.
DO $$
DECLARE
    me text := current_user;
BEGIN
    SET LOCAL ROLE spool_realm_sweeper;
    CREATE OR REPLACE FUNCTION personal.due_receipts(now timestamptz)
        RETURNS TABLE (person_id text, workspace_id text)
        LANGUAGE sql STABLE SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
    AS $fn$
        SELECT d.person_id, d.workspace_id FROM personal.receipt_due d
        WHERE d.done_at IS NULL AND d.due_at <= now
        ORDER BY d.due_at, d.person_id, d.workspace_id
    $fn$;
    REVOKE ALL ON FUNCTION personal.due_receipts(timestamptz) FROM PUBLIC;
    EXECUTE format('GRANT EXECUTE ON FUNCTION personal.due_receipts(timestamptz) TO %I WITH GRANT OPTION', me);
    EXECUTE format('SET LOCAL ROLE %I', me);

    SET LOCAL ROLE spool_realm_eraser;
    CREATE OR REPLACE FUNCTION personal.delete_my_receipts(workspace_id text)
        RETURNS integer
        LANGUAGE plpgsql VOLATILE SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
        p text := NULLIF(current_setting('app.person_id', true), '');
        n integer;
    BEGIN
        IF p IS NULL OR p !~ '^HUM-[0-9]+$'
           OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL
           OR current_setting('app.rls_scope', true) IS NOT DISTINCT FROM 'operator' THEN
            RAISE EXCEPTION 'delete_my_receipts: the person scope only'
                USING ERRCODE = 'insufficient_privilege';
        END IF;
        DELETE FROM personal.hours_receipts r
        WHERE r.person_id = p AND r.workspace_id = delete_my_receipts.workspace_id;
        GET DIAGNOSTICS n = ROW_COUNT;
        UPDATE personal.receipt_due d SET done_at = now()
        WHERE d.person_id = p AND d.workspace_id = delete_my_receipts.workspace_id AND d.done_at IS NULL;
        RETURN n;
    END
    $fn$;
    REVOKE ALL ON FUNCTION personal.delete_my_receipts(text) FROM PUBLIC;
    EXECUTE format('GRANT EXECUTE ON FUNCTION personal.delete_my_receipts(text) TO %I WITH GRANT OPTION', me);
    EXECUTE format('SET LOCAL ROLE %I', me);
END
$$;

-- 8.1: the sweeper's one policy, read-only, open rows only. Permissive
-- policies OR together; this one is TO spool_realm_sweeper alone.
DROP POLICY IF EXISTS realm_sweeper_read ON personal.receipt_due;
CREATE POLICY realm_sweeper_read ON personal.receipt_due FOR SELECT TO spool_realm_sweeper
    USING (done_at IS NULL);
