-- 0194_issue_discussions.sql — every issue links to one or more discussions,
-- enforced by the database (SPL-1593). Forward-only.
--
-- The owner (HUM-10, t1 topic fcf09921, 2026-10-13): "Issues must be linked
-- to one or more discussions." (msg 3e75e13e) "And that link in the database
-- should be enforced, so it should be not null. For all of the existing
-- issues, they could link to this discussion." (msg 62f96f94) This replaces
-- spec 135 Q4 A (the source link as a description line only).
--
-- issue_discussions: one row per (tenant, issue, discussion topic). A topic
-- has no table of its own: it is the task_id its messages share, so the link
-- cannot carry a foreign key to it. issues.task_id stays the issue's OWN
-- comment thread (spec 039), not a source discussion.
--
-- "At least one" is a pair of DEFERRED constraint triggers: an issue that
-- ends a transaction with no link is refused at COMMIT (insert the issue and
-- its links in one transaction), and so is removing an issue's last link.
--
-- A discussion that is archived keeps its links: an archived topic still
-- opens (owner msg 28b479fd). A discussion deleted physically (its last
-- message gone: a message, topic or channel delete, or the retention sweep)
-- loses its links (a topic merged into another moves its links there),
-- and an issue left with none is relinked to its tenant's
-- default discussion (owner msg 81a43a7f, "B"). The default is
-- issue_discussion_default, the one place that names it:
--   t1           topic fcf09921-8f21-4518-a117-f8ddb41bfff5 (msg 62f96f94)
--   every other  its "Issue backlog" topic, spool_issue_backlog_id(tenant)
--                (owner msg e3c349e2, "A"). Only the hub holds the box-wui
--                key, so the hub posts that topic (hub/issue_backlog.go) for
--                every tenant that links to it and lacks it, on start and on
--                every retention sweep, as it posts the 0173 #public notice.
-- The backfill below links every existing issue (deleted and archived ones
-- too) to its tenant's default.
--
-- RLS: the 0021 fail-closed form (NULLIF) plus the operator policy.

SET LOCAL lock_timeout = '5s';

CREATE TABLE issue_discussions (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    number    integer     NOT NULL,
    task_id   uuid        NOT NULL,
    linked_by text        NOT NULL DEFAULT '' CHECK (length(linked_by) <= 64),
    linked_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, number, task_id),
    FOREIGN KEY (tenant_id, number) REFERENCES issues (tenant_id, number) ON DELETE CASCADE
);
-- Which issues link to a topic: the relink and the hub's backlog probe.
CREATE INDEX issue_discussions_task ON issue_discussions (tenant_id, task_id);

ALTER TABLE issue_discussions ENABLE ROW LEVEL SECURITY;
ALTER TABLE issue_discussions FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON issue_discussions
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON issue_discussions
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- The "Issue backlog" topic's msg_id (and task_id) in tenant. Go computes the
-- same value (store.IssueBacklogID); store TestIssueDiscussions0194 pins it.
CREATE OR REPLACE FUNCTION spool_issue_backlog_id(tenant text) RETURNS uuid
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT substr(encode(sha256(('spool-issue-backlog:' || tenant)::bytea), 'hex'), 1, 32)::uuid $$;

-- What an issue with no other discussion links to: the backfill and the
-- relink both call it (Go twin: store.IssueDiscussionDefault).
CREATE OR REPLACE FUNCTION issue_discussion_default(tenant text) RETURNS uuid
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT CASE WHEN tenant = 't1' THEN 'fcf09921-8f21-4518-a117-f8ddb41bfff5'::uuid
                      ELSE spool_issue_backlog_id(tenant) END $$;

-- The rule, for one issue: it still exists and has no link -> refused.
CREATE OR REPLACE FUNCTION issue_discussions_check(tn text, num integer) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM issues i WHERE i.tenant_id = tn AND i.number = num)
       AND NOT EXISTS (SELECT 1 FROM issue_discussions d WHERE d.tenant_id = tn AND d.number = num) THEN
        RAISE EXCEPTION 'issue % of tenant % must link to at least one discussion', num, tn
            USING ERRCODE = 'check_violation', CONSTRAINT = 'issue_discussions_at_least_one';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION issue_discussions_issue_trg() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM issue_discussions_check(NEW.tenant_id, NEW.number);
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION issue_discussions_link_trg() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM issue_discussions_check(OLD.tenant_id, OLD.number);
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER issue_discussions_at_least_one AFTER INSERT ON issues
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION issue_discussions_issue_trg();

