# Spec 120: Qto document tree (workspace file explorer)

Version **v1.0-rc** (2026-10-10). The panel fold by the editor (seat
s120-claude, c-748) of a-796's draft v0.1 (77ffc9f8c, 54 lines). The four
seat files are under [reviews/](reviews/); section 10 records what each one
changed. The tree model is **not** decided here: it is owner question 1
(section 11), asked with the measured numbers.

## 0. Owner asks (verbatim, HUM-10, t1 topic 91289b0a)

- msg ad20e44a: "Also, this file system becomes kind of a replication of a
  file system, which could be a hierarchical nested set table on its own in
  the database."
- msg a14e799f: "We could design everything to cap it at no more than
  10,000 documents."
- msgs 635c2125 + 500ca8f5: a right-click menu on each document (Delete,
  Edit, more). Lane c-744 builds the menu; this spec gives it the routes
  (section 7).
- msg f5bc3948: remove the existing documents. c-001 does that on t1 prd,
  before the migration (section 6).

## 1. Goals

- The Qto file explorer (the folders and documents of a workspace) gets its
  own tree table in the database (msg ad20e44a). How that table stores the
  hierarchy (a nested set, as the owner wrote, or adjacency) is **owner
  question 1**. The panel recommends but does not decide it.
- At most **10,000 documents per workspace** (msg a14e799f), enforced by the
  database and answered by the hub with a clear error that the WUI shows.
- The context menu (lane c-744) gets delete, rename and move for documents
  and folders.
- Spec 113's document content (`workspace_doc`, `workspace_doc_item`, rdb
  0157) is unchanged. This spec adds the explorer around it.

## 2. Facts from the code (origin/master, 2026-10-10)

Each comes with the command that checks it.

- F1. **The workspace is the tenant; there is no `workspace_id` column.**
  `grep -n "so there is no separate workspace_id" csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql`
  -> 1 line. Every column below is `tenant_id` (text, `tenants (tenant_id)`).
- F2. **The explorer today lists at most 200 documents, all at once.**
  `grep -n "docTreeListMax  = 200" csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_tree.go`
  -> line 62. `QtoFileTree.vue` draws the whole list as depth-0 rows. At
  10,000 the explorer must load one folder's children at a time.
- F3. **No route deletes a document.**
  `grep -n '"DELETE ' csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_tree.go`
  -> 1 line, the item-subtree route. The context menu's Delete and the purge
  both need one (section 7).
- F4. **The hub already answers 413 `doc_too_large`**, for the
  whole-document read limit:
  `grep -n doc_too_large csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_tree.go`
  -> 1. The cap must not reuse 413.
- F5. **Spec 114 (v0.2, not built)** keeps documents private per workspace
  and shares across workspaces by a grant. A shared-in document is another
  tenant's row.
- F6. Prd runs POSTGRES_16:
  `grep -n database_version csi-spl-cnf/csi-spl/all.env.yaml`.

## 3. Tree model: the measurement (input to owner question 1)

The draft quoted spec 113's bench. That bench is for one document's item
tree (fanout 10). The explorer has a different shape: after the migration,
every document sits flat under the root. Both benches are below.

**Spec 113** ([bench/result-2026-10-08.md](../113-workspace-docs-qto/bench/result-2026-10-08.md),
landed 9257ed1e3): PostgreSQL 16.15, n = 5, median, load ~12 on 16 cores,
11,111 items, fanout 10:

| model | insert early | move subtree | read subtree |
|---|---:|---:|---:|
| nested set | 234.4 ms | 215.5 ms | 2.2 ms |
| adjacency + ord | 0.77 ms | 0.98 ms | 5.2 ms |

**Explorer shape** (seat s120-claude-2, [reviews/s120-claude-2.md](reviews/s120-claude-2.md)
section 1.1, SQL in its section 4): throwaway `postgres:16-alpine`, tree
77ffc9f8c, n = 5 after one warm-up, median, load ~27, no RLS and no
triggers, so these are lower bounds. The two shapes:

- **N**: root -> 10 folders -> 10 subfolders -> 100 documents each
  (10,000 documents).
- **F**: 10,000 documents flat under the root.

