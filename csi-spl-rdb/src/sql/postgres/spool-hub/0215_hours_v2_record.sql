-- 0215_hours_v2_record.sql - hours v2 record tables (spec 107 v2.3, task
-- T022, SPL-3104; FR-32, FR-33, FR-35, FR-40). Forward-only.
--
--   hours_days         the day record, one row per (member, day): start,
--                      end, break minutes, the standard day in force, the
--                      no-break mark and a source per field (FR-32). Written
--                      at approval and by the sweep, never on read.
--   hours_changes      the change log (FR-33 as owner Q21): who (a member, a
--                      terminal or the sweep), when, what object and key,
--                      before, after, why. Append-only in the database.
--   hours_adjustments  a correction after the final approval (FR-40): it
--                      lands in the member's next open period, signed
--                      minutes, a required reason. A paid period is never
--                      rewritten.
--   hours_ops          the offline queue's operation ids (FR-35): a replayed
--                      op_id reads as seen. Pruned at 45 days (T029).
--
-- No money (FR-19): no rate, amount or cost column. Every table in the 3.2
-- shape: tenant_id first (FK, ON DELETE CASCADE), ENABLE + FORCE row level
-- security, tenant_scope with the NULLIF guard (an unset or '' workspace
-- reads 0 rows and writes none), operator_scope. The runtime grants come
-- from the default privileges of spool-hub-roles/runtime-grants.sql.
--
-- hours_changes is append-only in the 0203 shape: a BEFORE UPDATE OR DELETE
-- trigger refuses every UPDATE, and a DELETE except
--   1. a tenant delete's FK cascade (pg_trigger_depth() > 1), and
--   2. the retention prune (FR-34, T045): hours_changes_prune(older_than),
--      a SECURITY DEFINER function owned by spool_hours_pruner, a NOLOGIN
--      NOBYPASSRLS role in the rdb 0168 shape (the migrator is a member WITH
--      INHERIT FALSE, SET TRUE, never holding its privileges). The trigger
--      lets the DELETE through only when current_user is that role, which
--      only the function's own body is. No custom setting is a guard: any
--      session can set_config one (app.rls_scope, rdb 0014).
-- The prune deletes under the caller's row level security scope (the
-- policies are TO public, so they bind the pruner too): a workspace scope
-- prunes that workspace's rows only, no scope prunes none. The pruner holds
-- SELECT and DELETE on hours_changes and nothing else; EXECUTE is revoked
-- from PUBLIC and granted to the schema owner WITH GRANT OPTION, so
-- runtime-grants.sql grants it to the runtime login.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). No running
-- hub reads these tables yet (T029, T032, T045, T049 do).
-- Live-data safety: four new empty tables; each FK takes a SHARE ROW
-- EXCLUSIVE lock on tenants until COMMIT.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_hours_pruner') THEN
        BEGIN
            CREATE ROLE spool_hours_pruner NOLOGIN NOBYPASSRLS;
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            NULL; -- created by a concurrent migrator of another database
        END;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_auth_members
                   WHERE roleid = 'spool_hours_pruner'::regrole
                     AND member = current_user::regrole
                     AND set_option AND NOT inherit_option) THEN
        BEGIN
            GRANT spool_hours_pruner TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
        EXCEPTION WHEN unique_violation THEN
            NULL; -- granted by a concurrent migrator of another database
        END;
    END IF;
END
$$;

CREATE TABLE hours_days (
    tenant_id        text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id        text        NOT NULL CHECK (length(member_id) BETWEEN 1 AND 200),
    day              date        NOT NULL,
    start_at         timestamptz NULL,
    end_at           timestamptz NULL,
    break_minutes    integer     NOT NULL DEFAULT 0 CHECK (break_minutes BETWEEN 0 AND 1440),
    standard_minutes integer     NOT NULL CHECK (standard_minutes BETWEEN 0 AND 1440),
    no_break         boolean     NOT NULL DEFAULT false,
    -- one source per field (FR-32): {"start_at": "plan", "end_at": "clock", ...}
    sources          jsonb       NOT NULL DEFAULT '{}'
                                 CHECK (jsonb_typeof(sources) = 'object'
                                        AND sources - ARRAY['start_at', 'end_at', 'break_minutes', 'standard_minutes', 'no_break'] = '{}'::jsonb
                                        AND NOT jsonb_path_exists(sources,
                                            '$.* ? (@.type() != "string" || !(@ like_regex "^(plan|standard|activity|clock|terminal|foreman|self|absence|holiday)$"))')),
    written_by       text        NOT NULL CHECK (length(written_by) BETWEEN 1 AND 200),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id, day),
    CHECK (start_at IS NULL OR end_at IS NULL OR end_at > start_at),
    CHECK (NOT no_break OR break_minutes = 0)
);
CREATE INDEX hours_days_day ON hours_days (tenant_id, day);

