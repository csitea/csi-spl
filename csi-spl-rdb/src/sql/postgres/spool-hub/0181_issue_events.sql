-- 0181_issue_events.sql — every change of an issue, for its History tab
-- (owner HUM-10, t1 62e48cef, msg 5d4a027b: "we need jira like history tab
-- for each issue to see when it was created, when somebody commneted etc.").
-- Forward-only.
--
-- One row per event: created; a field changed (title, description, status,
-- priority, level, assignee, kind, parent = the epic, deadline, labels);
-- deleted / restored (rdb 0071); archived / unarchived (rdb 0085). Blocked
-- and on hold are statuses (rdb 0061), so they are status changes.
--
-- Written by a trigger on issues, not by the Go store: every path that
-- changes a row (UpdateIssue, the level cascade, delete, the archive /
-- unarchive cascades, a future data migration) is covered without touching
-- each call site, and in the same transaction as the change. The actor is
-- the row's own audit column the store already writes: created_by,
-- deleted_by, archived_by, else updated_by.
--
-- Comments are NOT copied here: an issue's discussion is its topic
-- (issues.task_id), so the hub reads them from messages when the history is
-- fetched.
--
-- Backfill: 'created' for every existing issue at created_at, plus its
-- deleted / archived stamp. Older field changes were never recorded.
--
-- RLS: the 0021 fail-closed form (NULLIF) plus the operator policy, like
-- every tenant table; the trigger runs as the writer, inside its tenant.

SET LOCAL lock_timeout = '5s';

CREATE TABLE issue_events (
    id        bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    number    integer     NOT NULL,
    at        timestamptz NOT NULL DEFAULT now(),
    actor     text        NOT NULL DEFAULT '' CHECK (length(actor) <= 64),
    event     text        NOT NULL
              CHECK (event IN ('created', 'changed', 'deleted', 'restored', 'archived', 'unarchived')),
    -- the changed field for event 'changed', else empty
    field     text        NOT NULL DEFAULT ''
              CHECK (field IN ('', 'title', 'description', 'status', 'priority', 'level',
                               'assignee', 'kind', 'parent', 'deadline', 'labels')),
    -- old -> new as text; NULL where it does not apply (a description is too
    -- long to repeat: its change carries no values)
    old_value text        NULL CHECK (length(old_value) <= 1000),
    new_value text        NULL CHECK (length(new_value) <= 1000),
    FOREIGN KEY (tenant_id, number) REFERENCES issues (tenant_id, number) ON DELETE CASCADE
);
-- One issue's history, oldest first.
CREATE INDEX issue_events_issue ON issue_events (tenant_id, number, at, id);

ALTER TABLE issue_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE issue_events FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON issue_events
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON issue_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- issue_event_ts renders a deadline the way the API does (RFC 3339, UTC).
CREATE FUNCTION issue_event_ts(v timestamptz) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT to_char(v AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;

CREATE FUNCTION issue_events_record() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    who text := left(NEW.updated_by, 64);
    ts  timestamptz := CASE WHEN TG_OP = 'UPDATE' AND NEW.updated_at IS DISTINCT FROM OLD.updated_at
                            THEN NEW.updated_at ELSE now() END;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO issue_events (tenant_id, number, at, actor, event)
        VALUES (NEW.tenant_id, NEW.number, NEW.created_at, left(NEW.created_by, 64), 'created');
        RETURN NULL;
    END IF;

    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        INSERT INTO issue_events (tenant_id, number, at, actor, event)
        VALUES (NEW.tenant_id, NEW.number, NEW.deleted_at, left(coalesce(NEW.deleted_by, who), 64), 'deleted');
    ELSIF NEW.deleted_at IS NULL AND OLD.deleted_at IS NOT NULL THEN
        INSERT INTO issue_events (tenant_id, number, at, actor, event)
        VALUES (NEW.tenant_id, NEW.number, ts, who, 'restored');
    END IF;
    IF NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL THEN
        INSERT INTO issue_events (tenant_id, number, at, actor, event)
        VALUES (NEW.tenant_id, NEW.number, NEW.archived_at, left(coalesce(NEW.archived_by, who), 64), 'archived');
    ELSIF NEW.archived_at IS NULL AND OLD.archived_at IS NOT NULL THEN
        INSERT INTO issue_events (tenant_id, number, at, actor, event)
        VALUES (NEW.tenant_id, NEW.number, ts, who, 'unarchived');
    END IF;

    INSERT INTO issue_events (tenant_id, number, at, actor, event, field, old_value, new_value)
    SELECT NEW.tenant_id, NEW.number, ts, who, 'changed', c.field, left(c.o, 1000), left(c.n, 1000)
    FROM (VALUES
        (1,  'title',       OLD.title,                         NEW.title,                         OLD.title IS DISTINCT FROM NEW.title),
        (2,  'description', NULL,                              NULL,                              OLD.description IS DISTINCT FROM NEW.description),
        (3,  'status',      OLD.status,                        NEW.status,                        OLD.status IS DISTINCT FROM NEW.status),
        (4,  'priority',    OLD.priority::text,                NEW.priority::text,                OLD.priority IS DISTINCT FROM NEW.priority),
        (5,  'level',       OLD.level::text,                   NEW.level::text,                   OLD.level IS DISTINCT FROM NEW.level),
        (6,  'assignee',    OLD.assignee,                      NEW.assignee,                      OLD.assignee IS DISTINCT FROM NEW.assignee),
        (7,  'kind',        OLD.kind,                          NEW.kind,                          OLD.kind IS DISTINCT FROM NEW.kind),
        (8,  'parent',      OLD.parent_number::text,           NEW.parent_number::text,           OLD.parent_number IS DISTINCT FROM NEW.parent_number),
        (9,  'deadline',    issue_event_ts(OLD.deadline),      issue_event_ts(NEW.deadline),      OLD.deadline IS DISTINCT FROM NEW.deadline),
        (10, 'labels',      array_to_string(OLD.labels, ','),  array_to_string(NEW.labels, ','),  OLD.labels IS DISTINCT FROM NEW.labels)
    ) AS c (ord, field, o, n, changed)
    WHERE c.changed
    ORDER BY c.ord;
    RETURN NULL;
END
$$;

CREATE TRIGGER issue_events_record AFTER INSERT OR UPDATE ON issues
    FOR EACH ROW EXECUTE FUNCTION issue_events_record();

-- Backfill, in the migrator's operator scope.
INSERT INTO issue_events (tenant_id, number, at, actor, event)
SELECT tenant_id, number, created_at, left(created_by, 64), 'created' FROM issues;
INSERT INTO issue_events (tenant_id, number, at, actor, event)
SELECT tenant_id, number, deleted_at, left(coalesce(deleted_by, updated_by), 64), 'deleted'
FROM issues WHERE deleted_at IS NOT NULL;
INSERT INTO issue_events (tenant_id, number, at, actor, event)
SELECT tenant_id, number, archived_at, left(coalesce(archived_by, updated_by), 64), 'archived'
FROM issues WHERE archived_at IS NOT NULL;
