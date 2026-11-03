-- 0256_workspace_doc_restricted_to_human.sql - a Qto document only one person
-- can read: no other member, no admin role, no agent seat, no act-as clone
-- (spec 125 row B8, section 5.3; research section 6.1 "Option D's gap";
-- owner HUM-10 constraints C7, C8, C9 in csitea topic fc0119cd; SPL-4723).
-- Forward-only, additive, idempotent: a second apply changes nothing.
--
--   workspace_doc.restricted_to_human
--                 NULL = the document is the workspace's, as before (0157);
--                 'HUM-<n>' = the document is that human's alone.
--   human_lock    a RESTRICTIVE policy (USING and WITH CHECK) on
--                 workspace_doc: a locked row passes only when the
--                 transaction-local app.doc_human_id is its human. Unset or ''
--                 is no human, so a locked row reads as 0 rows: fail closed.
--                 Only the hub sets app.doc_human_id (store.WithHuman), and only
--                 for a signed-in member who is not an act-as clone; an agent
--                 token, a desk, the operator scope, a migration and the
--                 reporting SQL never carry it. Restrictive, so it only
--                 narrows tenant_scope, operator_scope and 0191's
--                 doc_select_repo.
--                 A setting of its own, not 0255's app.human_id (the
--                 Netvisor owner scope): a doc read never opens finance rows.
--   human_lock    on workspace_doc_item and workspace_doc_rev_log: a row
--                 passes only when its document is visible to the same
--                 statement (the IN reads workspace_doc under its own RLS,
--                 so the lock above decides). An uncorrelated IN, so the
--                 planner hashes the visible doc ids once per scan instead of
--                 probing per row. WITH CHECK (true): a create writes the
--                 document and its root item in one statement, which could
--                 not see the new document yet; the store writes an item only
--                 under the document's lock, which reads the document first
--                 (store.wsDocTx.lock), so a write to a hidden document is
--                 already a 404.
-- workspace_doc_node keeps its two policies: its nested set (lft / rgt) is
-- renumbered by statements over the whole workspace, and a hidden row would
-- keep stale bounds. A doc node holds no title (0165's shape check), and
-- every listing joins the document and drops a node whose document it
-- cannot see (store.docNodeSelect).
--
-- Live-data safety: a NULL column rewrites no row; the CHECK scans one small
-- table; CREATE POLICY is catalog-only but holds ACCESS EXCLUSIVE on its table
-- until COMMIT, hence lock_timeout. No row is locked by this file, so the
-- policies change nothing until the hub locks one. DEPLOY ORDER: wf 20
-- applies this before the hub that reads the column rolls. Runs under the
-- operator RLS scope (spool migrate, rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

ALTER TABLE workspace_doc
    ADD COLUMN IF NOT EXISTS restricted_to_human text NULL
    CONSTRAINT workspace_doc_restricted_to_human_id CHECK (restricted_to_human ~ '^HUM-[0-9]+$');

DROP POLICY IF EXISTS human_lock ON workspace_doc;
CREATE POLICY human_lock ON workspace_doc AS RESTRICTIVE
    USING (restricted_to_human IS NULL
           OR restricted_to_human = NULLIF(current_setting('app.doc_human_id', true), ''))
    WITH CHECK (restricted_to_human IS NULL
                OR restricted_to_human = NULLIF(current_setting('app.doc_human_id', true), ''));

DROP POLICY IF EXISTS human_lock ON workspace_doc_item;
CREATE POLICY human_lock ON workspace_doc_item AS RESTRICTIVE
    USING (doc_id IN (SELECT d.id FROM workspace_doc d))
    WITH CHECK (true);

DROP POLICY IF EXISTS human_lock ON workspace_doc_rev_log;
CREATE POLICY human_lock ON workspace_doc_rev_log AS RESTRICTIVE
    USING (doc_id IN (SELECT d.id FROM workspace_doc d))
    WITH CHECK (true);
