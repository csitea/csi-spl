-- 0184_issue_opens.sql — which issues a member has opened, so a new issue is
-- marked until its assignee opens it (SPL-1559). Forward-only.
--
-- The owner (HUM-10, t1 7edebc75, msg 7d76ce22): "Now that I receive
-- "counter" in the issues, I can see the counter, but I cannot distinguish
-- which issues are the new ones. They should be marked the same way as the
-- messages are marked. A new issue should be marked as a new issue, which has
-- not been opened yet".
--
-- One row per (tenant, member, issue) the member opened; opening it again
-- keeps the first time. The hub lists an open issue as unopened for its
-- assignee while the assignee has no row here (and did not create it); the
-- Issues tab counts exactly those rows. read_marks (0098) is not reused: its
-- keys are message cursors that every /v1/me/reads answer carries.
--
-- Backfill: every live issue counts as opened by its current assignee, so the
-- first list after the deploy marks only issues that arrive later, not every
-- issue already assigned (the 0104 rule: no flood on the first badge).
--
-- RLS: the 0021 fail-closed form (NULLIF) plus the operator policy.

SET LOCAL lock_timeout = '5s';

CREATE TABLE issue_opens (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id text        NOT NULL CHECK (length(member_id) BETWEEN 1 AND 64),
    number    integer     NOT NULL,
    opened_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id, number),
    FOREIGN KEY (tenant_id, number) REFERENCES issues (tenant_id, number) ON DELETE CASCADE
);

ALTER TABLE issue_opens ENABLE ROW LEVEL SECURITY;
ALTER TABLE issue_opens FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON issue_opens
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON issue_opens
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- Backfill, in the migrator's operator scope.
INSERT INTO issue_opens (tenant_id, member_id, number)
SELECT tenant_id, assignee, number FROM issues
WHERE assignee <> '' AND deleted_at IS NULL;
