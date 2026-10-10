-- 0165_workspace_doc_node.sql - the Qto document tree: the folders and
-- documents of a workspace as ONE nested set per workspace (spec 120 v1.0,
-- sections 4, 6.2 and 8; owner msgs d44d08f8 nested set, 90b4dc96 one hidden
-- root, 2b5a1ad4 folder = name, title, description). Forward-only, additive.
--
--   workspace_doc_node   one row per folder and per document, plus one hidden
--                        root per workspace. A document keeps its header in
--                        workspace_doc (0157, 0164, unchanged); its node
--                        points at it 1:1. The root row holds the counters
--                        and is the workspace lock: every structural op takes
--                        it FOR UPDATE first (spec 5).
--
-- The workspace is the tenant (0157): tenant_id, no workspace_id. FK checks
-- bypass RLS, so both FKs carry the tenant, and the parent FK the parent's
-- kind (a node hangs only under a root or folder of its own workspace).
--
-- The invariants (spec 4.3) the DB holds:
--   one root, at lft 1        workspace_doc_node_one_root + _root_lft
--   a row's bounds            workspace_doc_node_bounds, _leaf (immediate)
--   no bound used twice       workspace_doc_node_lft_once, _rgt_once (deferred)
--   1..2n, nested, parent_id  workspace_doc_node_ns (deferred constraint
--   agrees, depth <= 32       trigger: the ordered pass at commit)
--   caps 10,000 / 1,000       doc_count, folder_count on the root under the
--                             _cap / _folder_cap CHECKs, kept by
--                             workspace_doc_node_count
--   kind, tenant fixed        workspace_doc_node_fixed
-- Every shift is ONE UPDATE setting lft and rgt with CASE: the immediate
-- CHECKs refuse the textbook two-step and negate forms (spec 5, T2b).
--
-- Data: every existing workspace_doc gets a node under its workspace's root,
-- refused when a workspace holds more than 10,000 documents (spec 6.2).
-- The second migration (spec 6.4, workspace_doc_node_required) waits until
-- the hub that writes nodes serves dev and prd.
-- DEPLOY ORDER: wf 20 applies it on dev AND prd; today's hub never writes
-- the table, so it is additive for it. A workspace_doc delete now cascades to
-- its node, so whoever deletes a migrated document closes the gap in the same
-- transaction (spec 5, delete document) or the commit check refuses it.