| op | shape | nested set | adjacency + ord | adjacency, by name |
|---|---|---:|---:|---:|
| create document | N | 366.5 ms | 1.51 ms | 0.15 ms |
| move folder (100 docs) | N | 364.4 ms | 0.66 ms | 0.19 ms |
| move document | N | 486.6 ms | 1.34 ms | 0.15 ms |
| create, first of 10,000 siblings | F | 437.1 ms | 158.7 ms | 0.14 ms |
| read one folder's children (10,000) | F | - | - | 5.43 ms |

How to read it:

- Differences under 2 ms are noise at this load; only the 100-3,000x gaps
  carry a conclusion.
- Speed alone does not rule the nested set out at this cap. About 0.4 s per
  human-driven write is tolerable (seat s120-claude section 2).
- What weighs against the nested set is integrity and locking:
  - Every write renumbers `lft`/`rgt` across up to the whole workspace, so
    every write locks the whole workspace.
  - Its "no gap, no overlap" rule is a full-table scan, never a constraint.
  - That class of failure broke the owner's own build (spec 113 section 3.6,
    defects D1-D9; owner msgs 7370f63e, baad764f).
- **Adjacency ordered by name** (folders first, then alphabetical, as a file
  system shows them) stores no position at all. A write is one row, nothing
  can drift, and the wide-root cost of `ord` (158.7 ms) does not exist.
  A manual order (`ord`) can be added later, forward-only, if the owner asks
  for drag-to-reorder.

Sections 4-9 are written for **option B, adjacency ordered by name**, the
recommendation of all four seats (section 10). If the owner picks A (nested
set), section 4.4 lists what A must add.

## 4. The table

### 4.1 `workspace_doc_node`

One row per folder and per document, plus one hidden root per workspace.
A document keeps its header in `workspace_doc` (0157, unchanged); its node
points at it 1:1. Rdb file `01NN_workspace_doc_node.sql`, the next free
number at build time (0164 is the last today).

```sql
CREATE TABLE workspace_doc_node (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    parent_id   uuid        NULL,
    kind        text        NOT NULL CHECK (kind IN ('root', 'folder', 'doc')),
    parent_kind text        NULL,
    name        text        NOT NULL DEFAULT '',
    doc_id      uuid        NULL,
    doc_count    integer    NOT NULL DEFAULT 0,
    folder_count integer    NOT NULL DEFAULT 0,
    created_by  text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 200),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_node_tenant_id UNIQUE (tenant_id, id, kind),
    CONSTRAINT workspace_doc_node_shape CHECK (
        (kind = 'root'   AND parent_id IS NULL     AND doc_id IS NULL     AND name = '')
     OR (kind = 'folder' AND parent_id IS NOT NULL AND doc_id IS NULL     AND length(name) BETWEEN 1 AND 255)
     OR (kind = 'doc'    AND parent_id IS NOT NULL AND doc_id IS NOT NULL AND name = '')),
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
CREATE INDEX workspace_doc_node_children ON workspace_doc_node (tenant_id, parent_id, kind, lower(name));
```

Why each piece:

- **The parent FK carries the tenant and the parent's kind.** A node can
  only hang under a root or folder of its own workspace, so a document is a
  leaf, enforced by the FK with no trigger. FK checks bypass RLS (spec 113
  seat 5, measured), which is why the tenant is in the key. The FK is NO
  ACTION (checked at statement end), so a recursive delete in one statement
  passes (section 5).
- **A document's name is `workspace_doc.title`**, one place with no drift.
  The node's `name` is `''` for a document. Two documents with the same
  title in one folder stay allowed, as today. Folder names are unique per
  parent, case-insensitive.
- **The root row** holds the counters (section 4.2) and is the
  per-workspace lock (section 5).
- The name ordering is `kind` then `lower(name)`. The children index covers
  it for folders; documents sort by their title, joined from `workspace_doc`.

### 4.2 The caps

| what | cap | where |
|---|---|---|
| documents per workspace | **10,000** (owner, msg a14e799f) | `doc_count` on the root, `workspace_doc_node_cap` |
| folders per workspace | 1,000 (panel proposal, section 11 item 4) | `folder_count` on the root, `workspace_doc_node_folder_cap` |
| folder depth | 32 (panel proposal) | the store, plus the deferred tree trigger (4.3) |

