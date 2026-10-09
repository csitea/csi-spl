-- share-control.sql - spec 114 section 3.4: the controls, v0.2. Each one
-- breaks the model on purpose and must make a P-check's query return the
-- wrong answer; it prints "CONTROL <name> caught" when it does, "MISSED" when
-- it does not. Run by isolation-bench.sh after share-proof.sql, one psql
-- session per control: C1 as the superuser (it flips FORCE), the rest as the
-- owner role. C2..C11 run inside BEGIN .. ROLLBACK, so each starts from the
-- state share-proof.sql left (both grants on A1 to b accepted and revoked,
-- A1 at rev 4) and leaves it unchanged.
\set ON_ERROR_STOP 1
\if :{?control}
\else
\echo 'usage: psql -v control=c1|c2|..|c11 -f share-control.sql'
\quit
\endif

SELECT :'control' = 'c1' AS is_c1, :'control' = 'c2' AS is_c2, :'control' = 'c3' AS is_c3,
       :'control' = 'c4' AS is_c4, :'control' = 'c5' AS is_c5, :'control' = 'c6' AS is_c6,
       :'control' = 'c7' AS is_c7, :'control' = 'c8' AS is_c8, :'control' = 'c9' AS is_c9,
       :'control' = 'c10' AS is_c10, :'control' = 'c11' AS is_c11 \gset

\if :is_c1
-- C1 (P1-P7): without FORCE the owning role is not bound by RLS (spec 113
-- seat 5#4).
ALTER TABLE workspace_doc_item NO FORCE ROW LEVEL SECURITY;
SET ROLE spl_owner;
SELECT set_config('app.tenant_id', 'c', false), set_config('app.rls_scope', '', false);
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c1-no-force caught (c reads ' || count(*) || ' of a items)'
            ELSE 'CONTROL c1-no-force MISSED' END AS result
  FROM workspace_doc_item WHERE tenant_id = 'a';
RESET ROLE;
ALTER TABLE workspace_doc_item FORCE ROW LEVEL SECURITY;
\quit
\endif

BEGIN;
SELECT set_config('app.tenant_id', 'a', false), set_config('app.rls_scope', '', false);
-- the controls that need a LIVE accepted grant: a offers A1 to b again (edit),
-- b accepts. C2 and C11 need a revoked one (share-proof's), C6 a pending one.
\if :is_c2
\elif :is_c6
\elif :is_c11
\else
INSERT INTO workspace_doc_share (id, tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('00000000-0000-0000-0005-000000000003', 'a', '00000000-0000-0000-0000-0000000000a1', 'b', 'edit', 'm-a');
SELECT set_config('app.tenant_id', 'b', false);
UPDATE workspace_doc_share SET accepted_at = now(), accepted_by = 'm-b' WHERE id = '00000000-0000-0000-0005-000000000003';
\endif

\if :is_c2
-- C2 (P5): a share_read that forgets revoked_at keeps showing a revoked doc.
DROP POLICY share_read ON workspace_doc_item;
DROP POLICY share_edit ON workspace_doc_item;
CREATE POLICY share_read ON workspace_doc_item FOR SELECT
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), ''))));
SELECT set_config('app.tenant_id', 'b', false);
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c2-no-revoke-filter caught (b reads ' || count(*) || ' revoked items)'
            ELSE 'CONTROL c2-no-revoke-filter MISSED' END AS result
  FROM workspace_doc_item WHERE tenant_id = 'a';
\elif :is_c3
-- C3 (P8): without the column trigger an edit receiver forges the header.
DROP TRIGGER workspace_doc_share_edit_cols ON workspace_doc;
WITH u AS (UPDATE workspace_doc SET created_by = 'owner-admin@a', rev = 999999
            WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING 1)
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c3-no-column-trigger caught (b forged created_by and rev of A1)'
            ELSE 'CONTROL c3-no-column-trigger MISSED' END AS result FROM u;
\elif :is_c4
-- C4 (P9): without the reached trigger a receiver pre-fills a future rev
-- slot. IMMEDIATE, so the kept trigger would refuse here, not at a commit
-- this rolled-back transaction never reaches.
DROP TRIGGER workspace_doc_rev_log_reached ON workspace_doc_rev_log;
SET CONSTRAINTS ALL IMMEDIATE;
WITH i AS (INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
            VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 1000000, '{}', 'm-b@b') RETURNING 1)
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c4-no-reached-trigger caught (b pre-filled rev 1000000 of A1)'
            ELSE 'CONTROL c4-no-reached-trigger MISSED' END AS result FROM i;