CREATE TABLE workspace_doc_node (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    lft         integer     NOT NULL,
    rgt         integer     NOT NULL,
    parent_id   uuid        NULL,
    kind        text        NOT NULL CHECK (kind IN ('root', 'folder', 'doc')),
    parent_kind text        NULL,
    name        text        NOT NULL DEFAULT '',
    title       text        NOT NULL DEFAULT '' CHECK (length(title) <= 500),
    description text        NOT NULL DEFAULT '' CHECK (length(description) <= 1000),
    doc_id      uuid        NULL,
    doc_count    integer    NOT NULL DEFAULT 0,
    folder_count integer    NOT NULL DEFAULT 0,
    created_by  text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 200),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_node_tenant_id UNIQUE (tenant_id, id, kind),
    CONSTRAINT workspace_doc_node_bounds CHECK (lft >= 1 AND lft < rgt AND (rgt - lft) % 2 = 1),
    CONSTRAINT workspace_doc_node_leaf   CHECK (kind <> 'doc' OR rgt = lft + 1),
    CONSTRAINT workspace_doc_node_root_lft CHECK (kind <> 'root' OR lft = 1),
    CONSTRAINT workspace_doc_node_lft_once UNIQUE (tenant_id, lft) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT workspace_doc_node_rgt_once UNIQUE (tenant_id, rgt) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT workspace_doc_node_shape CHECK (
        (kind = 'root'   AND parent_id IS NULL     AND doc_id IS NULL     AND name = '')
     OR (kind = 'folder' AND parent_id IS NOT NULL AND doc_id IS NULL     AND length(name) BETWEEN 1 AND 255)
     OR (kind = 'doc'    AND parent_id IS NOT NULL AND doc_id IS NOT NULL
         AND name = '' AND title = '' AND description = '')),
    CONSTRAINT workspace_doc_node_parent_kind CHECK (
        (parent_id IS NULL) = (parent_kind IS NULL) AND parent_kind IN ('root', 'folder')),
    CONSTRAINT workspace_doc_node_cap        CHECK (doc_count BETWEEN 0 AND 10000),
    CONSTRAINT workspace_doc_node_folder_cap CHECK (folder_count BETWEEN 0 AND 1000),
    CONSTRAINT workspace_doc_node_parent_fk FOREIGN KEY (tenant_id, parent_id, parent_kind)
        REFERENCES workspace_doc_node (tenant_id, id, kind),
    CONSTRAINT workspace_doc_node_doc_fk FOREIGN KEY (tenant_id, doc_id)
        REFERENCES workspace_doc (tenant_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX workspace_doc_node_one_root ON workspace_doc_node (tenant_id) WHERE kind = 'root';
CREATE UNIQUE INDEX workspace_doc_node_one_place ON workspace_doc_node (doc_id) WHERE doc_id IS NOT NULL;
CREATE UNIQUE INDEX workspace_doc_node_folder_name
    ON workspace_doc_node (tenant_id, parent_id, lower(name)) WHERE kind = 'folder';
CREATE INDEX workspace_doc_node_children ON workspace_doc_node (tenant_id, parent_id, lft);

-- RLS in the 0157 shape (spec 8).
ALTER TABLE workspace_doc_node ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_node FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc_node
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_doc_node
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- A node's kind and workspace never change: the counters and the parent FK
-- are kept per kind and per workspace.
CREATE FUNCTION workspace_doc_node_fixed() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.kind IS DISTINCT FROM OLD.kind OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
        RAISE EXCEPTION 'workspace_doc_node_fixed: node % kind/tenant change refused (%/% -> %/%)',
            OLD.id, OLD.tenant_id, OLD.kind, NEW.tenant_id, NEW.kind
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_fixed';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER workspace_doc_node_fixed
    BEFORE UPDATE OF kind, tenant_id ON workspace_doc_node
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_node_fixed();

-- The caps (spec 4.2): one UPDATE of the root per statement and workspace,
-- by the documents and folders the statement inserted or deleted. The root
-- row is the lock, so two creates at 9,999 queue on it and the second's
-- CHECK fails at 10,001 (a count(*) check races). A move changes no counter;
-- a subtree delete decrements once by k. A root deleted in the same
-- statement (a workspace delete) leaves nothing to update.
CREATE FUNCTION workspace_doc_node_count() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE workspace_doc_node r
           SET doc_count = r.doc_count + c.docs, folder_count = r.folder_count + c.folders
          FROM (SELECT tenant_id, count(*) FILTER (WHERE kind = 'doc') AS docs,
                       count(*) FILTER (WHERE kind = 'folder') AS folders
                  FROM workspace_doc_node_new GROUP BY tenant_id) c
         WHERE r.tenant_id = c.tenant_id AND r.kind = 'root' AND (c.docs > 0 OR c.folders > 0);
    ELSE
        UPDATE workspace_doc_node r
           SET doc_count = r.doc_count - c.docs, folder_count = r.folder_count - c.folders
          FROM (SELECT tenant_id, count(*) FILTER (WHERE kind = 'doc') AS docs,
                       count(*) FILTER (WHERE kind = 'folder') AS folders
                  FROM workspace_doc_node_old GROUP BY tenant_id) c
         WHERE r.tenant_id = c.tenant_id AND r.kind = 'root' AND (c.docs > 0 OR c.folders > 0);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER workspace_doc_node_count_ins
    AFTER INSERT ON workspace_doc_node
    REFERENCING NEW TABLE AS workspace_doc_node_new
    FOR EACH STATEMENT EXECUTE FUNCTION workspace_doc_node_count();
CREATE TRIGGER workspace_doc_node_count_del
    AFTER DELETE ON workspace_doc_node
    REFERENCING OLD TABLE AS workspace_doc_node_old
    FOR EACH STATEMENT EXECUTE FUNCTION workspace_doc_node_count();

-- The nested-set invariant at commit (spec 4.3), once per workspace per
-- firing statement (0157's statement-stamped transaction-local key):
--   1. the root row FOR UPDATE: a writer that skipped the lock waits here
--      for the one that holds it, then (READ COMMITTED) checks the state
--      that writer committed. No root: valid only with no node at all (a
--      workspace delete, or nothing created yet);
--   2. every bound of the workspace in order, with a stack of open nodes:
--      each bound is the previous + 1 (so 1..2n, no gap, no bound twice);
--      an lft's node has the stack's top as parent_id (the empty stack only
--      for the root) and the depth stays <= 33 (the root + 32 levels); an
--      rgt closes the stack's top (no crossing); the stack ends empty.
-- Any break raises check_violation naming workspace_doc_node_ns, the node
-- and the bound; the transaction rolls back.
CREATE FUNCTION workspace_doc_node_ns() RETURNS trigger
    LANGUAGE plpgsql AS $$
DECLARE
    v_tenant text;
    v_stamp  text := statement_timestamp()::text;
    v_key    text;
    v_prev   integer := 0;
    v_stack  uuid[] := '{}';
    v_depth  integer := 0;
    r        record;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_tenant := OLD.tenant_id;
    ELSE
        v_tenant := NEW.tenant_id;
    END IF;
    v_key := 'spool_wsdocnode.k' || md5(v_tenant);
    IF current_setting(v_key, true) IS NOT DISTINCT FROM v_stamp THEN
        RETURN NULL;
    END IF;

    PERFORM 1 FROM workspace_doc_node WHERE tenant_id = v_tenant AND kind = 'root' FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM 1 FROM workspace_doc_node WHERE tenant_id = v_tenant LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'workspace_doc_node_ns: workspace % has nodes but no root', v_tenant
                USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_ns';
        END IF;
        PERFORM set_config(v_key, v_stamp, true);
        RETURN NULL;
    END IF;

    FOR r IN
        SELECT b.bound, b.id, b.is_lft, b.parent_id FROM (
            SELECT lft AS bound, id, true AS is_lft, parent_id FROM workspace_doc_node WHERE tenant_id = v_tenant
            UNION ALL
            SELECT rgt, id, false, parent_id FROM workspace_doc_node WHERE tenant_id = v_tenant) b
        ORDER BY b.bound, b.is_lft
    LOOP
        IF r.bound <> v_prev + 1 THEN
            RAISE EXCEPTION 'workspace_doc_node_ns: workspace % bound % of node % follows % (gap, overlap or a bound used twice)',
                v_tenant, r.bound, r.id, v_prev
                USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_ns';
        END IF;
        IF r.is_lft THEN
            IF (v_depth = 0 AND r.parent_id IS NOT NULL)
               OR (v_depth > 0 AND r.parent_id IS DISTINCT FROM v_stack[v_depth]) THEN
                RAISE EXCEPTION 'workspace_doc_node_ns: workspace % node % at lft % has parent_id %, its enclosing interval is %',
                    v_tenant, r.id, r.bound, r.parent_id, CASE WHEN v_depth > 0 THEN v_stack[v_depth]::text ELSE 'none' END
                    USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_ns';
            END IF;
            v_depth := v_depth + 1;
            IF v_depth > 33 THEN
                RAISE EXCEPTION 'workspace_doc_node_ns: workspace % node % at lft % is deeper than 32 levels',
                    v_tenant, r.id, r.bound
                    USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_ns';
            END IF;
            v_stack[v_depth] := r.id;
        ELSE
            IF v_depth = 0 OR v_stack[v_depth] IS DISTINCT FROM r.id THEN
                RAISE EXCEPTION 'workspace_doc_node_ns: workspace % node % closes at rgt % inside node % (crossing intervals)',
                    v_tenant, r.id, r.bound, CASE WHEN v_depth > 0 THEN v_stack[v_depth]::text ELSE 'none' END
                    USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_ns';
            END IF;
            v_depth := v_depth - 1;
        END IF;
        v_prev := r.bound;
    END LOOP;
    IF v_depth <> 0 THEN
        RAISE EXCEPTION 'workspace_doc_node_ns: workspace % ends with % open node(s)', v_tenant, v_depth
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_ns';
    END IF;
    PERFORM set_config(v_key, v_stamp, true);
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER workspace_doc_node_ns
    AFTER INSERT OR UPDATE OF lft, rgt, parent_id OR DELETE ON workspace_doc_node
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_node_ns();

-- Spec 6.2: refuse, naming the workspaces, when one holds more than 10,000
-- documents. The migrator runs this file in one transaction under operator
-- scope, so a refusal leaves nothing behind.
DO $$
DECLARE
    v_over text;
BEGIN
    SELECT string_agg(tenant_id || ' (' || n || ')', ', ' ORDER BY tenant_id) INTO v_over
      FROM (SELECT tenant_id, count(*) AS n FROM workspace_doc GROUP BY tenant_id HAVING count(*) > 10000) s;
    IF v_over IS NOT NULL THEN
        RAISE EXCEPTION 'workspace_doc_node: refused, workspace(s) over 10000 documents: %', v_over
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_cap';
    END IF;
END $$;

-- Spec 6.2.3: per workspace with documents, its root (1, 2n + 2) and each
-- document i (created_at, id order) at (2i, 2i + 1), one INSERT. The counter
-- trigger sets doc_count; the commit check verifies the bounds.
WITH d AS (
    SELECT tenant_id, id, created_by, created_at,
           row_number() OVER (PARTITION BY tenant_id ORDER BY created_at, id)::integer AS i
      FROM workspace_doc),
roots AS (
    SELECT tenant_id, count(*)::integer AS n, gen_random_uuid() AS id FROM d GROUP BY tenant_id)
INSERT INTO workspace_doc_node (id, tenant_id, lft, rgt, parent_id, parent_kind, kind, doc_id, created_by, created_at)
SELECT id, tenant_id, 1, 2 * n + 2, NULL, NULL, 'root', NULL, '', now() FROM roots
UNION ALL
SELECT gen_random_uuid(), d.tenant_id, 2 * d.i, 2 * d.i + 1, roots.id, 'root', 'doc', d.id, d.created_by, d.created_at
  FROM d JOIN roots USING (tenant_id);

-- Spec 6.2.4: the root's doc_count equals the documents.
DO $$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(coalesce(w.tenant_id, r.tenant_id), ', ') INTO v_bad
      FROM (SELECT tenant_id, count(*) AS n FROM workspace_doc GROUP BY tenant_id) w
      FULL JOIN (SELECT tenant_id, doc_count FROM workspace_doc_node WHERE kind = 'root') r USING (tenant_id)
     WHERE w.n IS DISTINCT FROM r.doc_count;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'workspace_doc_node: doc_count differs from the documents for: %', v_bad
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_node_cap';
    END IF;
END $$;