- **DB, the authority.** A row trigger `AFTER INSERT OR DELETE ON
  workspace_doc_node` keeps the root's counters with
  `UPDATE .. SET doc_count = doc_count ± 1` (folder nodes: `folder_count`).
  - The UPDATE takes the root's row lock, so two concurrent creates queue
    on it. Under READ COMMITTED the second re-reads the committed count and
    its CHECK fails at 10,001. A `count(*)` trigger (the draft) cannot do
    this: two transactions at 9,999 both pass.
  - The trigger is O(1) per insert.
  - A move never changes a counter. A recursive delete may decrement once
    by k.
- **Hub, the fast path.** A create reads the counter first and at the cap
  answers **409 `doc_cap_reached`** `{limit: 10000, count}`. It also maps
  the DB's `check_violation` on `workspace_doc_node_cap` to the same 409, so
  a race that slips past the read still gets the right answer, not a 500.
  Folders get 409 `folder_cap_reached`. The cap is never 413 (F4).
- **WUI.**
  - The new-document dialog and the context menu's New document show the
    409 inline and keep the dialog open: "This workspace has reached its
    10,000-document limit. Delete documents to add new ones."
  - The text is one i18n key, in every locale. agy reviews it last (language
    rule).
  - From 9,000 documents on, the explorer footer shows `n / 10,000`.
  - There is no client-only check.

### 4.3 Invariants and how the DB holds them

| invariant | held by |
|---|---|
| one root per workspace | `workspace_doc_node_one_root` + the shape CHECK |
| one parent, of the same workspace, never a document | parent FK (tenant, id, kind) |
| every `workspace_doc` has exactly one node | `workspace_doc_node_one_place` + deferred trigger `workspace_doc_node_required` (AFTER INSERT ON workspace_doc, the 0157 `root_required` pattern) |
| no cycle, depth <= 32 | deferred constraint trigger `workspace_doc_node_tree` (AFTER UPDATE OF parent_id). It locks the root row, then walks from the moved node to the root; meeting the node again, or more than 32 steps, raises |
| counters = real counts | the counter trigger; checked by `do_spl_doc_tree_check` (section 6) |

### 4.4 If the owner picks A (nested set)

Then add `lft`, `rgt` (NOT NULL, `CHECK (lft < rgt)`) to the table, and
keep `parent_id`. The sibling project's defect D1 was guessing the parent,
so `parent_id` stays. Also:

- every write locks the root row first (D4);
- a deferred full-scan check of "no gap, no overlap" (D3), the same in
  `do_spl_doc_tree_check`;
- the property test (section 9) after every op;
- the measured ~0.4 s per write accepted as the cost.

## 5. Operations

Every structural op is one transaction that first locks the workspace's
root row `FOR UPDATE`. Explorer writes are rare and human-driven, so
serialising them per workspace costs nothing measurable.

| op | rule | refusals |
|---|---|---|
| create document | `workspace_doc` + its 0157 root item + its node, one transaction; optional `parent` (default the root) | 409 `doc_cap_reached` |
| create folder | `{parent, name}` | 409 `name_taken`, `folder_cap_reached`, depth over 32 |
| rename folder | `UPDATE name` | 409 `name_taken` |
| rename document | the existing `PATCH /v1/workspace/doctree/{doc}` (title, rev-checked) | 412 stale rev |
| move | `UPDATE parent_id` of one node: a folder moves with its subtree, a document alone; counters unchanged | 409 `move_into_own_subtree` (the store checks first, the trigger is the backstop); 400 parent is a document (the FK holds it too); 409 depth |
| delete document | `DELETE FROM workspace_doc`: 0157 cascades its items and rev log, the node cascades by `doc_id`, the counter decrements | 404 |
| delete folder, empty | delete the node | - |
| delete folder, not empty | **409 `folder_not_empty` `{folders, documents}`** unless `?recursive=1` | - |
| delete folder, `?recursive=1` | one transaction: (1) the subtree by recursive CTE (<= 11,000 rows); (2) delete those documents' `workspace_doc` rows (cascade); (3) delete the subtree's folders in ONE statement (NO ACTION FK passes at statement end); one hub log line with actor and counts | - |
| delete root | never: refused by the store; the one-root index and the root-required trigger hold it | 400 |

