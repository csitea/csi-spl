-- 0157_workspace_docs.sql - workspace documents: one tree of items per
-- document, an outline and a grid over it (spec 113 T001, sections 2.2, 2.3
-- and 3.2). Forward-only, additive.
--
--   workspace_doc          the document header. Its row is the per-document
--                          lock: every structural op and the item trigger
--                          below take it FOR UPDATE first (spec 3.3).
--   workspace_doc_item     adjacency list + sibling ordinal. Every document
--                          has ONE hidden root (parent_id NULL, ord 1); the
--                          top-level sections are its children. The outline
--                          number 1 / 1.1 / 1.1.1 is derived at read from the
--                          ord path, never stored.
--   workspace_doc_rev_log  append-only JSONB log: one entry per
--                          workspace_doc.rev bump, written in the same
--                          transaction (D-Q1). No UPDATE or DELETE for the
--                          runtime login (spool-hub-roles/runtime-grants.sql).
--
-- The workspace is the tenant (0126's naming): tenant_id is the workspace id,
-- so there is no separate workspace_id column to drift from it.
--
-- FK checks bypass RLS (spec 2.2, seat 5, measured), so every FK carries the
-- tenant: an item can only point at a doc, and a parent, of its own tenant.
--
-- The invariants (spec 3.1) the DB holds:
--   I1 at most one root   workspace_doc_item_one_root + workspace_doc_item_root_ord
--   I1 at least one root  workspace_doc_root_required (doc INSERT, deferred)
--                         and workspace_doc_item_tree (a root delete)
--   I2 one parent, in D   parent_id + workspace_doc_item_parent_fk
--   I4 overlap            workspace_doc_item_sibling_ord + workspace_doc_item_ord_min
--   I3 cycle, I4 gap      workspace_doc_item_tree (deferred constraint trigger)
-- DEPLOY ORDER: apply BEFORE the hub that writes these tables (T002).

CREATE TABLE workspace_doc (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    title      text        NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
    rev        bigint      NOT NULL DEFAULT 0 CHECK (rev >= 0),
    created_by text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 200),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_tenant_id UNIQUE (tenant_id, id)
);

