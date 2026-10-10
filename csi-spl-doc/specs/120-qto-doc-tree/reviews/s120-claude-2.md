signed against 77ffc9f8c

# Spec 120 review, seat s120-claude-2 (c-749, claude)

Angle: the data model and its integrity: the table, the cap, RLS, the
structural ops, the migration, and the evidence for the tree-model question.
Every claim about the repo carries the command that checks it.

Verdict: **agree with changes.** The draft's direction holds (its own table,
adjacency, a hidden root, a DB backstop for the cap). Its cap trigger is not
race-proof, it uses the wrong HTTP status, and it copies spec 113's sibling
`ord` into a shape where `ord` costs what the nested set costs. The table,
the ops, the routes and the tests are missing; proposals in section 2.

## 1. Section by section

| draft section | verdict | one line |
|---|---|---|
| title, v0.1 | change | add "Owner asks (verbatim)", as spec 113 section 0: msgs ad20e44a, a14e799f, 635c2125, 500ca8f5, f5bc3948; the draft quotes only the first two and never mentions the context menu or the purge |
| 1 Goals | change | "It becomes a hierarchical nested set table" states the owner's ask as decided. Write "its own tree table; the model (nested set or adjacency) is owner question Q3" |
| 2.1 numbers | change | spec 113's numbers are for a document's item tree (fanout 10). The explorer's shape differs: after the migration every document sits flat under the root (10,000 siblings). There adjacency **+ ord** inserting first costs 159 ms, close to the nested set's 437 ms (section 1.1). Quote the explorer-shaped bench, not only 113's |
| 2.1 decision | change | adjacency yes, but **drop `ord`**: a file explorer sorts folders first, then by name. With no `ord` every write is one row (0.13-0.19 ms), there is no sibling shift to miss, and the I4 gap invariant does not exist. Manual order can be added later, forward-only, if the owner asks for drag-to-reorder |
| 2.1 "integrity" | change | the reason is not only the owner's earlier breakage: with no `lft`/`rgt` and no `ord` there is no derived position data to drift. Say that |
| 3 Hub cap | change | 413 Payload Too Large is a request-body status, and the hub already answers 413 `doc_too_large` for a different limit (`grep -n doc_too_large csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_tree.go` -> 1). Use **409 `doc_cap_reached`** (section 2.2) |
| 3 Hub cap | change | "document or folder creation" counts folders against a cap the owner set on documents. Count documents only; folders get their own cap (section 2.2) |
| 3 DB cap | change | a deferred `count(*)` trigger is **not race-proof**: two transactions at 9,999 each check under their own snapshot and both commit 10,001 (the same failure spec 113 seat 5 measured for the gap check). It is also O(n) per insert. Replace with a counter on the root row under a CHECK (section 2.2) |
| 3 | missing | where the WUI shows the cap error, and what it shows |
| 4 Migration | change | the repo has no `workspace_id`: the workspace is the tenant, `tenant_id` (`sed -n 18,19p csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql`). Use `tenant_id` everywhere |
| 4 step 2 | change | "a hidden root (if required) or top-level children" is two designs in one sentence. Pick the root (Q1) and write one procedure (section 2.5) |
| 4 step 3 | change | with no `ord` there is nothing to assign. Note: after the t1 purge (f5bc3948) t1 has 0 documents, but every other tenant keeps its rows, so the migration still has to handle them |
| 4 | missing | a workspace already above 10,000 documents: the migration must refuse it before it writes |
| 4 | missing | the same transaction as `POST /v1/workspace/doctree` must create the node, or a document exists with no place in the explorer |
| 5 RLS | agree | ENABLE + FORCE, `tenant_scope` NULLIF + `operator_scope`, composite FKs that carry the tenant: that is 0157's shape. Name it "the 0157 shape" and give the exact FKs (section 2.1) |
| 5 | missing | the negative tests (section 2.7), and spec 114: a document shared into this workspace is not a node of this tenant's tree (section 2.4) |
| 6 Q1 | agree | hidden root (A), plus a second reason: the root row is the workspace's lock and holds the cap counter (section 2.2) |
| 6 Q2 | agree | name only (A) |
| 6 | missing | the nested-set question (Q3) as an explicit owner question, with numbers and each seat's recommendation |
| (none) | missing | the table DDL, the move/rename/delete semantics, the API routes the context menu needs (lane c-744), the tests |

