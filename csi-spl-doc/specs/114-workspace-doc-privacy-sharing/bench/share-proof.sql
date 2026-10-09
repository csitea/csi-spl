-- share-proof.sql - spec 114 section 3.4: model (a) privacy + sharing proof.
-- Runs as the non-superuser role that OWNS the tables (FORCE RLS binds it),
-- after 0157 and share-grant.sql. Every check prints PASS <label> or stops
-- the run (ON_ERROR_STOP). The two controls live in share-control.sql.

CREATE FUNCTION pg_temp.ok(label text, got bigint, want bigint) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
    IF got IS DISTINCT FROM want THEN
        RAISE EXCEPTION 'FAIL % got % want %', label, got, want;
    END IF;
    RAISE NOTICE 'PASS %', label;
END $$;

-- Runs sql; passes only when it fails with SQLSTATE want.
CREATE FUNCTION pg_temp.refused(label text, sql text, want text) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE sql;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = want THEN
            RAISE NOTICE 'PASS % (refused %: %)', label, SQLSTATE, SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL % refused with % (%), want %', label, SQLSTATE, SQLERRM, want;
    END;
    RAISE EXCEPTION 'FAIL % was accepted, want %', label, want;
END $$;

CREATE FUNCTION pg_temp.as_tenant(t text) RETURNS void
    LANGUAGE sql AS $$ SELECT set_config('app.tenant_id', t, false), set_config('app.rls_scope', '', false) $$;

-- Seed: workspace a owns docs A1 (shared later) and A2 (never shared),
-- b owns B1. Fixed ids so the checks can name them.
SELECT pg_temp.as_tenant('a');
BEGIN;
INSERT INTO workspace_doc (id, tenant_id, title) VALUES
    ('00000000-0000-0000-0000-0000000000a1', 'a', 'A1'),
    ('00000000-0000-0000-0000-0000000000a2', 'a', 'A2');
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title) VALUES
    ('00000000-0000-0000-0001-0000000000a1', 'a', '00000000-0000-0000-0000-0000000000a1', NULL, 1, 'root'),
    ('00000000-0000-0000-0002-0000000000a1', 'a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0001-0000000000a1', 1, 'section'),
    ('00000000-0000-0000-0001-0000000000a2', 'a', '00000000-0000-0000-0000-0000000000a2', NULL, 1, 'root');
COMMIT;
SELECT pg_temp.as_tenant('b');
BEGIN;
INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('00000000-0000-0000-0000-0000000000b1', 'b', 'B1');
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title) VALUES
    ('00000000-0000-0000-0001-0000000000b1', 'b', '00000000-0000-0000-0000-0000000000b1', NULL, 1, 'root');
COMMIT;