CREATE CONSTRAINT TRIGGER issue_discussions_keep_one AFTER DELETE OR UPDATE ON issue_discussions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION issue_discussions_link_trg();

-- The relink: of the (tenant, topic) pairs given, those with no message left
-- lose their links, and every issue that had its last link there (and still
-- exists) links to issue_discussion_default. Two statements: one statement's
-- NOT EXISTS would still see the links its own DELETE removes.
CREATE OR REPLACE FUNCTION issue_discussions_prune(tns text[], tks uuid[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
    cut_tn  text[];
    cut_num integer[];
BEGIN
    WITH gone AS (
        SELECT DISTINCT g.tn, g.tk FROM unnest(tns, tks) AS g (tn, tk)
        WHERE EXISTS (SELECT 1 FROM issue_discussions d WHERE d.tenant_id = g.tn AND d.task_id = g.tk)
          AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = g.tn AND m.task_id = g.tk)
    ), cut AS (
        DELETE FROM issue_discussions d USING gone
        WHERE d.tenant_id = gone.tn AND d.task_id = gone.tk
        RETURNING d.tenant_id, d.number
    )
    SELECT array_agg(cut.tenant_id), array_agg(cut.number) INTO cut_tn, cut_num FROM cut;
    IF cut_tn IS NULL THEN
        RETURN;
    END IF;
    INSERT INTO issue_discussions (tenant_id, number, task_id, linked_by)
    SELECT DISTINCT c.tn, c.num, issue_discussion_default(c.tn), 'hub'
    FROM unnest(cut_tn, cut_num) AS c (tn, num)
    JOIN issues i ON i.tenant_id = c.tn AND i.number = c.num
    WHERE NOT EXISTS (SELECT 1 FROM issue_discussions d WHERE d.tenant_id = c.tn AND d.number = c.num)
    ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION issue_discussions_msg_del_trg() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    tns text[];
    tks uuid[];
BEGIN
    SELECT array_agg(o.tenant_id), array_agg(o.task_id) INTO tns, tks
    FROM (SELECT DISTINCT tenant_id, task_id FROM issue_discussions_old) o;
    IF tns IS NOT NULL THEN
        PERFORM issue_discussions_prune(tns, tks);
    END IF;
    RETURN NULL;
END $$;

-- A message moved to another topic (a merge or a move, rdb 0069). When the
-- last one leaves, the topic moved whole: its links follow it to NEW.task_id
-- (an issue already linking there keeps the one row). Else as a delete.
CREATE OR REPLACE FUNCTION issue_discussions_msg_move_trg() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.tenant_id = NEW.tenant_id
       AND EXISTS (SELECT 1 FROM issue_discussions d WHERE d.tenant_id = OLD.tenant_id AND d.task_id = OLD.task_id)
       AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = OLD.tenant_id AND m.task_id = OLD.task_id) THEN
        DELETE FROM issue_discussions d WHERE d.tenant_id = OLD.tenant_id AND d.task_id = OLD.task_id
            AND EXISTS (SELECT 1 FROM issue_discussions e
                        WHERE e.tenant_id = d.tenant_id AND e.number = d.number AND e.task_id = NEW.task_id);
        UPDATE issue_discussions SET task_id = NEW.task_id WHERE tenant_id = OLD.tenant_id AND task_id = OLD.task_id;
        RETURN NULL;
    END IF;
    PERFORM issue_discussions_prune(ARRAY[OLD.tenant_id], ARRAY[OLD.task_id]);
    RETURN NULL;
END $$;

CREATE TRIGGER issue_discussions_msg_del AFTER DELETE ON messages
    REFERENCING OLD TABLE AS issue_discussions_old
    FOR EACH STATEMENT EXECUTE FUNCTION issue_discussions_msg_del_trg();

CREATE TRIGGER issue_discussions_msg_move AFTER UPDATE OF tenant_id, task_id ON messages
    FOR EACH ROW
    WHEN (OLD.tenant_id IS DISTINCT FROM NEW.tenant_id OR OLD.task_id IS DISTINCT FROM NEW.task_id)
    EXECUTE FUNCTION issue_discussions_msg_move_trg();

-- Backfill, in the migrator's operator scope: every issue with no link (on
-- the first run, every issue) gets its tenant's default discussion.
INSERT INTO issue_discussions (tenant_id, number, task_id, linked_by, linked_at)
SELECT i.tenant_id, i.number, issue_discussion_default(i.tenant_id), 'rdb-0194', i.created_at FROM issues i
WHERE NOT EXISTS (SELECT 1 FROM issue_discussions d WHERE d.tenant_id = i.tenant_id AND d.number = i.number)
ON CONFLICT DO NOTHING;