There is no trash in v1.0: a deleted document's rev log goes with it. The
WUI confirms every delete. For a non-empty folder it shows the counts:
"Delete folder X, 3 folders and 41 documents?"

**Spec 114 sharing.** A document shared into workspace B stays a node of
its own workspace A only; the composite FKs make a cross-tenant node
impossible. B's explorer may show shared documents in a virtual "Shared
with this workspace" group, read through spec 114's own call, never as a
row of B's `workspace_doc_node`. From B, moving, renaming or deleting a
shared document is refused. The node table gets no 114 share policy, so
its isolation stays a pure tenant fence.

## 6. Migration from today's `workspace_doc`

Order, each step deployed on dev and prd before the next:

1. **The t1 purge** on prd (msg f5bc3948, c-001). t1 then has 0 documents.
   Every other workspace keeps its rows, so the migration still handles them.
2. **rdb, forward-only, one transaction:**
   1. Create the table, indexes, the counter trigger, the tree trigger and RLS.
   2. Refuse, naming the tenants, if any workspace holds more than 10,000
      documents: `SELECT tenant_id, count(*) FROM workspace_doc GROUP BY 1 HAVING count(*) > 10000`
      must return 0 rows. The build lane reads the prd count first, operator
      scope, read-only.
   3. Insert one `root` per tenant that has documents.
   4. Insert one `doc` node per `workspace_doc` under that tenant's root.
      No ordering is needed: order is by name at read.
   5. Set the root's `doc_count` from those rows and assert it equals the
      count.