\elif :is_c5
-- C5 (P9): a share_edit on the rev log without the actor term lets a
-- receiver write under an owner member's name.
DROP POLICY share_edit ON workspace_doc_rev_log;
CREATE POLICY share_edit ON workspace_doc_rev_log FOR INSERT
    WITH CHECK (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.access = 'edit' AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)));
WITH x AS (UPDATE workspace_doc SET rev = rev + 1, updated_at = now() WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING tenant_id, id, rev),
     l AS (INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
            SELECT tenant_id, id, rev, '{"kind":"fake"}', 'owner-admin@a' FROM x RETURNING 1)
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c5-no-actor-check caught (b wrote a rev entry as owner-admin@a)'
            ELSE 'CONTROL c5-no-actor-check MISSED' END AS result FROM l;
\elif :is_c6
-- C6 (P11): a share_read without accepted_at opens a grant b never accepted.
INSERT INTO workspace_doc_share (tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 'b', 'read', 'm-a');
DROP POLICY share_read ON workspace_doc_item;
CREATE POLICY share_read ON workspace_doc_item FOR SELECT
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.revoked_at IS NULL)));
SELECT set_config('app.tenant_id', 'b', false);
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c6-no-consent caught (b reads ' || count(*) || ' items of a pending grant)'
            ELSE 'CONTROL c6-no-consent MISSED' END AS result
  FROM workspace_doc_item WHERE tenant_id = 'a';
\elif :is_c7
-- C7 (P12 fence): drop the fence, add a debug policy that forgot the scope:
-- a session with no scope reads every item.
DROP POLICY scope_fence ON workspace_doc_item;
CREATE POLICY bench_debug ON workspace_doc_item USING (true);
SELECT set_config('app.tenant_id', '', false);
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c7-no-fence caught (no scope reads ' || count(*) || ' items)'
            ELSE 'CONTROL c7-no-fence MISSED' END AS result
  FROM workspace_doc_item;
\elif :is_c8
-- C8 (P12 pin): one added permissive policy, fence kept: the pin turns red.
CREATE POLICY bench_debug ON workspace_doc_item USING (true);
SELECT CASE WHEN bench_policy_set() <> bench_policy_pinned() THEN 'CONTROL c8-extra-policy caught (policy set differs from the pin)'
            ELSE 'CONTROL c8-extra-policy MISSED' END AS result;
\elif :is_c9
-- C9 (P13): a rev-log share_read without the granted_at bound shows b the
-- entry written before any share.
DROP POLICY share_read ON workspace_doc_rev_log;
CREATE POLICY share_read ON workspace_doc_rev_log FOR SELECT
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)));
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c9-no-history-bound caught (b reads ' || count(*) || ' pre-share rev entry)'
            ELSE 'CONTROL c9-no-history-bound MISSED' END AS result
  FROM workspace_doc_rev_log WHERE rev = 1;
\elif :is_c10
-- C10 (P10): TODAY's list query (wsDocHeadSQL, no tenant filter) mixes the
-- shared A1 into b's own list.
SELECT CASE WHEN count(*) > 1 THEN 'CONTROL c10-store-list-no-tenant-filter caught (b own list shows ' || count(*) || ' docs, owns 1)'
            ELSE 'CONTROL c10-store-list-no-tenant-filter MISSED' END AS result
  FROM workspace_doc d JOIN workspace_doc_item r ON r.doc_id = d.id AND r.parent_id IS NULL
 WHERE (NULL::uuid IS NULL OR d.id = NULL) AND (NULL::text IS NULL OR r.attrs->>'topic_id' = NULL);
\elif :is_c11
-- C11 (P14): a share_edit that forgets revoked_at lets b keep writing.
DROP POLICY share_edit ON workspace_doc_item;
CREATE POLICY share_edit ON workspace_doc_item
    USING (doc_id = ANY (ARRAY(SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '') AND s.access = 'edit')))
    WITH CHECK (doc_id = ANY (ARRAY(SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '') AND s.access = 'edit')));
SELECT set_config('app.tenant_id', 'b', false);
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title) VALUES
    ('a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0001-0000000000a1', 3, 'c11 after revoke');
SELECT set_config('app.rls_scope', 'operator', false);
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c11-no-revoke-on-edit caught (b added an item after revoke)'
            ELSE 'CONTROL c11-no-revoke-on-edit MISSED' END AS result
  FROM workspace_doc_item WHERE title = 'c11 after revoke';
\endif
ROLLBACK;
