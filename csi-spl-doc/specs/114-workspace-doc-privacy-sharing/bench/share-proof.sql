-- share-proof.sql - spec 114 section 3.4: model (a) privacy + sharing proof,
-- v0.2. Runs as the non-superuser role that OWNS the tables (FORCE RLS binds
-- it), after 0157 and share-grant.sql. Every check prints PASS <label> or
-- stops the run (ON_ERROR_STOP). The controls live in share-control.sql.

CREATE FUNCTION pg_temp.ok(label text, got bigint, want bigint) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
    IF got IS DISTINCT FROM want THEN
        RAISE EXCEPTION 'FAIL % got % want %', label, got, want;
    END IF;
    RAISE NOTICE 'PASS %', label;
END $$;

-- Runs sql; passes only when it fails with SQLSTATE want. immediate = check
-- the deferred constraint triggers at the end of sql, not at commit.
CREATE FUNCTION pg_temp.refused(label text, sql text, want text, immediate boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        IF immediate THEN
            SET CONSTRAINTS ALL IMMEDIATE;
        END IF;
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

-- P12 pin: the exact policy set of the four tables. Not pg_temp, because the
-- controls (share-control.sql, other sessions) re-run it. The store test that
-- replaces this at build time pins the same (table, policy, permissive, cmd).
CREATE FUNCTION bench_policy_set() RETURNS text
    LANGUAGE sql AS $$
    SELECT string_agg(tablename || ':' || policyname || ':' || permissive || ':' || cmd, ' '
                      ORDER BY tablename, policyname)
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename IN ('workspace_doc', 'workspace_doc_item', 'workspace_doc_rev_log', 'workspace_doc_share') $$;
CREATE FUNCTION bench_policy_pinned() RETURNS text
    LANGUAGE sql AS $$ SELECT
    'workspace_doc:operator_scope:PERMISSIVE:ALL workspace_doc:scope_fence:RESTRICTIVE:ALL '
    'workspace_doc:share_edit:PERMISSIVE:UPDATE workspace_doc:share_read:PERMISSIVE:SELECT '
    'workspace_doc:tenant_scope:PERMISSIVE:ALL '
    'workspace_doc_item:operator_scope:PERMISSIVE:ALL workspace_doc_item:scope_fence:RESTRICTIVE:ALL '
    'workspace_doc_item:share_edit:PERMISSIVE:ALL workspace_doc_item:share_read:PERMISSIVE:SELECT '
    'workspace_doc_item:tenant_scope:PERMISSIVE:ALL '
    'workspace_doc_rev_log:operator_scope:PERMISSIVE:ALL workspace_doc_rev_log:scope_fence:RESTRICTIVE:ALL '
    'workspace_doc_rev_log:share_edit:PERMISSIVE:INSERT workspace_doc_rev_log:share_read:PERMISSIVE:SELECT '
    'workspace_doc_rev_log:tenant_scope:PERMISSIVE:ALL '
    'workspace_doc_share:operator_scope:PERMISSIVE:ALL workspace_doc_share:scope_fence:RESTRICTIVE:ALL '
    'workspace_doc_share:share_accept:PERMISSIVE:UPDATE workspace_doc_share:share_seen_by_receiver:PERMISSIVE:SELECT '
    'workspace_doc_share:tenant_scope:PERMISSIVE:ALL'::text $$;

-- Seed: workspace a owns docs A1 (shared later) and A2 (never shared),
-- b owns B1. Fixed ids so the checks can name them. A1 gets one rev-log entry
-- BEFORE any share (the hub's bump, workspace_docs.go lines 191-194), so P13
-- can show it stays hidden.
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
WITH x AS (UPDATE workspace_doc SET rev = rev + 1, updated_at = now() WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING tenant_id, id, rev)
INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
    SELECT tenant_id, id, rev, '{"kind":"create"}', 'm-a@a' FROM x;
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

-- P11 consent (c-714 #4): a grant opens nothing until the receiver accepts;
-- only the receiver can accept, once.
SELECT pg_temp.as_tenant('b');
SELECT pg_temp.ok('P11 b sees the pending grant', (SELECT count(*) FROM workspace_doc_share WHERE accepted_at IS NULL), 1);
SELECT pg_temp.ok('P11 pending grant opens 0 docs', (SELECT count(*) FROM workspace_doc WHERE tenant_id = 'a'), 0);
SELECT pg_temp.ok('P11 pending grant opens 0 items', (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = 'a'), 0);
SELECT pg_temp.as_tenant('a');
SELECT pg_temp.refused('P11 owner cannot accept for the receiver', $q$
    UPDATE workspace_doc_share SET accepted_at = now(), accepted_by = 'm-a' WHERE id = '00000000-0000-0000-0005-000000000001'$q$, '23514');
SELECT pg_temp.as_tenant('b');
WITH u AS (UPDATE workspace_doc_share SET accepted_at = now(), accepted_by = 'm-b' WHERE id = '00000000-0000-0000-0005-000000000001' RETURNING 1)
SELECT pg_temp.ok('P11 receiver accepts', (SELECT count(*) FROM u), 1);
SELECT pg_temp.refused('P11 second accept', $q$
    UPDATE workspace_doc_share SET accepted_at = now(), accepted_by = 'm-b' WHERE id = '00000000-0000-0000-0005-000000000001'$q$, '23514');

SELECT pg_temp.ok('P3 b sees shared A1', (SELECT count(*) FROM workspace_doc WHERE tenant_id = 'a'), 1);
SELECT pg_temp.ok('P3 b sees A1 items', (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = 'a'), 2);
SELECT pg_temp.ok('P3 b still sees 0 of A2', (SELECT count(*) FROM workspace_doc WHERE id = '00000000-0000-0000-0000-0000000000a2'), 0);
SELECT pg_temp.ok('P3 b sees the grant row', (SELECT count(*) FROM workspace_doc_share), 1);
-- P13 history bound (c-714 #7): the rev-log entry written before the share
-- stays hidden from the receiver.
SELECT pg_temp.ok('P13 read receiver sees 0 pre-share rev entries', (SELECT count(*) FROM workspace_doc_rev_log), 0);
SELECT pg_temp.as_tenant('c');
SELECT pg_temp.ok('P3 c sees 0 of a', (SELECT count(*) FROM workspace_doc_item WHERE tenant_id = 'a'), 0);
SELECT pg_temp.ok('P3 c sees 0 grants', (SELECT count(*) FROM workspace_doc_share), 0);

-- P4 read is read: b's writes hit 0 rows, b cannot re-share or revoke.
SELECT pg_temp.as_tenant('b');
WITH u AS (UPDATE workspace_doc_item SET body = 'b was here' WHERE tenant_id = 'a' RETURNING 1)
SELECT pg_temp.ok('P4 b update on read share hits 0 rows', (SELECT count(*) FROM u), 0);
WITH d AS (DELETE FROM workspace_doc_item WHERE tenant_id = 'a' RETURNING 1)
SELECT pg_temp.ok('P4 b delete on read share hits 0 rows', (SELECT count(*) FROM d), 0);
SELECT pg_temp.refused('P4 b re-shares A1 to c', $q$
    INSERT INTO workspace_doc_share (tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 'c', 'read', 'm-b')$q$, '42501');
SELECT pg_temp.refused('P4 b cannot revoke a grant it received', $q$
    UPDATE workspace_doc_share SET revoked_at = now(), revoked_by = 'm-b'$q$, '23514');

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

-- P6 edit share: b accepts, then edits A1 with the hub's own bump (rev 1 ->
-- 2); rows keep tenant a; the 0157 tree trigger (which locks the doc row FOR
-- UPDATE) commits under b's scope.
SELECT pg_temp.as_tenant('a');
INSERT INTO workspace_doc_share (id, tenant_id, doc_id, to_tenant, access, granted_by)
    VALUES ('00000000-0000-0000-0005-000000000002', 'a', '00000000-0000-0000-0000-0000000000a1', 'b', 'edit', 'm-a');
SELECT pg_temp.as_tenant('b');
UPDATE workspace_doc_share SET accepted_at = now(), accepted_by = 'm-b' WHERE id = '00000000-0000-0000-0005-000000000002';
BEGIN;
SELECT 1 FROM workspace_doc WHERE id = '00000000-0000-0000-0000-0000000000a1' FOR UPDATE;
INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title) VALUES
    ('a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0001-0000000000a1', 2, 'added by b');
WITH x AS (UPDATE workspace_doc SET rev = rev + 1, updated_at = now() WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING tenant_id, id, rev)
INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
    SELECT tenant_id, id, rev, '{"kind":"add"}', 'm-b@b' FROM x;
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

-- P8 the doc header's columns (c-714 #1): a receiver cannot forge the owner's
-- header; a +1 bump with a title change is all it can do (rev 2 -> 3).
SELECT pg_temp.refused('P8 receiver forges created_by', $q$
    UPDATE workspace_doc SET created_by = 'owner-admin@a' WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$, '23514');
SELECT pg_temp.refused('P8 receiver jumps rev', $q$
    UPDATE workspace_doc SET rev = 999999 WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$, '23514');
SELECT pg_temp.refused('P8 receiver re-tags the header to itself', $q$
    UPDATE workspace_doc SET tenant_id = 'b', rev = rev + 1 WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$, '23514');
WITH x AS (UPDATE workspace_doc SET title = 'A1 renamed by b', rev = rev + 1, updated_at = now()
            WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING tenant_id, id, rev),
     l AS (INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
            SELECT tenant_id, id, rev, '{"kind":"title"}', 'm-b@b' FROM x RETURNING 1)
SELECT pg_temp.ok('P8 receiver renames with a +1 bump', (SELECT count(*) FROM l), 1);
SELECT pg_temp.as_tenant('a');
SELECT pg_temp.refused('P8 owner cannot rewrite created_at', $q$
    UPDATE workspace_doc SET created_at = '2000-01-01' WHERE id = '00000000-0000-0000-0000-0000000000a1'$q$, '23514');

-- P9 the rev log (c-714 #2): a receiver writes only under its own actor and
-- only for a rev the doc has reached, so the owner's next bump always lands.
SELECT pg_temp.as_tenant('b');
SELECT pg_temp.refused('P9 receiver forges an owner actor', $q$
    WITH x AS (UPDATE workspace_doc SET rev = rev + 1, updated_at = now() WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING tenant_id, id, rev)
    INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
        SELECT tenant_id, id, rev, '{"kind":"fake"}', 'owner-admin@a' FROM x$q$, '42501');
SELECT pg_temp.refused('P9 receiver pre-fills the next rev slot', $q$
    INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 4, '{}', 'm-b@b')$q$, '23514', true);
SELECT pg_temp.refused('P9 receiver pre-fills a far rev slot', $q$
    INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 1000000, '{}', 'm-b@b')$q$, '23514', true);
SELECT pg_temp.as_tenant('a');
WITH x AS (UPDATE workspace_doc SET rev = rev + 1, updated_at = now() WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING tenant_id, id, rev),
     l AS (INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
            SELECT tenant_id, id, rev, '{"kind":"set"}', 'm-a@a' FROM x RETURNING rev)
SELECT pg_temp.ok('P9 owner next bump still lands', (SELECT rev FROM l), 4);

-- P13 with the edit grant: b sees the entries since the grant (revs 2, 3, 4),
-- never the pre-share rev 1.
SELECT pg_temp.as_tenant('b');
SELECT pg_temp.ok('P13 edit receiver sees the 3 rev entries since its grant', (SELECT count(*) FROM workspace_doc_rev_log), 3);
SELECT pg_temp.ok('P13 edit receiver sees 0 pre-share rev entries', (SELECT count(*) FROM workspace_doc_rev_log WHERE rev = 1), 0);

-- P10 own list vs shared list (c-714 #3, c-715 #4): the hub's doc list
-- (wsDocHeadSQL, internal/store/wsdoc_hub.go lines 41-45) WITH the explicit
-- tenant filter the build adds keeps the own list to B1; the shared list is
-- its own query. Control C10 runs today's query without the filter.
SELECT pg_temp.ok('P10 own list with a live grant shows only own docs',
    (SELECT count(*) FROM workspace_doc d JOIN workspace_doc_item r ON r.doc_id = d.id AND r.parent_id IS NULL
      WHERE d.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')), 1);
SELECT pg_temp.ok('P10 shared list shows the shared doc',
    (SELECT count(*) FROM workspace_doc d JOIN workspace_doc_item r ON r.doc_id = d.id AND r.parent_id IS NULL
      WHERE d.tenant_id <> NULLIF(current_setting('app.tenant_id', true), '')), 1);

-- P14 revoke closes the WRITE side at the next statement too (c-714 #6).
SELECT pg_temp.as_tenant('a');
UPDATE workspace_doc_share SET revoked_at = now(), revoked_by = 'm-a' WHERE id = '00000000-0000-0000-0005-000000000002';
SELECT pg_temp.as_tenant('b');
WITH x AS (UPDATE workspace_doc SET rev = rev + 1, updated_at = now() WHERE id = '00000000-0000-0000-0000-0000000000a1' RETURNING tenant_id, id, rev),
     l AS (INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
            SELECT tenant_id, id, rev, '{"kind":"set"}', 'm-b@b' FROM x RETURNING 1)
SELECT pg_temp.ok('P14 revoked receiver bump hits 0 rows', (SELECT count(*) FROM l), 0);
WITH u AS (UPDATE workspace_doc_item SET body = 'after revoke' WHERE doc_id = '00000000-0000-0000-0000-0000000000a1' RETURNING 1)
SELECT pg_temp.ok('P14 revoked receiver item update hits 0 rows', (SELECT count(*) FROM u), 0);
SELECT pg_temp.refused('P14 revoked receiver adds an item', $q$
    INSERT INTO workspace_doc_item (tenant_id, doc_id, parent_id, ord, title) VALUES
    ('a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0001-0000000000a1', 3, 'after revoke')$q$, '42501');
SELECT pg_temp.refused('P14 revoked receiver writes the rev log', $q$
    INSERT INTO workspace_doc_rev_log (tenant_id, doc_id, rev, op, actor)
    VALUES ('a', '00000000-0000-0000-0000-0000000000a1', 4, '{}', 'm-b@b')$q$, '42501');

-- P12 the policy set is pinned, and the RESTRICTIVE fence holds a later
-- permissive policy that forgot the scope (c-714 #5).
SELECT pg_temp.ok('P12 policy set of the four tables is the pinned one', (bench_policy_set() = bench_policy_pinned())::int, 1);
BEGIN;
CREATE POLICY bench_debug ON workspace_doc_item USING (true);
SELECT pg_temp.as_tenant('');
SELECT pg_temp.ok('P12 fence: a USING (true) policy still shows no scope 0 items', (SELECT count(*) FROM workspace_doc_item), 0);
ROLLBACK;

-- P7 fail closed and operator.
SELECT pg_temp.as_tenant('');
SELECT pg_temp.ok('P7 no tenant sees 0 docs', (SELECT count(*) FROM workspace_doc), 0);
SELECT pg_temp.ok('P7 no tenant sees 0 grants', (SELECT count(*) FROM workspace_doc_share), 0);
SELECT set_config('app.rls_scope', 'operator', false);
SELECT pg_temp.ok('P7 operator sees 3 docs', (SELECT count(*) FROM workspace_doc), 3);
SELECT pg_temp.ok('P7 operator sees 2 grants', (SELECT count(*) FROM workspace_doc_share), 2);