### 1.1 The measurement (explorer shape, this seat)

The bench SQL is in the appendix (section 4). Throwaway `postgres:16-alpine`,
tree at 77ffc9f8c, **n = 5** per op after one warm-up, box load average
~27. No RLS and no triggers, so these are lower bounds for the real ops.
Every write rolls back.

- **Shape N**: root -> 10 folders -> 10 subfolders -> 100 documents each.
  That is 10,000 documents and 111 folders (`max(rgt)` = 20,222).
- **Shape F**: root -> 10,000 documents flat, the shape the migration
  produces.
- **Models**: `ns` = nested set (`lft`, `rgt`, `parent`). `ao` = adjacency +
  sibling `ord` (the draft's model). `an` = adjacency, no `ord`, sorted by
  name.
- **Ops**:
  - `ins`: a new document as the first child of the first subfolder (N) or
    of the root (F); in `an` there is no position, just the row.
  - `mv folder`: move a subfolder with 100 documents to the end of the last
    top folder.
  - `mv doc`: move one document the same way.

Medians in ms:

| op | shape | ns | ao | an |
|---|---|---|---|---|
| ins | N | 366.5 | 1.51 | 0.15 |
| mv folder (100 docs) | N | 364.4 | 0.66 | 0.19 |
| mv doc | N | 486.6 | 1.34 | 0.15 |
| ins (first of 10,000 siblings) | F | 437.1 | 158.7 | 0.14 |
| read: one folder's children, 10,000 rows, folders first then by name | F | - | - | 5.43 |

What it shows:

- At the owner's 10,000 cap the nested set pays 0.36-0.49 s and rewrites
  ~20,000 bounds per write, as in spec 113's 234 ms / 216 ms at 11,111 items.
- Adjacency + ord is fast in narrow folders but pays 159 ms for "insert
  first" in a wide one, and the migration makes the root wide.
- Adjacency without `ord` is a single-row write in every shape.
- Differences under 2 ms are noise at this load; only the 100-3000x gaps
  carry the decision.

## 2. Proposals for what is missing

### 2.1 The table (rdb `01NN_workspace_doc_node.sql`, next free number at build time)

```sql
CREATE TABLE workspace_doc_node (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    parent_id   uuid        NULL,                 -- NULL only for the hidden root
    kind        text        NOT NULL CHECK (kind IN ('root', 'folder', 'doc')),
    parent_kind text        NULL,                 -- always 'folder' or 'root': see the FK
    name        text        NOT NULL DEFAULT '',  -- folders only; a doc's name is workspace_doc.title
    doc_id      uuid        NULL,
    doc_count   integer     NOT NULL DEFAULT 0,   -- root only: the cap counter
    created_by  text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 200),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_node_tenant_id      UNIQUE (tenant_id, id, kind),
    CONSTRAINT workspace_doc_node_shape CHECK (
        (kind = 'root'   AND parent_id IS NULL     AND doc_id IS NULL     AND name = '')
     OR (kind = 'folder' AND parent_id IS NOT NULL AND doc_id IS NULL     AND length(name) BETWEEN 1 AND 255)
     OR (kind = 'doc'    AND parent_id IS NOT NULL AND doc_id IS NOT NULL AND name = '')),
    CONSTRAINT workspace_doc_node_parent_kind CHECK (
        (parent_id IS NULL) = (parent_kind IS NULL) AND parent_kind IN ('root', 'folder')),
    CONSTRAINT workspace_doc_node_cap CHECK (doc_count BETWEEN 0 AND 10000),
    -- a parent of the same tenant AND of a container kind: a doc is a leaf, by FK
    CONSTRAINT workspace_doc_node_parent_fk FOREIGN KEY (tenant_id, parent_id, parent_kind)
        REFERENCES workspace_doc_node (tenant_id, id, kind),     -- NO ACTION: see 2.3 delete
    CONSTRAINT workspace_doc_node_doc_fk FOREIGN KEY (tenant_id, doc_id)
        REFERENCES workspace_doc (tenant_id, id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX workspace_doc_node_one_root ON workspace_doc_node (tenant_id) WHERE kind = 'root';
CREATE UNIQUE INDEX workspace_doc_node_one_place ON workspace_doc_node (doc_id) WHERE doc_id IS NOT NULL;
CREATE UNIQUE INDEX workspace_doc_node_folder_name
    ON workspace_doc_node (tenant_id, parent_id, lower(name)) WHERE kind = 'folder';
CREATE INDEX workspace_doc_node_children ON workspace_doc_node (tenant_id, parent_id, kind, name);
```

Why each piece:

- **`(tenant_id, parent_id, parent_kind)` FK.** A document node cannot
  become a parent, and that holds in the DB with no trigger. FK checks bypass
  RLS (spec 113 seat 5, measured), so the FK also carries the tenant.
- **Folder names unique per parent, case-insensitive.** Document titles stay
  non-unique, as today (0157 has no unique title).
- **RLS** in the 0157 shape: ENABLE + FORCE, `tenant_scope` with
  `NULLIF(current_setting('app.tenant_id', true), '')`, and `operator_scope`.
  Runtime grants in `spool-hub-roles/runtime-grants.sql`.
- **Two deferred constraint triggers.** Both need it, but neither is
  expensive:
  - `workspace_doc_node_required` (AFTER INSERT ON workspace_doc, deferred,
    the 0157 `root_required` pattern): at commit, a document has its node.
  - `workspace_doc_node_tree` (AFTER UPDATE OF parent_id, deferred): it locks
    the root row, then walks from the moved node to the root. Meeting the
    node again, or more steps than the depth cap (32), is a cycle. A walk is
    at most 32 steps, independent of the 10,000.

### 2.2 The 10,000 cap

- **DB, the authority.** `doc_count` lives on the tenant's root row, under
  `CHECK (doc_count BETWEEN 0 AND 10000)`. A trigger keeps it:
  `AFTER INSERT OR DELETE ON workspace_doc_node FOR EACH ROW WHEN (kind = 'doc')`
  runs `UPDATE workspace_doc_node SET doc_count = doc_count ± 1 WHERE tenant_id = … AND kind = 'root'`.
  - The UPDATE takes the root's row lock, so two concurrent creators queue
    on it. The second re-reads the committed count (READ COMMITTED) and its
    CHECK fails at 10,001.
  - O(1) per insert; no `count(*)`.
  - A recursive delete of k documents is k decrements in one statement on
    one row. That is fine at k <= 10,000; the store may instead decrement
    once by k.
- **Folders.** At most 1,000 per workspace (`folder_count`, same pattern),
  and a depth of at most 32. Both are seat proposals for the panel. They
  bound the explorer's lazy reads and the cycle walk; the owner capped only
  documents.
- **Hub, the fast path.**
  - `POST /v1/workspace/doctree` and `POST …/folders` read `doc_count`
    first. At 10,000 they answer **409 `doc_cap_reached`**: "This workspace
    holds 10,000 documents, the most it can. Delete documents to add new
    ones."
  - The hub also maps the DB's `check_violation` on `workspace_doc_node_cap`
    to the same 409, so a race that slips past the read still gets the
    right error, not a 500.
  - Folders: 409 `folder_cap_reached`, same shape.
- **WUI.**
  - The new-document dialog (`WorkspaceDocNewDialog.vue`) shows the 409
    message inline and keeps the dialog open.
  - The explorer shows `n / 10,000` in its footer from 9,000 on.
  - No silent failure, and no client-only check.

### 2.3 Move, rename, delete

All structural ops run as one transaction that locks the tenant's root row
`FOR UPDATE` first. That is the per-workspace lock, the analogue of 0157's
doc row. Explorer writes are rare and human-driven, so serializing them per
workspace costs nothing.

- **Rename.**
  - A folder: `UPDATE name`. A duplicate name in the same parent is 409
    `name_taken`.
  - A document: the existing `PATCH /v1/workspace/doctree/{doc}` (title).
    The node holds no name, so nothing can drift.
- **Move.** `UPDATE parent_id` of one node: a folder moves with its whole
  subtree, a document alone.
  - Refused into itself or a descendant: 409 `move_into_own_subtree`. The
    store checks it first, and the deferred trigger is the backstop.
  - Refused into a document: a 400 from the hub, and the parent FK holds it
    in the DB.
  - Refused beyond depth 32: 409.
  - A move never changes `doc_count`.
- **Delete a document.** `DELETE FROM workspace_doc WHERE …`. Its items, rev
  log and node cascade, and the counter trigger decrements.
  - Missing today: no route deletes a document
    (`grep -n '"DELETE ' csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_tree.go`
    -> 1 line, the item subtree route).
  - The context menu's Delete needs it (lane c-744).
- **Delete a folder.**
  - Empty: delete it.
  - Not empty, without `?recursive=1`: **409 `folder_not_empty`** with
    `{folders, documents}` counts.
  - With `?recursive=1`, one transaction:
    1. Collect the subtree with a recursive CTE (<= 11,000 rows).
    2. Delete those documents' `workspace_doc` rows (cascade).
    3. Delete the subtree's folders in **one** statement. The parent FK is
       NO ACTION, checked at statement end, so deleting a parent with its
       children in one DELETE passes, where RESTRICT would refuse the first
       row.
  - The WUI confirms with the counts ("Delete folder X, 3 folders and 41
    documents?").
  - The root is never deletable (store refusal, and the one-root index plus
    the root-required trigger).
- **Audit.** A recursive delete writes one hub log line with actor, folder
  and counts. A tree-level rev log is not needed in v1.

### 2.4 Spec 114 sharing

A document shared into workspace B from workspace A stays a node of A's tree
only: B cannot reference it, because the composite FKs carry the tenant.
If B should see shared documents, the explorer shows a virtual "Shared with
this workspace" group, read from 114's grant, never a row in B's
`workspace_doc_node`. Moving, renaming or deleting a shared document from B
is refused. Spec 120 should say this in one paragraph.

### 2.5 The migration

The migration runs after the t1 purge (f5bc3948), forward-only, in one
transaction:

1. Create the table, indexes, triggers and RLS (2.1).
2. Refuse if any tenant has more than 10,000 `workspace_doc` rows, naming
   the tenants: `SELECT tenant_id, count(*) FROM workspace_doc GROUP BY 1 HAVING count(*) > 10000`
   must return 0 rows.
3. Insert one `root` per tenant that has documents (operator scope).
4. Insert one `doc` node per `workspace_doc`, `parent_id` = that tenant's
   root.
5. Set the root's `doc_count` from those rows, then check that it equals the
   count.

New tenants get their root lazily: the first document or folder create
inserts it in the same transaction, under `ON CONFLICT DO NOTHING` on the
one-root index. The store's create-document op inserts the node in the same
transaction (spec 120 names the store function). `do_spl_doc_tree_check`
(spec 113 section 3.4) gains the node checks:

- every document has one node;
- `doc_count` equals the real count;
- no node is deeper than 32;
- no cycle.

It runs under operator scope and exits 2 on 0 tenants, as 113 seat 5 asked.

DEPLOY ORDER: rdb before the hub that writes it (wf 20 applies it on dev and
prd).

### 2.6 API routes (the context menu and the explorer)

Under the existing `/v1/workspace/doctree` prefix. `rbac.DocsRead` for GET,
`rbac.DocsWrite` for the rest, the same as today's routes.

| route | body / query | answers |
|---|---|---|
| `GET /v1/workspace/doctree/nodes` | `?parent=` (none = root) | that folder's children, folders first then by name: `{id, kind, name or title, doc, child_count}`; the lazy unit (5.4 ms for 10,000 rows, section 1.1) |
| `GET /v1/workspace/doctree/nodes/{node}/path` | | the ancestors, for the breadcrumb and for opening a document deep in the tree |
| `POST /v1/workspace/doctree` | gains optional `parent` (a folder id) | 201; 409 `doc_cap_reached` |
| `POST /v1/workspace/doctree/folders` | `{parent, name}` | 201; 409 `name_taken`, `folder_cap_reached`, depth |
| `PATCH /v1/workspace/doctree/folders/{folder}` | `{name}` | 200; 409 `name_taken` |
| `POST /v1/workspace/doctree/nodes/{node}/move` | `{parent}` | 200; 409 `move_into_own_subtree`; 400 parent is a document |
| `DELETE /v1/workspace/doctree/{doc}` | | 204; the context menu's Delete for a document |
| `DELETE /v1/workspace/doctree/folders/{folder}` | `?recursive=1` | 204; 409 `folder_not_empty {folders, documents}` |

The existing `GET /v1/workspace/doctree` (every document) stays for the omnibox
and search. The explorer stops using it, because at 10,000 documents it is
the whole list on every open.

### 2.7 Tests

| id | what | fails when |
|---|---|---|
| T1 store | create/rename/move/delete folder and document; recursive delete removes the documents, their items and rev log | any row survives or a count is off |
| T2 cycle | move a folder under its own grandchild: the store refuses (409), and raw SQL that skips the store is refused at commit by the trigger | either commits |
| T3 leaf | raw SQL inserting a node under a `doc` node is refused by the parent FK | it commits |
| T4 cap | bulk-insert 10,000 documents in one tenant (one statement, a few s), then the 10,001st: the DB raises on `workspace_doc_node_cap` and the hub answers 409 `doc_cap_reached` | 201 or 500 |
| T5 cap race | at 9,999, two transactions each create one document and commit: exactly 1 commits, 1 gets 409 | 2 commit (the draft's `count(*)` trigger fails this control; keep it as a planted-bug control) |
| T6 RLS negative | as the runtime login (non-owner, so FORCE binds), tenant a sees 0 of b's nodes; a node with `tenant_id = a` and b's parent or doc id is refused by the FK; a move into b's folder is 404; an unscoped session sees 0 rows; operator scope sees both | any cross-tenant read or write |
| T7 migration | in the `workspace-docs-migration.tst.sh` style: each document has one node, `doc_count` equals the count, a tenant at 10,001 makes the migration refuse with its id | silent pass |
| T8 hub | the routes of 2.6 with their 4xx codes, `rbac.DocsRead` refused on writes | a wrong status |
| T9 WUI e2e (mock bundle) | the context menu Delete, the non-empty-folder confirm with counts, the cap message in the new-document dialog | the message is missing |
| T10 timing | real ops (RLS + triggers) at 10,000 documents in shape N and F, n = 5, printed; fail above 50 ms per op (113's ceiling) | an op over 50 ms |

Postgres only (`PRE_PUSH_TIER=full`): this is a store and migration change.

## 3. Owner questions

Q3 is the one the panel must not decide; it goes to the owner as asked.

### Q1. Root: one hidden root per workspace, or several `parent_id = NULL` nodes?

- **A.** One hidden root per workspace (the draft).
- **B.** Several top-level nodes with `parent_id = NULL`.
- **Recommendation: A.** The root row is also the per-workspace lock and
  holds the cap counter (2.2), and the unique folder name per parent needs a
  non-NULL parent. B would need `NULLS NOT DISTINCT` plus a separate lock
  and counter row.

### Q2. Folder attributes: a name only, or a JSONB attributes column?

- **A.** A name only (the draft).
- **B.** A JSONB attributes column.
- **Recommendation: A**, plus `created_by` and `created_at`. A column can be
  added later, forward-only.

### Q3. The tree model: the nested set you asked for (msg ad20e44a), or adjacency?

Your words: "a hierarchical nested set table on its own in the database".
Both options give you the table on its own. They differ only in how the
hierarchy is stored.

- **A. Nested set** (`lft`, `rgt` per node), as you asked.
  - Reads a whole subtree with no recursion.
  - Every create, move or delete early in the tree rewrites the bounds of
    most rows. Measured at your 10,000 cap, n = 5: create 366-437 ms, move
    364-487 ms (section 1.1). Spec 113 measured the same at 11,111 items:
    234 / 216 ms.
  - One missed shift breaks the whole hierarchy. You wrote: "I could not get
    it work, the hierarchy got always broken" (msg baad764f).
- **B. Adjacency** (each node stores its parent; folders first, then by
  name).
  - Every create, move or delete writes one row: 0.13-0.19 ms at 10,000,
    1,000-3,000x less.
  - There are no stored positions, so there is nothing that can drift or
    break.
  - The explorer opens one folder at a time: 5.4 ms even for 10,000
    documents in one folder.
- **Recommendation of this seat: B.** At 10,000 documents the nested set's
  advantage (subtree reads) is not needed. Its cost is the failure you
  already lived through.
- A middle variant, adjacency **plus** a manual order, matters only if you
  want drag-to-reorder. It costs 159 ms per insert at the top of a
  10,000-document folder, so this seat proposes it only if you ask for
  manual order.

The editor collects each seat's recommendation into this question.

### Seat notes for the editor

- The WUI comment at `csi-spl-wui/src/components/workspace-docs/QtoFileTree.vue:4`
  calls spec 113's tree "nested-set"; 0157 is adjacency + ord
  (`grep -c 'adjacency list + sibling ordinal' csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql` -> 1).
  It is a one-word fix for whichever lane next edits that file, not this
  panel.

## 4. Appendix: the bench SQL (section 1.1)

The bench ran via `docker run -d --rm postgres:16-alpine`, then
`psql -U postgres -qAt -v ON_ERROR_STOP=1 < b.sql`.

```sql
CREATE TABLE ns (id int PRIMARY KEY, parent int, lft int NOT NULL, rgt int NOT NULL, kind char(1), name text);
CREATE INDEX ON ns(lft); CREATE INDEX ON ns(rgt); CREATE INDEX ON ns(parent);
CREATE TABLE ao (id int PRIMARY KEY, parent int REFERENCES ao(id), ord int NOT NULL, kind char(1), name text, UNIQUE(parent,ord) DEFERRABLE INITIALLY IMMEDIATE);
CREATE TABLE an (id int PRIMARY KEY, parent int REFERENCES an(id), kind char(1), name text);
CREATE INDEX ON an(parent, name);
CREATE SEQUENCE ids START 1000000;
CREATE FUNCTION ns_num(n int, p int, l int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE c record; r int := l + 1; k char(1); nm text;
BEGIN
 SELECT kind, name INTO k, nm FROM ao WHERE id = n;
 FOR c IN SELECT id FROM ao WHERE parent = n ORDER BY ord LOOP r := ns_num(c.id, n, r); END LOOP;
 INSERT INTO ns VALUES (n, p, l + 1, r + 1, k, nm);
 RETURN r + 1;
END $$;
CREATE FUNCTION build(shape text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE i int; j int; f int; s int;
BEGIN
 TRUNCATE ns; TRUNCATE ao CASCADE; TRUNCATE an CASCADE;
 INSERT INTO ao VALUES (1,NULL,1,'f','root'); INSERT INTO an VALUES (1,NULL,'f','root');
 IF shape='F' THEN
  INSERT INTO ao SELECT g+1,1,g,'d','doc'||lpad(g::text,5,'0') FROM generate_series(1,10000) g;
  INSERT INTO an SELECT g+1,1,'d','doc'||lpad(g::text,5,'0') FROM generate_series(1,10000) g;
 ELSE
  FOR i IN 1..10 LOOP f := 10+i*1000;
   INSERT INTO ao VALUES (f,1,i,'f','f'||i); INSERT INTO an VALUES (f,1,'f','f'||i);
   FOR j IN 1..10 LOOP s := f+j*10000+100000;
    INSERT INTO ao VALUES (s,f,j,'f','s'||j); INSERT INTO an VALUES (s,f,'f','s'||j);
    INSERT INTO ao SELECT s*1000+g, s, g,'d','doc'||g FROM generate_series(1,100) g;
    INSERT INTO an SELECT s*1000+g, s,'d','doc'||g FROM generate_series(1,100) g;
   END LOOP; END LOOP;
 END IF;
 PERFORM ns_num(1, NULL, 0);
 ANALYZE;
END $$;
CREATE FUNCTION ns_ins(par int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE pl int; BEGIN SELECT lft INTO pl FROM ns WHERE id=par FOR UPDATE;
 UPDATE ns SET rgt=rgt+2 WHERE rgt>pl; UPDATE ns SET lft=lft+2 WHERE lft>pl;
 INSERT INTO ns VALUES (nextval('ids'),par,pl+1,pl+2,'d','new'); END $$;
CREATE FUNCTION ao_ins(par int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN UPDATE ao SET ord=ord+1 WHERE parent=par; INSERT INTO ao VALUES (nextval('ids'),par,1,'d','new'); END $$;
CREATE FUNCTION an_ins(par int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO an VALUES (nextval('ids'),par,'d','new'); END $$;
CREATE FUNCTION ns_mv(x int, np int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE xl int; xr int; w int; pr int; d int;
BEGIN SELECT lft,rgt INTO xl,xr FROM ns WHERE id=x; w:=xr-xl+1;
 UPDATE ns SET lft=-lft, rgt=-rgt WHERE lft>=xl AND rgt<=xr;
 UPDATE ns SET lft=lft-w WHERE lft>xr; UPDATE ns SET rgt=rgt-w WHERE rgt>xr;
 SELECT rgt INTO pr FROM ns WHERE id=np;
 UPDATE ns SET lft=lft+w WHERE lft>=pr; UPDATE ns SET rgt=rgt+w WHERE rgt>=pr;
 d := pr - xl;
 UPDATE ns SET lft=-lft+d, rgt=-rgt+d, parent=CASE WHEN id=x THEN np ELSE parent END WHERE lft<0;
END $$;
CREATE FUNCTION ao_mv(x int, np int) RETURNS void LANGUAGE plpgsql AS $$
DECLARE op int; oo int; m int;
BEGIN SELECT parent,ord INTO op,oo FROM ao WHERE id=x;
 SELECT coalesce(max(ord),0)+1 INTO m FROM ao WHERE parent=np;
 SET CONSTRAINTS ALL DEFERRED;
 UPDATE ao SET parent=np, ord=m WHERE id=x;
 UPDATE ao SET ord=ord-1 WHERE parent=op AND ord>oo; END $$;
CREATE FUNCTION an_mv(x int, np int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN UPDATE an SET parent=np WHERE id=x; END $$;
CREATE FUNCTION t(q text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; ms numeric;
BEGIN
 BEGIN t0 := clock_timestamp(); EXECUTE q; ms := extract(epoch FROM clock_timestamp()-t0)*1000;
   RAISE EXCEPTION 'rb'; EXCEPTION WHEN raise_exception THEN NULL; END;
 RETURN round(ms,3);
END $$;
CREATE FUNCTION run(shape text, model text, q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE a numeric[] := '{}'; i int;
BEGIN PERFORM t(q); FOR i IN 1..5 LOOP a := a || t(q); END LOOP;
 RETURN format('%s %s %-28s median %s ms  runs %s', shape, model, q, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x) FROM unnest(a) x), a);
END $$;
SELECT build('N');
SELECT run('N','ns','SELECT ns_ins(111010)'); SELECT run('N','ao','SELECT ao_ins(111010)'); SELECT run('N','an','SELECT an_ins(111010)');
SELECT run('N','ns','SELECT ns_mv(111010,10010)'); SELECT run('N','ao','SELECT ao_mv(111010,10010)'); SELECT run('N','an','SELECT an_mv(111010,10010)');
SELECT run('N','ns','SELECT ns_mv(111010001,10010)'); SELECT run('N','ao','SELECT ao_mv(111010001,10010)'); SELECT run('N','an','SELECT an_mv(111010001,10010)');
SELECT build('F');
SELECT run('F','ns','SELECT ns_ins(1)'); SELECT run('F','ao','SELECT ao_ins(1)'); SELECT run('F','an','SELECT an_ins(1)');
SELECT run('F','an-read','SELECT count(*) FROM (SELECT id FROM an WHERE parent=1 ORDER BY kind DESC, name) z');
```

Raw runs (ms, n = 5 each):

- N ns ins {335.6, 366.5, 337.4, 366.9, 386.1}
- N ao ins {1.03, 1.00, 1.51, 2.31, 1.61}
- N an ins {0.148, 0.141, 0.165, 0.152, 0.146}
- N ns mv folder {328.6, 364.4, 341.7, 371.5, 586.7}
- N ao mv folder {0.70, 0.66, 0.97, 0.58, 0.61}
- N an mv folder {0.228, 0.186, 0.193, 0.186, 0.180}
- N ns mv doc {447.1, 445.5, 486.6, 537.5, 566.8}
- N ao mv doc {1.27, 1.61, 1.25, 1.34, 1.65}
- N an mv doc {0.161, 0.152, 0.172, 0.141, 0.133}
- F ns ins {367.2, 454.0, 397.8, 437.1, 451.3}
- F ao ins {158.7, 163.3, 149.6, 155.8, 169.4}
- F an ins {0.176, 0.135, 0.126, 0.138, 0.132}
- F an read {5.60, 5.73, 5.27, 5.43, 5.32}