CREATE TABLE workspace_doc_item (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  text        NOT NULL,
    doc_id     uuid        NOT NULL,
    parent_id  uuid        NULL,
    ord        integer     NOT NULL,
    title      text        NOT NULL DEFAULT '' CHECK (length(title) <= 1000),
    body       text        NOT NULL DEFAULT '' CHECK (length(body) <= 1000000),
    attrs      jsonb       NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(attrs) = 'object'),
    rev        bigint      NOT NULL DEFAULT 1 CHECK (rev >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_item_ord_min CHECK (ord >= 1),
    CONSTRAINT workspace_doc_item_root_ord CHECK (parent_id IS NOT NULL OR ord = 1),
    CONSTRAINT workspace_doc_item_tenant_doc_id UNIQUE (tenant_id, doc_id, id),
    -- I4 overlap, and the child-lookup index (children in order, max(ord)).
    -- Checked at statement end, so a shift is one statement; a multi-statement
    -- shift runs under SET CONSTRAINTS .. DEFERRED.
    CONSTRAINT workspace_doc_item_sibling_ord UNIQUE (doc_id, parent_id, ord)
        DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT workspace_doc_item_doc_fk FOREIGN KEY (tenant_id, doc_id)
        REFERENCES workspace_doc (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT workspace_doc_item_parent_fk FOREIGN KEY (tenant_id, doc_id, parent_id)
        REFERENCES workspace_doc_item (tenant_id, doc_id, id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX workspace_doc_item_one_root ON workspace_doc_item (doc_id) WHERE parent_id IS NULL;

CREATE TABLE workspace_doc_rev_log (
    tenant_id  text        NOT NULL,
    doc_id     uuid        NOT NULL,
    rev        bigint      NOT NULL CHECK (rev >= 1),
    op         jsonb       NOT NULL CHECK (jsonb_typeof(op) = 'object'),
    actor      text        NOT NULL CHECK (length(actor) BETWEEN 1 AND 200),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_rev_log_doc_rev PRIMARY KEY (doc_id, rev),
    CONSTRAINT workspace_doc_rev_log_doc_fk FOREIGN KEY (tenant_id, doc_id)
        REFERENCES workspace_doc (tenant_id, id) ON DELETE CASCADE
);

-- RLS in the 0021 fail-closed NULLIF shape (the 0107 pair) on all three.
ALTER TABLE workspace_doc ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_doc
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE workspace_doc_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_item FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc_item
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_doc_item
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE workspace_doc_rev_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_rev_log FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_doc_rev_log
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_doc_rev_log
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- I1 at least one: at commit a new document has its root. A document deleted
-- in the same transaction needs none.
CREATE FUNCTION workspace_doc_root_required() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM workspace_doc WHERE id = NEW.id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    PERFORM 1 FROM workspace_doc_item WHERE doc_id = NEW.id AND parent_id IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'workspace_doc_root_required: I1 doc % has no root item', NEW.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_root_required';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER workspace_doc_root_required
    AFTER INSERT ON workspace_doc
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_root_required();

-- I3 and I4 at commit (spec 3.2):
--   1. a doc_id change is refused;
--   2. the doc row FOR UPDATE: a writer that skipped the doc lock waits here
--      for the one that holds it, and (READ COMMITTED) checks the state that
--      writer committed, so two lock-skipping writers cannot both commit a
--      gap. A no-op when the op already holds the lock. Doc gone (deleted in
--      this transaction, its items cascaded): nothing to check;
--   3. on a parent_id change, a bounded walk from the item to the root:
--      meeting the item again, or more steps than the doc has items, is a
--      cycle (I3);
--   4. the parent of OLD and of NEW: no children is valid, else min(ord) = 1
--      and max(ord) = count (the UNIQUE key rules out duplicates), so 1..k
--      (I4). The root group (parent NULL) must hold exactly the root (I1).
--      Once per (doc, parent) per firing statement: every deferred fire of
--      one COMMIT (or SET CONSTRAINTS .. IMMEDIATE) runs after the last
--      write and sees the same final state, so a k-sibling shift checks its
--      parent once, not k times. The key is transaction-local and stamped
--      with statement_timestamp(), so a later batch in the same transaction
--      checks again.
CREATE FUNCTION workspace_doc_item_tree() RETURNS trigger
    LANGUAGE plpgsql AS $$
DECLARE
    v_doc    uuid;
    v_parent uuid;
    v_stamp  text := statement_timestamp()::text;
    v_key    text;
    v_n      bigint;
    v_min    integer;
    v_max    integer;
    v_items  bigint;
    v_cur    uuid;
    v_steps  bigint := 0;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.doc_id IS DISTINCT FROM OLD.doc_id THEN
        RAISE EXCEPTION 'workspace_doc_item_tree: doc_id change refused (item %, doc % -> %)', NEW.id, OLD.doc_id, NEW.doc_id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_item_tree';
    END IF;
    IF TG_OP = 'DELETE' THEN
        v_doc := OLD.doc_id;
    ELSE
        v_doc := NEW.doc_id;
    END IF;

    PERFORM 1 FROM workspace_doc WHERE id = v_doc FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.parent_id IS DISTINCT FROM OLD.parent_id AND NEW.parent_id IS NOT NULL THEN
        SELECT count(*) INTO v_items FROM workspace_doc_item WHERE doc_id = v_doc;
        v_cur := NEW.parent_id;
        WHILE v_cur IS NOT NULL LOOP
            v_steps := v_steps + 1;
            IF v_cur = NEW.id OR v_steps > v_items THEN
                RAISE EXCEPTION 'workspace_doc_item_tree: I3 cycle, item % under % in doc %', NEW.id, NEW.parent_id, v_doc
                    USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_item_tree';
            END IF;
            SELECT parent_id INTO v_cur FROM workspace_doc_item WHERE doc_id = v_doc AND id = v_cur;
        END LOOP;
    END IF;

    FOR v_parent IN
        SELECT DISTINCT p FROM (VALUES
            (CASE WHEN TG_OP <> 'INSERT' THEN OLD.parent_id END, TG_OP <> 'INSERT'),
            (CASE WHEN TG_OP <> 'DELETE' THEN NEW.parent_id END, TG_OP <> 'DELETE')) AS t (p, used)
        WHERE used
    LOOP
        v_key := 'spool_wsdoc.k' || md5(v_doc::text || '/' || coalesce(v_parent::text, 'root'));
        IF current_setting(v_key, true) IS NOT DISTINCT FROM v_stamp THEN
            CONTINUE;
        END IF;
        IF v_parent IS NULL THEN
            SELECT count(*) INTO v_n FROM workspace_doc_item WHERE doc_id = v_doc AND parent_id IS NULL;
            IF v_n <> 1 THEN
                RAISE EXCEPTION 'workspace_doc_item_tree: I1 doc % has % root items', v_doc, v_n
                    USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_item_tree';
            END IF;
        ELSE
            SELECT count(*), min(ord), max(ord) INTO v_n, v_min, v_max
              FROM workspace_doc_item WHERE doc_id = v_doc AND parent_id = v_parent;
            IF v_n > 0 AND (v_min <> 1 OR v_max <> v_n) THEN
                RAISE EXCEPTION 'workspace_doc_item_tree: I4 gap under parent % in doc % (count %, ord %..%)', v_parent, v_doc, v_n, v_min, v_max
                    USING ERRCODE = 'check_violation', CONSTRAINT = 'workspace_doc_item_tree';
            END IF;
        END IF;
        PERFORM set_config(v_key, v_stamp, true);
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER workspace_doc_item_tree
    AFTER INSERT OR UPDATE OF parent_id, ord, doc_id OR DELETE ON workspace_doc_item
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_item_tree();
