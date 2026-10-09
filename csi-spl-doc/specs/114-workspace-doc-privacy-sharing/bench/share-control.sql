-- share-control.sql - spec 114 section 3.4: the two controls. Each one breaks
-- the model on purpose and must make a P-check's query return the wrong
-- count; it prints "CONTROL <name> caught" when it does. Run by
-- isolation-bench.sh after share-proof.sql: C1 as the superuser (it flips
-- FORCE), C2 as the owner role.
\set ON_ERROR_STOP 1
\if :{?control}
\else
\echo 'usage: psql -v control=c1|c2 -f share-control.sql'
\quit
\endif

SELECT :'control' = 'c1' AS is_c1 \gset
\if :is_c1
-- C1: without FORCE the owning role is not bound by RLS (spec 113 seat 5#4).
ALTER TABLE workspace_doc_item NO FORCE ROW LEVEL SECURITY;
SET ROLE spl_owner;
SELECT set_config('app.tenant_id', 'c', false), set_config('app.rls_scope', '', false);
SELECT CASE WHEN count(*) > 0 THEN 'CONTROL c1-no-force caught (c reads ' || count(*) || ' of a items)'
            ELSE 'CONTROL c1-no-force MISSED' END AS result
  FROM workspace_doc_item WHERE tenant_id = 'a';
RESET ROLE;
ALTER TABLE workspace_doc_item FORCE ROW LEVEL SECURITY;
\else
-- C2: a share_read that forgets revoked_at keeps showing a revoked doc.
SELECT set_config('app.tenant_id', 'a', false), set_config('app.rls_scope', '', false);
UPDATE workspace_doc_share SET revoked_at = now(), revoked_by = 'm-a' WHERE revoked_at IS NULL;
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
\endif
