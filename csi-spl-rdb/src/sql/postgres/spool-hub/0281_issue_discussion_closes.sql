-- 0281_issue_discussion_closes.sql - an issue follows its discussion
-- (SPL-5284, spec 041 archive-releases-work.md). Forward-only.
--
-- The owner (HUM-10, t1 fcf09921, msgs a081dcf2 and eae27b5d, 2026-11-11):
-- "Once a customer closes a discussion, all of the open issues should be
-- changed to this status and closed as well. ... If the customer deletes a
-- discussion, then all of the open issues should be deleted as well." and
-- "if the customer then reopens a discussion, all of the issues which are
-- related to it and which were in this status should be reopened and changed
-- back to To Do or Work in Progress (whatever the previous status was)."
-- Poll 063a4bdd: any ONE linked discussion decides (1 B); a deleted
-- discussion deletes its open issues instead of moving them to the backlog
-- (2 A); a discussion undelete is its own lane (3 A).
--
-- issue_discussion_closes: one row per issue a discussion closed or deleted,
-- with the status it had, so that the discussion's unarchive (and a later
-- undelete) puts it back. op 'archive': the issue went to diss, and
-- closed_at is the canceled_at it was given; the unarchive reverts only an
-- issue still diss with that same canceled_at, so a change made by hand in
-- between stands. op 'delete': the issue was soft-deleted (deleted_at =
-- closed_at). One row per issue: a closed issue is no longer open, so no
-- second discussion closes it; a stale row (an issue reopened by hand) is
-- overwritten by the next close.
--
-- Live-data safety: a new empty table, nothing rewritten. Runs under the
-- operator RLS scope (spool migrate, rdb 0014). The running image neither
-- reads nor writes it, so the file applies before the hub that does.
-- RLS: the 0021 fail-closed form (NULLIF) plus the operator policy, as 0194.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS issue_discussion_closes (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    number      integer     NOT NULL,
    task_id     uuid        NOT NULL,
    op          text        NOT NULL CHECK (op IN ('archive', 'delete')),
    prev_status text        NOT NULL CHECK (length(prev_status) <= 16),
    closed_at   timestamptz NOT NULL,
    closed_by   text        NOT NULL DEFAULT '' CHECK (length(closed_by) <= 64),
    PRIMARY KEY (tenant_id, number),
    FOREIGN KEY (tenant_id, number) REFERENCES issues (tenant_id, number) ON DELETE CASCADE
);

-- Which issues a discussion closed: the unarchive's read.
CREATE INDEX IF NOT EXISTS issue_discussion_closes_task ON issue_discussion_closes (tenant_id, task_id);

ALTER TABLE issue_discussion_closes ENABLE ROW LEVEL SECURITY;
ALTER TABLE issue_discussion_closes FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON issue_discussion_closes;
CREATE POLICY tenant_scope ON issue_discussion_closes
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON issue_discussion_closes;
CREATE POLICY operator_scope ON issue_discussion_closes
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
