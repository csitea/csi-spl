-- 0310_t1_issue_backlog_default.sql — t1 uses its "Issue backlog" topic as
-- its default discussion, like every other workspace (SPL-6212, spec 039).
-- Forward-only.
--
-- The owner (HUM-10, t1 topic 438d96a1, 2026-11-21, msg 564f9723, poll
-- 14996393): "B — Give t1 its own "Issue backlog" topic like every other
-- workspace, and move the 222 open issues there". Until now
-- issue_discussion_default (0194) named t1's topic fcf09921 (msg 62f96f94),
-- so every t1 issue with no other discussion piled into that one topic.
--
-- 1. issue_discussion_default(tenant) is spool_issue_backlog_id(tenant) for
--    every tenant, t1 included (Go twin: store.IssueDiscussionDefault; bash
--    twin: spl_lane_issue_default_topic). The hub posts t1's backlog topic
--    as it does for any tenant that links to it and lacks it
--    (hub/issue_backlog.go, store.TenantsMissingIssueBacklog).
-- 2. The move: every t1 issue linked to fcf09921 whose status is neither
--    done nor diss (prd 2026-11-21 ~21:0xZ, read only: 222 = eval 106,
--    onhold 10, todo 33, wip 73) has that link replaced by one to t1's
--    backlog topic, linked_at kept. A done or diss issue keeps its fcf09921
--    link (history); topic fcf09921 itself is untouched. Each issue keeps a
--    link throughout, so the deferred "at least one" check (0194) holds at
--    COMMIT. Idempotent: a second run finds nothing linked to fcf09921 that
--    is open.

SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION issue_discussion_default(tenant text) RETURNS uuid
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT spool_issue_backlog_id(tenant) $$;

-- An open issue that already links the backlog topic only loses fcf09921.
DELETE FROM issue_discussions d
USING issues i
WHERE d.tenant_id = 't1' AND d.task_id = 'fcf09921-8f21-4518-a117-f8ddb41bfff5'
  AND i.tenant_id = d.tenant_id AND i.number = d.number AND i.status NOT IN ('done', 'diss')
  AND EXISTS (SELECT 1 FROM issue_discussions b
              WHERE b.tenant_id = d.tenant_id AND b.number = d.number AND b.task_id = spool_issue_backlog_id('t1'));

UPDATE issue_discussions d
SET task_id = spool_issue_backlog_id('t1'), linked_by = 'rdb-0310'
FROM issues i
WHERE d.tenant_id = 't1' AND d.task_id = 'fcf09921-8f21-4518-a117-f8ddb41bfff5'
  AND i.tenant_id = d.tenant_id AND i.number = d.number AND i.status NOT IN ('done', 'diss');