-- P1 private by default: b sees none of a's rows.
SELECT pg_temp.ok('P1 b sees 0 of a docs', (SELECT count(*) FROM workspace_doc WHERE tenant_id = 'a'), 0);
SELECT pg_temp.ok('P1 b sees 0 of a items', (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = 'a'), 0);
SELECT pg_temp.ok('P1 b sees its own doc', (SELECT count(*) FROM workspace_doc), 1);
-- P2 b cannot grant itself a's doc.
SELECT pg_temp.refused('P2 grant naming b as owner of a doc', $q$
    INSERT INTO workspace_doc_share (tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('b', '00000000-0000-0000-0000-0000000000a1', 'c', 'read', 'm-b')$q$, '23503');
SELECT pg_temp.refused('P2 grant as a from b scope', $q$
    INSERT INTO workspace_doc_share (tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 'b', 'read', 'm-b')$q$, '42501');

-- P3 a shares A1 with b, read only.
SELECT pg_temp.as_tenant('a');
SELECT pg_temp.refused('P3 a cannot share with itself', $q$
    INSERT INTO workspace_doc_share (tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 'a', 'read', 'm-a')$q$, '23514');
INSERT INTO workspace_doc_share (id, tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('00000000-0000-0000-0005-000000000001', 'a', '00000000-0000-0000-0000-0000000000a1', 'b', 'read', 'm-a');
SELECT pg_temp.as_tenant('b');
SELECT pg_temp.ok('P3 b sees shared A1', (SELECT count(*) FROM workspace_doc WHERE tenant_id = 'a'), 1);
SELECT pg_temp.ok('P3 b sees A1 items', (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = 'a'), 2);
SELECT pg_temp.ok('P3 b still sees 0 of A2', (SELECT count(*) FROM workspace_doc WHERE id = '00000000-0000-0000-0000-0000000000a2'), 0);
SELECT pg_temp.ok('P3 b sees the grant row', (SELECT count(*) FROM workspace_doc_share), 1);
SELECT pg_temp.as_tenant('c');
SELECT pg_temp.ok('P3 c sees 0 of a', (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = 'a'), 0);
SELECT pg_temp.ok('P3 c sees 0 grants', (SELECT count(*) FROM workspace_doc_share), 0);

-- P4 read is read: b's writes hit 0 rows, b cannot re-share.
SELECT pg_temp.as_tenant('b');
WITH u AS (UPDATE workspace_doc_item SET body = 'b was here' WHERE tenant_id = 'a' RETURNING 1)
SELECT pg_temp.ok('P4 b update on read share hits 0 rows', (SELECT count(*) FROM u), 0);
WITH d AS (DELETE FROM workspace_doc_item WHERE tenant_id = 'a' RETURNING 1)
SELECT pg_temp.ok('P4 b delete on read share hits 0 rows', (SELECT count(*) FROM d), 0);
SELECT pg_temp.refused('P4 b re-shares A1 to c', $q$
    INSERT INTO workspace_doc_share (tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 'c', 'read', 'm-b')$q$, '42501');
WITH u AS (UPDATE workspace_doc_share SET revoked_at = now(), revoked_by = 'm-b' RETURNING 1)
SELECT pg_temp.ok('P4 b cannot revoke a grant it received', (SELECT count(*) FROM u), 0);

-- P5 revoke: once, and only the revoke.
SELECT pg_temp.as_tenant('a');
SELECT pg_temp.refused('P5 access change in place', $q$
    UPDATE workspace_doc_share SET access = 'edit' WHERE id = '00000000-0000-0000-0005-000000000001'$q$, '23514');
UPDATE workspace_doc_share SET revoked_at = now(), revoked_by = 'm-a' WHERE id = '00000000-0000-0000-0005-000000000001';
SELECT pg_temp.refused('P5 second revoke', $q$
    UPDATE workspace_doc_share SET revoked_at = now(), revoked_by = 'm-a' WHERE id = '00000000-0000-0000-0005-000000000001'$q$, '23514');
SELECT pg_temp.as_tenant('b');
SELECT pg_temp.ok('P5 b sees 0 of A1 after revoke', (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = 'a'), 0);
SELECT pg_temp.ok('P5 b still sees the revoked grant (audit)', (SELECT count(*) FROM workspace_doc_share WHERE revoked_at IS NOT NULL), 1);

-- P6 edit share: b edits A1; rows keep tenant a; the 0157 tree trigger
-- (which locks the doc row FOR UPDATE) commits under b's scope.
SELECT pg_temp.as_tenant('a');
INSERT INTO workspace_doc_share (tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 'b', 'edit', 'm-a');
SELECT pg_temp.as_tenant('b');
BEGIN;
SELECT 1 FROM workspace_doc WHERE id = '00000000-0000-0000-0000-0000000000a1' FOR UPDATE;
UPDATE workspace_doc SET rev = rev + 1 WHERE id = '00000000-0000-0000-0000-0000000000a1';
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title) VALUES
    ('a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0001-0000000000a1', 2, 'added by b');
INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor) VALUES
    ('a', '00000000-0000-0000-0000-0000000000a1', 1, '{"kind":"add"}', 'm-b@b');
COMMIT;
SELECT pg_temp.ok('P6 b edit landed in A1', (SELECT count(*) FROM workspace_doc_item WHERE doc_id = '00000000-0000-0000-0000-0000000000a1'), 3);
SELECT pg_temp.refused('P6 b item tagged b in a doc', $q$
    INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title) VALUES
    ('b', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0001-0000000000a1', 3, 'x')$q$, '23503');
WITH d AS (DELETE FROM workspace_doc WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING 1)
SELECT pg_temp.ok('P6 edit cannot delete the doc', (SELECT count(*) FROM d), 0);
SELECT pg_temp.ok('P6 edit still sees 0 of A2', (SELECT count(*) FROM workspace_doc_item WHERE doc_id = '00000000-0000-0000-0000-0000000000a2'), 0);
SELECT pg_temp.refused('P6 b writes into unshared A2', $q$
    INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title) VALUES
    ('a', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0001-0000000000a2', 1, 'x')$q$, '42501');

-- P7 fail closed and operator.
SELECT pg_temp.as_tenant('');
SELECT pg_temp.ok('P7 no tenant sees 0 docs', (SELECT count(*) FROM workspace_doc), 0);
SELECT pg_temp.ok('P7 no tenant sees 0 grants', (SELECT count(*) FROM workspace_doc_share), 0);
SELECT set_config('app.rls_scope', 'operator', false);
SELECT pg_temp.ok('P7 operator sees 3 docs', (SELECT count(*) FROM workspace_doc), 3);
SELECT pg_temp.ok('P7 operator sees 2 grants', (SELECT count(*) FROM workspace_doc_share), 2);
