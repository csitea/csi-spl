-- 0047_issues.sql — a tenant's issues, the way Linear keeps them (specs/039,
-- CLE-34993). Forward-only.
--
-- Owner, 2026-09-26: "after the event log we must create the issues section
-- in the left most bar, the issues those must be shown the way Linear shows
-- the issues ... with the attributes and behaviours on how linear does that",
-- refined the same morning: "each issue must have prio, deadline, level,
-- title, description ... the deadline must be a calendar control, which has
-- also time".
--
-- Three tables, all tenant-scoped:
--   issue_counters  one row per tenant: the key prefix (SPL in SPL-12) and the
--                   last number handed out. Numbers are never reused.
--   issue_labels    the tenant's label catalogue (name + colour).
--   issues          one row per issue. Its discussion is an ordinary spool
--                   topic: task_id is minted with the issue, and every comment
--                   is a message on that task, so edit, emoji, files and agent
--                   delivery work unchanged.
--
-- No row is deleted by the hub (Linear's Canceled is a status). A tenant's
-- issues die with the tenant.
--
-- RLS: the 0021 fail-closed form (NULLIF) plus the operator policy, like
-- every tenant table. An issue is readable by every member of its tenant
-- (topics.read); writing needs notes.send (hub, specs/039 §3).

CREATE TABLE issue_counters (
    tenant_id   text        PRIMARY KEY REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    prefix      text        NOT NULL DEFAULT 'SPL' CHECK (prefix ~ '^[A-Z][A-Z0-9]{0,9}$'),
    last_number integer     NOT NULL DEFAULT 0 CHECK (last_number >= 0)
);

CREATE TABLE issue_labels (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    -- slug of the name, the value issues.labels carries
    label_id   text        NOT NULL CHECK (label_id ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
    name       text        NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
    color      text        NOT NULL DEFAULT '#6b7280' CHECK (color ~ '^#[0-9a-f]{6}$'),
    created_by text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 64),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, label_id)
);

CREATE TABLE issues (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    number        integer     NOT NULL CHECK (number > 0),
    title         text        NOT NULL CHECK (length(title) BETWEEN 1 AND 255),
    -- markdown, shown only in the right pane
    description   text        NOT NULL DEFAULT '' CHECK (length(description) <= 20000),
    status        text        NOT NULL DEFAULT 'backlog'
                              CHECK (status IN ('backlog', 'todo', 'in_progress', 'in_review', 'done', 'canceled')),
    -- Linear's order: 0 no priority, 1 urgent, 2 high, 3 medium, 4 low
    priority      smallint    NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 4),
    -- the owner's "level": Linear's t-shirt estimate, 0 none, 1 XS .. 5 XL
    level         smallint    NOT NULL DEFAULT 0 CHECK (level BETWEEN 0 AND 5),
    -- a member HUM-* or a roster agent id, empty string = unassigned
    assignee      text        NOT NULL DEFAULT '' CHECK (assignee = '' OR assignee ~ '^[A-Z]{2,4}-[0-9]+$'),
    -- issue_labels.label_id values; the hub keeps them known and unique
    labels        text[]      NOT NULL DEFAULT '{}' CHECK (cardinality(labels) <= 20),
    -- date AND time (owner: "a calendar control, which has also time")
    deadline      timestamptz NULL,
    parent_number integer     NULL,
    task_id       uuid        NOT NULL,
    created_by    text        NOT NULL CHECK (length(created_by) <= 64),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    text        NOT NULL CHECK (length(updated_by) <= 64),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    -- set when the status enters done / canceled, cleared when it leaves
    completed_at  timestamptz NULL,
    canceled_at   timestamptz NULL,
    PRIMARY KEY (tenant_id, number),
    UNIQUE (tenant_id, task_id),
    CHECK (parent_number IS NULL OR parent_number <> number),
    FOREIGN KEY (tenant_id, parent_number) REFERENCES issues (tenant_id, number)
);

-- The list is read whole per tenant and grouped by status in the hub; the
-- primary key serves it. Sub-issues of one parent:
CREATE INDEX issues_parent ON issues (tenant_id, parent_number) WHERE parent_number IS NOT NULL;

ALTER TABLE issue_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE issue_counters FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON issue_counters
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON issue_counters
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE issue_labels ENABLE ROW LEVEL SECURITY;
ALTER TABLE issue_labels FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON issue_labels
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON issue_labels
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE issues ENABLE ROW LEVEL SECURITY;
ALTER TABLE issues FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON issues
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON issues
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