3. **The hub** that creates the node in the same transaction as the
   document (the store's `DocCreate` gains it). New workspaces get their
   root lazily: the first create inserts it under `ON CONFLICT DO NOTHING`
   on the one-root index.
4. **rdb, the second migration:** the deferred `workspace_doc_node_required`
   trigger. It ships only after step 3 is live on dev and prd. An older hub
   between steps 2 and 3 still creates a document without a node, and
   would fail at commit if the trigger came in step 2.
5. **The WUI** switches the explorer to the per-folder route (section 7).

`do_spl_doc_tree_check` (spec 113 section 3.4) gains the node checks:

- every document has one node;
- the counters equal the real counts;
- no node is deeper than 32;
- no cycle.

It runs under operator scope and exits 2 on 0 tenants.

## 7. Hub API (the explorer and the context menu)

Under the existing `/v1/workspace/doctree` prefix, with the same caller rule
(`docTreeCaller`): `docs.read` for GET, `docs.write` for the rest. The
412/404/422 mapping is today's.

| route | body / query | answers |
|---|---|---|
| `GET /v1/workspace/doctree/nodes` | `?parent=` (none = root), keyset `?after=`, limit 200 | one folder's children, folders first then by name: `{id, kind, name or title, doc, child_count}`; the explorer's only list call (F2) |
| `GET /v1/workspace/doctree/nodes/{node}/path` | | the ancestors: the breadcrumb, and opening a document deep in the tree |
| `POST /v1/workspace/doctree` | gains optional `parent` | 201; 409 `doc_cap_reached` |
| `POST /v1/workspace/doctree/folders` | `{parent, name}` | 201; 409 `name_taken`, `folder_cap_reached`, depth |
| `PATCH /v1/workspace/doctree/folders/{folder}` | `{name}` | 200; 409 `name_taken` |
| `POST /v1/workspace/doctree/nodes/{node}/move` | `{parent}` | 200; 409 `move_into_own_subtree`; 400 parent is a document |
| `DELETE /v1/workspace/doctree/{doc}` | | 204; the context menu's Delete for a document (closes F3) |
| `DELETE /v1/workspace/doctree/folders/{folder}` | `?recursive=1` | 204; 409 `folder_not_empty {folders, documents}` |

The existing `GET /v1/workspace/doctree` (max 200) stays for the CLI, the
omnibox and search; the explorer stops using it. Lane c-744's menu calls the
`DELETE` routes above once they exist and does not grow a second delete path.

## 8. RLS

On `workspace_doc_node`, the 0157 shape:

- ENABLE **and FORCE** row level security;
- `tenant_scope` with `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')`
  in USING and WITH CHECK;
- `operator_scope`.

The store reaches the table only through `inTenant` / `asOperator`. Runtime
grants go in `spool-hub-roles/runtime-grants.sql`.
`TestRLSCoversEveryTenantTable` and `TestCrossTenantEveryTable` pick the
table up by its `tenant_id` column.

## 9. Tests

Store and migration tests run on Postgres (`PRE_PUSH_TIER=full`).

| id | what | fails when |
|---|---|---|
| T1 store | create, rename, move and delete for folders and documents; a recursive delete removes the documents, their items and rev logs (counts before and after) | a row survives or a count is off |
| T2 cycle | move a folder under its own grandchild: the store answers 409; raw SQL that skips the store is refused at commit by the trigger | either commits |
| T3 leaf | raw SQL inserting a node under a `doc` node is refused by the parent FK | it commits |
| T4 cap | bulk-insert 10,000 documents in one workspace, then the 10,001st: the DB raises `workspace_doc_node_cap` and the hub answers 409 `doc_cap_reached`; delete one and the next create succeeds; the same for 1,000 folders | 201 or 500 |
| T5 cap race | at 9,999, two concurrent creates: exactly one 201 and one 409, and counter = `count(*)` = 10,000. **Control:** the draft's `count(*)` trigger lets both through at least once in 50 tries | both commit, or the control never fails |
| T6 RLS negative | as the runtime login (non-owner, so FORCE binds): tenant a sees 0 of b's nodes; a node with `tenant_id = a` and b's parent or document id is refused by the FK; a move into b's folder is 404; an unscoped session sees 0 rows; operator scope sees both. **Control:** in a throwaway DB, an FK without the tenant column lets the cross-tenant insert through | any cross-tenant read or write, or the control passes |
| T7 migration | in the `workspace-docs-migration.tst.sh` style: every document has one node, `doc_count` equals the count, a workspace at 10,001 makes the migration refuse with its id | a silent pass |
| T8 hub | the section 7 routes with their 4xx codes; `docs.read` refused on writes | a wrong status |
| T9 property | 1,000 random ops (spec 113 section 3.5 pattern), after each: one root, no cycle, every document one node, counters = counts | any invariant breaks |
| T10 WUI e2e (mock bundle) | expanding a folder loads only its children; the context menu's Delete; the non-empty-folder confirm with counts; the cap message in the new-document dialog | a message is missing |
| T11 timing | the real ops (RLS + triggers) at 10,000 documents in shapes N and F, n = 5, printed; fail above 50 ms per op (spec 113's ceiling) | an op over 50 ms |

## 10. Panel and consensus

Seats, all signed against 77ffc9f8c, each commit touching only its own file
(`git show --stat <sha>`, checked by the editor):

| seat | agent | commit | file |
|---|---|---|---|
| s120-claude (editor) | c-748 | 8b8defb98 | [reviews/s120-claude.md](reviews/s120-claude.md) |
| s120-claude-2 | c-749 | c699d0dee | [reviews/s120-claude-2.md](reviews/s120-claude-2.md) |
| s120-mistral | m-750 | 23a3b4691 | [reviews/s120-mistral.md](reviews/s120-mistral.md) |
| s120-agy | a-797 | f1e285629 | [reviews/s120-agy.md](reviews/s120-agy.md) |

**Agreed by all four** (in the spec as drafted, or extended):

- its own tree table; a single hidden root per workspace; folders carry a
  name only;
- RLS in the 0157 shape with tenant-carrying composite FKs;
- the migration runs after the t1 purge and puts today's documents under
  the root;
- the cap is enforced both in the hub and in the DB, with a WUI message;
- the recommendation on the tree model is adjacency (B), not the nested
  set.

**Changed from the draft, and settled by the panel** (who raised it; why it
holds):

| point | draft / some seats | settled | raised by | why |
|---|---|---|---|---|
| tenant column | `workspace_id` (draft, mistral) | `tenant_id` text | claude, claude-2 | F1: the column does not exist |
| cap status | 413 (draft, mistral, agy) | 409 `doc_cap_reached` | claude, claude-2 | 413 is a body-size status and is already `doc_too_large` (F4) |
| cap check | deferred `count(*)` trigger (draft, mistral, agy) | counter on the root row under a CHECK | claude, claude-2 | `count(*)` races under READ COMMITTED; T5 is its control |
| sibling order | `ord` (draft, mistral, agy) | none: folders first, by name | claude, claude-2 | file-system order; `ord` costs 158.7 ms at the migrated flat root; manual order can come later. The owner sees this choice inside question 1 (option B) |
| non-empty folder delete | cascade (mistral, agy) | 409 unless `?recursive=1`, the WUI confirms with counts | claude, claude-2 | an unconfirmed cascade loses up to 10,000 documents on one click |
| parent FK action | CASCADE (mistral) | NO ACTION, recursive delete in one statement | claude-2 | a cascade bypasses the confirm; RESTRICT refuses the one-statement delete |
| document is a leaf | not held (all) | parent FK on `(tenant, id, kind)` | claude-2 | no trigger needed |
| folder cap, depth | none | 1,000 folders, depth 32 | claude, claude-2 | bounds the lazy reads and the cycle walk; stated to the owner (11.4) |
| list route | the flat list | per-folder `GET .../nodes` | claude, claude-2 | F2: 200-row list vs 10,000 cap |
| document delete route | none | `DELETE /v1/workspace/doctree/{doc}` | claude, claude-2 | F3 |
| shared documents | not covered | a virtual group, never a node | claude, claude-2 | F5 |
| node-required trigger | n/a | second migration, after the hub | claude | an older hub would fail at commit |
| route shape | `/api/workspace/:id/...` (mistral, agy) | under `/v1/workspace/doctree` | claude, claude-2 | the hub's existing prefix; the tenant comes from the caller, never the URL |

Editor's note on the seats: the mistral file's signature is on line 3, not
line 1 (`git show 23a3b4691:csi-spl-doc/specs/120-qto-doc-tree/reviews/s120-mistral.md | head -3`).
Its content is signed against 77ffc9f8c, so it is accepted as is.

**Signatures on this version** (each seat confirms it on dispatch-91289b0a):

| seat | signed |
|---|---|
| s120-claude | pending |
| s120-claude-2 | pending |
| s120-mistral | pending |
| s120-agy | pending |

## 11. Owner questions

1. **The tree model: a nested set, as you asked (msg ad20e44a), or
   adjacency?** Both give the explorer its own table; they differ only in
   how the hierarchy is stored.
   - **A. Nested set** (`lft`, `rgt` per node):
     - it reads a whole subtree with no recursion;
     - every create or move rewrites the bounds of most rows: measured at
       your 10,000 cap, create 366-437 ms and move 364-487 ms (section 3,
       n = 5);
     - every write locks the whole workspace;
     - one missed shift breaks the hierarchy, the failure you described
       (msgs 7370f63e, baad764f).
   - **B. Adjacency** (each node stores its parent):
     - every create or move writes one row, 0.14-0.19 ms at 10,000;
     - the database itself enforces one parent, one root and no cycle;
     - folders and documents sort by name, as in a file system;
     - opening a folder of 10,000 documents takes 5.4 ms;
     - a manual order (drag-to-reorder) is an extra `ord` column. It costs
       158.7 ms per insert at the top of a 10,000-document folder, so it is
       added only if you want it.
   - **Recommendation of every seat: B.**
     - s120-claude and s120-claude-2: B ordered by name.
     - s120-mistral and s120-agy: B with `ord`.
     - The panel settled on by-name (section 10). Say if you want manual
       order.
2. **Root: one hidden root per workspace, or several top-level nodes?**
   (draft Q1)
   - A. One hidden root: it is also the workspace's lock and holds the cap
     counter.
   - B. Several nodes with no parent.
   - **Recommendation of all four seats: A.**
3. **What does a folder carry?** (draft Q2)
   - A. A name only (plus who created it and when).
   - B. A name and free attributes (colour, description).
   - **Recommendation of all four seats: A.** A column can be added later.
4. **For the record, not a question:** beside your 10,000 documents, the
   panel caps a workspace at 1,000 folders and 32 levels of depth. Say
   otherwise if you want different limits.