CREATE TABLE hours_changes (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    change_id  bigint      GENERATED ALWAYS AS IDENTITY,
    actor      text        NOT NULL CHECK (length(actor) BETWEEN 1 AND 200),
    actor_kind text        NOT NULL CHECK (actor_kind IN ('member', 'terminal', 'sweep')),
    at         timestamptz NOT NULL DEFAULT now(),
    -- the member whose hours the change touches; NULL for a workspace-level one
    member_id  text        NULL CHECK (length(member_id) BETWEEN 1 AND 200),
    object     text        NOT NULL CHECK (object ~ '^[a-z][a-z_]{0,39}$'),
    key        text        NOT NULL CHECK (length(key) BETWEEN 1 AND 400),
    before     jsonb       NULL CHECK (octet_length(before::text) <= 16384),
    after      jsonb       NULL CHECK (octet_length(after::text) <= 16384),
    reason     text        NULL CHECK (length(reason) <= 500),
    PRIMARY KEY (tenant_id, change_id),
    CHECK (actor_kind <> 'sweep' OR actor = 'sweep')
);
CREATE INDEX hours_changes_member_at ON hours_changes (tenant_id, member_id, at);
CREATE INDEX hours_changes_at ON hours_changes (at);

CREATE TABLE hours_adjustments (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    adjustment_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    member_id     text        NOT NULL CHECK (length(member_id) BETWEEN 1 AND 200),
    period_start  date        NOT NULL, -- the open period it lands in
    corrects_day  date        NOT NULL,
    kind          text        NOT NULL CHECK (kind IN ('work', 'travel', 'wait', 'absence')),
    target        text        NOT NULL CHECK (target ~ '^(t|ch|dm|cal|job):.{1,200}$' OR target = 'ws'),
    minutes       integer     NOT NULL CHECK (minutes BETWEEN -1440 AND 1440 AND minutes <> 0),
    reason        text        NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
    created_by    text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, adjustment_id),
    CHECK (corrects_day < period_start)
);
CREATE INDEX hours_adjustments_period ON hours_adjustments (tenant_id, member_id, period_start);

CREATE TABLE hours_ops (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id text        NOT NULL CHECK (length(member_id) BETWEEN 1 AND 200),
    op_id     text        NOT NULL CHECK (length(op_id) BETWEEN 1 AND 100),
    at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id, op_id)
);
CREATE INDEX hours_ops_at ON hours_ops (at);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF, CLE-3416).
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['hours_days', 'hours_changes', 'hours_adjustments', 'hours_ops'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;

-- Append-only change log: no UPDATE ever; a DELETE only as a tenant
-- delete's cascade or from inside hours_changes_prune.
CREATE FUNCTION hours_changes_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND (pg_trigger_depth() > 1 OR current_user = 'spool_hours_pruner') THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'hours_changes is append-only: % refused (only a tenant delete or the retention prune removes rows)', TG_OP;
END $$;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON hours_changes
    FOR EACH ROW EXECUTE FUNCTION hours_changes_append_only();

-- CREATE only so the migrator, as the role, can create the function (rdb
-- 0143, P0 G7); revoked again below.
GRANT USAGE, CREATE ON SCHEMA public TO spool_hours_pruner;
GRANT SELECT, DELETE ON hours_changes TO spool_hours_pruner;

-- As spool_hours_pruner, then back to the migrator's own role (rdb 0143).
DO $$
DECLARE
    me    text := current_user;
    owner text := (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.hours_changes'::regclass);
BEGIN
    SET LOCAL ROLE spool_hours_pruner;
    CREATE FUNCTION public.hours_changes_prune(older_than timestamptz)
        RETURNS integer
        LANGUAGE plpgsql VOLATILE SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
    AS $fn$
    DECLARE
        n integer;
    BEGIN
        DELETE FROM public.hours_changes c WHERE c.at < older_than;
        GET DIAGNOSTICS n = ROW_COUNT;
        RETURN n;
    END
    $fn$;
    REVOKE ALL ON FUNCTION public.hours_changes_prune(timestamptz) FROM PUBLIC;
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.hours_changes_prune(timestamptz) TO %I WITH GRANT OPTION', owner);
    EXECUTE format('SET LOCAL ROLE %I', me);
END
$$;

REVOKE CREATE ON SCHEMA public FROM spool_hours_pruner;
