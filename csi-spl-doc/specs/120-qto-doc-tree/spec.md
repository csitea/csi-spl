# Spec 120: Qto document tree (workspace file explorer)

Version **v1.0-rc2** (2026-10-10). The panel fold by the editor (seat
s120-claude, c-748) of a-796's draft v0.1 (77ffc9f8c, 54 lines). The four
seat files are under [reviews/](reviews/); section 10 records what each one
changed. The owner answered all three questions (section 11). The tree is a
**nested set** by his decision (msg d44d08f8), against the panel's
recommendation. The rc e6b1652a4 was written for adjacency; rc2 rewrites
sections 4-9 for the nested set.

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
  own tree table in the database (msg ad20e44a), a **nested set** (owner,
  msg d44d08f8), guarded so that it cannot break the way his earlier build
  did (sections 4.3, 5, 9).
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
- What weighs against the nested set is integrity:
  - Every write renumbers `lft`/`rgt` across up to the whole workspace
    (~20,000 bounds at the cap).
  - Locking is NOT a difference: both models serialise structural writes
    per workspace on the root row (section 5). The nested set holds that
    lock ~0.4 s per write, adjacency ~0.2 ms (seat s120-claude-2's
    objection on the rc, folded in rc2).
  - Its "no gap, no overlap" rule is a full-table scan, never a constraint.
  - That class of failure broke the owner's own build (spec 113 section 3.6,
    defects D1-D9; owner msgs 7370f63e, baad764f).
- **Adjacency ordered by name** (folders first, then alphabetical, as a file
  system shows them) stores no position at all. A write is one row, nothing
  can drift, and the wide-root cost of `ord` (158.7 ms) does not exist.
  A manual order (`ord`) can be added later, forward-only, if the owner asks
  for drag-to-reorder.

**Decision: A, the nested set (owner, msg d44d08f8, verbatim: "1. A stil l ,
because we will add more completely new features , such as the file system
becomes it sown doc for eexample ... in the future").** All four seats
recommended B; the owner chose A for future features, for example the file
system becoming its own document. That use needs document order over the
whole tree, which `lft` gives. Sections 4-9 are written for the nested set.
They carry every integrity guard the panel can add against defects D1-D9 of
spec 113 section 3.6, because those are the failures the owner met in his
own build. The cost the owner accepted: ~0.4 s per structural write at
10,000 documents, with the workspace lock held for that time (section 3
table).

## 4. The table

### 4.1 `workspace_doc_node`

One row per folder and per document, plus one hidden root per workspace
(owner, msg 90b4dc96: "2. A"). A document keeps its header in
`workspace_doc` (0157, unchanged); its node points at it 1:1. Rdb file
`01NN_workspace_doc_node.sql`, the next free number at build time (0164 is
the last today).

```sql
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
```

Why each piece:

- **`lft`, `rgt`: the nested set the owner chose.** A node's subtree is
  every row with `lft` between its `lft` and `rgt`. Its ancestors are the
  rows whose interval encloses it. Document order over the whole tree is
  `ORDER BY lft`.
- **`parent_id` is kept beside the bounds.** The sibling project guessed the
  parent from `level` and `min(rgt)` (defect D1). Here the parent is a
  column with an FK, and the commit check (4.3) proves it agrees with the
  bounds.
- **The bound CHECKs are what a row can hold alone.** They cover
  `lft < rgt`, an odd width, a document of width 1 (a leaf: the sibling's
  width-4 leaf, D2, is refused), and the root at 1. NOT NULL everywhere is
  D9.
- **`lft` and `rgt` are each unique per workspace, deferred.** A shift
  rewrites many rows in several statements, so uniqueness is checked at
  commit.
- **The parent FK carries the tenant and the parent's kind.** A node hangs
  only under a root or folder of its own workspace (FK checks bypass RLS,
  spec 113 seat 5, measured). Its action is NO ACTION, checked at statement
  end, so a subtree deleted in one statement passes (section 5).
- **Name, Title and Description** (owner, msg 2b5a1ad4: "when using the
  nested set it could contain anything , but let's use for now Name , Title
  and Descrption").
  - A folder carries all three. `name` is the explorer label, unique per
    parent and case-insensitive. `title` is an optional longer heading (''
    = show the name). `description` is plain text up to 1,000 characters,
    the same limit as 0164's document description.
  - A document node keeps all three empty, because they already live on
    `workspace_doc` (`title`; `description` from 0164). One place, no drift:
    the explorer shows the document's own title.
  - "It could contain anything" later: a further column is a forward-only
    migration, and the nested set is unaffected.
- **The root row** holds the counters (4.2) and is the workspace lock
  (section 5).

### 4.2 The caps

| what | cap | where |
|---|---|---|
| documents per workspace | **10,000** (owner, msg a14e799f) | `doc_count` on the root, `workspace_doc_node_cap` |
| folders per workspace | 1,000 (panel proposal, section 11 item 4) | `folder_count` on the root, `workspace_doc_node_folder_cap` |
| folder depth | 32 (panel proposal) | the commit check (4.3) |

At the caps a workspace holds at most 11,001 nodes, so `rgt` is at most
22,002.

- **DB, the authority.** A row trigger `AFTER INSERT OR DELETE ON
  workspace_doc_node` keeps the root's counters with
  `UPDATE .. SET doc_count = doc_count ± 1` (folders: `folder_count`).
  - Every op already holds the root row (section 5), so two creates queue on
    it, and the second's CHECK fails at 10,001.
  - A `count(*)` trigger (the draft) races: two transactions at 9,999 both
    pass it.
  - A move never changes a counter. A subtree delete decrements once by k.
- **Hub, the fast path.** A create reads the counter first and at the cap
  answers **409 `doc_cap_reached`** `{limit: 10000, count}`. It also maps
  the DB's `check_violation` on `workspace_doc_node_cap` to the same 409, so
  a race that slips past the read gets the right answer, not a 500.
  Folders get 409 `folder_cap_reached`. The cap is never 413 (F4).
- **WUI.**
  - The new-document dialog and the context menu's New document show the
    409 inline and keep the dialog open: "This workspace has reached its
    10,000-document limit. Delete documents to add new ones."
  - The text is one i18n key in every locale, reviewed last by agy (language
    rule).
  - From 9,000 documents on, the explorer footer shows `n / 10,000`.

### 4.3 Invariants and how the DB holds them

A nested set's main invariant cannot be a constraint: the bounds of a
workspace must be exactly 1..2n, properly nested, and agree with
`parent_id`. So the DB checks it at commit, once per workspace per
transaction, by a full ordered pass. That is D3 of spec 113 section 3.6: the
sibling's own seeded tree broke the invariant and nothing noticed.

| invariant | held by |
|---|---|
| one root per workspace, at `lft = 1` | `workspace_doc_node_one_root` + `root_lft` CHECK + the commit check (root `rgt = 2n`) |
| bounds well formed per row | `workspace_doc_node_bounds`, `_leaf` CHECKs |
| no bound used twice | `_lft_once`, `_rgt_once` (deferred UNIQUE) |
| bounds are exactly 1..2n, properly nested, no crossing; the enclosing interval of each node is its `parent_id`; depth <= 32 | deferred constraint trigger `workspace_doc_node_ns` (below) |
| a parent is a root or folder of the same workspace | parent FK (tenant, id, kind) |
| every `workspace_doc` has exactly one node | `workspace_doc_node_one_place` + deferred trigger `workspace_doc_node_required` (AFTER INSERT ON workspace_doc, the 0157 `root_required` pattern) |
| counters = real counts | the counter trigger; also `do_spl_doc_tree_check` (section 6) |

**`workspace_doc_node_ns`**, a deferred constraint trigger AFTER INSERT OR
UPDATE OF lft, rgt, parent_id OR DELETE:

1. Lock the workspace's root row `FOR UPDATE`. A writer that skipped the
   lock waits here (D4).
2. Run once per workspace per firing statement. It uses the
   statement-stamped transaction-local key of 0157's
   `workspace_doc_item_tree`, so a 10,000-row shift checks once, not 10,000
   times.
3. Walk every bound of the workspace in order: the `lft` and `rgt` of each
   node, `ORDER BY bound`, with a stack:
   - **On an `lft`:** the bound must be the previous bound + 1. The stack's
     top must be the node's `parent_id` (an empty stack only for the root).
     Push the node; the stack depth must stay <= 33 (the root plus 32
     levels).
   - **On an `rgt`:** the bound must be the previous bound + 1, and the
     stack's top must be this node. Pop it.
   - **At the end:** the stack is empty, and the last bound is 2 x
     `count(*)`.
4. Any break raises `check_violation` with `CONSTRAINT =
   'workspace_doc_node_ns'`, naming the node and the bound. The whole
   transaction rolls back, so a broken shift is never committed.

The pass reads at most 22,002 bounds from the `(tenant_id, lft)` index. Its
cost is measured in T11 and added to the ~0.4 s write.

## 5. Operations

Every structural op is ONE transaction in the store. It locks the
workspace's root row `FOR UPDATE` first, then does the arithmetic below
with pgx bind parameters (never SQL text built from ids, D7). Every op ends
in one of four outcomes: done, a 4xx refusal, 412 stale, or a 500 with the
check's constraint name logged. Nothing is swallowed (D6). The shifts
are the textbook ones and the bench's (`ns_ins`, `ns_mv` in
[reviews/s120-claude-2.md](reviews/s120-claude-2.md) section 4).

| op | the nested-set write (`w` = subtree width = `rgt - lft + 1`) | refusals |
|---|---|---|
| create document / folder under P (a folder: `{name, title, description}`) | append as P's last child: `r := P.rgt`; `UPDATE .. SET rgt = rgt + 2 WHERE rgt >= r`; `UPDATE .. SET lft = lft + 2 WHERE lft > r`; insert `(r, r + 1)`. A document create also inserts `workspace_doc` and its 0157 root item, same transaction | 409 `doc_cap_reached`, `folder_cap_reached`, `name_taken`, depth |
| edit folder | `UPDATE name, title, description`; no bounds change | 409 `name_taken`; 400 over a length limit |
| rename document | the existing `PATCH /v1/workspace/doctree/{doc}` (title, rev-checked); no bounds change | 412 stale rev |
| move X under P (as last child) | refuse if `X.lft <= P.lft <= X.rgt` (into its own subtree); negate X's subtree, close its gap (`- w` above `X.rgt`), open a gap at P's (re-read) `rgt` (`+ w`), un-negate with the offset, set X's `parent_id`; counters unchanged | 409 `move_into_own_subtree`; 400 parent is a document; 409 depth |
| delete document X | `DELETE FROM workspace_doc` (0157 cascades items and rev log, the node cascades by `doc_id`), then close the gap: `- 2` on bounds above `X.rgt` | 404 |
| delete folder, empty | delete the node, close the gap (`- 2`) | - |
| delete folder, not empty | **409 `folder_not_empty` `{folders, documents}`** unless `?recursive=1` | - |
| delete folder, `?recursive=1` | (1) the subtree is `lft BETWEEN X.lft AND X.rgt`, no recursion; (2) delete those documents' `workspace_doc` rows (cascade); (3) delete the subtree's folders in ONE statement (NO ACTION FK passes at statement end); (4) close the gap: `- w` above `X.rgt`; one hub log line with actor and counts | - |
| delete root | never: refused by the store; the one-root index and the commit check hold it | 400 |

**Order shown in the explorer.** The tree's own order is `lft`: a new node
is appended as its parent's last child, and a move appends too. The
explorer shows a folder's children folders first, then by name (the file
system view, sorted at read). `?order=tree` returns `lft` order, which is
what the future "file system as its own doc" view will read (owner, msg
d44d08f8). A rename never moves bounds.

**Concurrency.** All structural writes of one workspace queue on its root
row, each holding it ~0.4 s at 10,000 documents (section 3). Two people
creating at once wait at most about one write each. Reads never take the
lock.

There is no trash in v1.0. The WUI confirms every delete, and for a
non-empty folder it shows the counts.

**Spec 114 sharing.** A document shared into workspace B stays a node of
its own workspace A only; the composite FKs make a cross-tenant node
impossible. B's explorer may show shared documents in a virtual "Shared
with this workspace" group, read through spec 114's own call, never as a
row of B's tree. From B, moving, renaming or deleting a shared document is
refused. The node table gets no 114 share policy.

## 6. Migration from today's `workspace_doc`

Order, each step deployed on dev and prd before the next:

1. **The t1 purge** on prd (msg f5bc3948, c-001). t1 then has 0 documents.
   Every other workspace keeps its rows, so the migration still handles them.
2. **rdb, forward-only, one transaction:**
   1. Create the table, indexes, the counter trigger, the `_ns` commit check
      and RLS.
   2. Refuse, naming the tenants, if any workspace holds more than 10,000
      documents: `SELECT tenant_id, count(*) FROM workspace_doc GROUP BY 1 HAVING count(*) > 10000`
      must return 0 rows. The build lane reads the prd count first, operator
      scope, read-only.
   3. Per tenant with documents, number them `i = row_number() OVER
      (PARTITION BY tenant_id ORDER BY created_at, id)`. Insert the root
      `(lft 1, rgt 2n + 2)` and each document under it at
      `(lft 2i, rgt 2i + 1)`, all in one `INSERT .. SELECT`. This is
      deterministic, and the commit check verifies it.
   4. Set the root's `doc_count` and assert it equals the count.
3. **The hub** that writes nodes. The store's `DocCreate` inserts the node
   in the same transaction as the document. New workspaces get their root
   `(1, 2)` lazily, on the first create, under `ON CONFLICT DO NOTHING` on
   the one-root index.
4. **rdb, the second migration:** the deferred `workspace_doc_node_required`
   trigger, only once step 3 is live on dev and prd. An older hub still
   creates a document without a node and would fail at commit.
5. **The WUI** switches the explorer to the per-folder route (section 7).

`do_spl_doc_tree_check` (spec 113 section 3.4) gains the node checks: the
same ordered pass as `_ns`, plus every document has one node and the
counters equal the counts. It runs under operator scope and exits 2 on 0
tenants. `do_spl_doc_tree_repair` gains a node rebuild: renumber `lft`/`rgt`
from `parent_id` by a depth-first walk in the current `lft` order. It is
the recovery for a broken nested set, because `parent_id` is the source
of truth.

## 7. Hub API (the explorer and the context menu)

Under the existing `/v1/workspace/doctree` prefix, with the same caller rule
(`docTreeCaller`): `docs.read` for GET, `docs.write` for the rest. The
412/404/422 mapping is today's.

| route | body / query | answers |
|---|---|---|
| `GET /v1/workspace/doctree/nodes` | `?parent=` (none = root), `?order=name` (default) or `tree`, keyset `?after=`, limit 200 | one folder's children: `{id, kind, name, title, description, doc, child_count}` (for a document, its `workspace_doc` title and description) (`child_count` from the parent_id index); the explorer's only list call (F2) |
| `GET /v1/workspace/doctree/nodes/{node}/path` | | the ancestors (`lft < n.lft AND rgt > n.rgt ORDER BY lft`): the breadcrumb, and opening a document deep in the tree |
| `GET /v1/workspace/doctree/nodes/{node}/subtree` | `?limit=` | the whole subtree in `lft` order, one range scan |
| `POST /v1/workspace/doctree` | gains optional `parent` | 201; 409 `doc_cap_reached` |
| `POST /v1/workspace/doctree/folders` | `{parent, name, title?, description?}` | 201; 409 `name_taken`, `folder_cap_reached`, depth |
| `PATCH /v1/workspace/doctree/folders/{folder}` | any of `{name, title, description}` | 200; 409 `name_taken`; 400 over a length limit |
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
table up by its `tenant_id` column. The shifts touch only the session's
tenant, and `WHERE tenant_id = $tenant` is written on every shift as well,
so a missed RLS session setting cannot shift another workspace.

## 9. Tests

Store and migration tests run on Postgres (`PRE_PUSH_TIER=full`).

| id | what | fails when |
|---|---|---|
| T1 store | create, rename, move and delete for folders and documents; after each, the bounds are 1..2n and agree with `parent_id`; a recursive delete removes the documents, their items and rev logs (counts before and after) | a row survives, a count is off, or a bound is wrong |
| T2 nested-set controls | each planted break must make the commit check raise `workspace_doc_node_ns`: a gap (one `rgt - 1`), an overlap (two siblings crossing), a `lft/rgt` off by one, a node whose `parent_id` disagrees with its enclosing interval, depth 33 (the spec 113 bench's control pattern) | any planted break commits |
| T3 leaf / width | raw SQL inserting a document with `rgt = lft + 3` (the sibling's D2) is refused by `_leaf`; a node under a `doc` is refused by the parent FK | it commits |
| T4 cap | bulk-insert 10,000 documents in one workspace, then the 10,001st: the DB raises `workspace_doc_node_cap` and the hub answers 409 `doc_cap_reached`; delete one and the next create succeeds; the same for 1,000 folders | 201 or 500 |
| T5 cap race | at 9,999, two concurrent creates: exactly one 201 and one 409, and counter = `count(*)` = 10,000 | both commit |
| T6 lock | two concurrent moves in one workspace, one of them through raw SQL that skips the store's lock: the second waits at the commit check's root lock, and the result passes T1's bound check | a broken tree commits |
| T7 RLS negative | as the runtime login (non-owner, so FORCE binds): tenant a sees 0 of b's nodes; a node with `tenant_id = a` and b's parent or doc id is refused by the FK; a move into b's folder is 404; a shift in a never changes b's bounds (md5 of b's bounds before and after); an unscoped session sees 0 rows. **Control:** an FK without the tenant column lets the cross-tenant insert through | any cross-tenant read or write, or the control passes |
| T8 property | 1,000 random ops (spec 113 section 3.5 pattern), after each: the ordered pass is clean, every document has one node, counters = counts; then `do_spl_doc_tree_repair` on a planted break restores a clean tree from `parent_id` | any invariant breaks, or repair fails |
| T9 migration | in the `workspace-docs-migration.tst.sh` style: bounds 1..2n, each document one node, `doc_count` = count; a workspace at 10,001 makes the migration refuse with its id | a silent pass |
| T10 hub + WUI | the section 7 routes with their 4xx codes; `docs.read` refused on writes. WUI e2e (mock bundle): expanding a folder loads only its children; the context menu's Delete; the non-empty-folder confirm with counts; the cap message | a wrong status, or a message is missing |
| T11 timing | the real ops (RLS + triggers + commit check) at 10,000 documents in shapes N and F, n = 5, printed with the load. Budget: **1 s** per structural write, the owner-accepted cost (section 3: 0.37-0.49 s without the check). Reads (children, path, subtree) stay under 50 ms | a write over 1 s or a read over 50 ms |

## 10. Panel and consensus

Seats, all signed against 77ffc9f8c, each commit touching only its own file
(`git show --stat <sha>`, checked by the editor):

| seat | agent | commit | file |
|---|---|---|---|
| s120-claude (editor) | c-748 | 8b8defb98 | [reviews/s120-claude.md](reviews/s120-claude.md) |
| s120-claude-2 | c-749 | c699d0dee | [reviews/s120-claude-2.md](reviews/s120-claude-2.md) |
| s120-mistral | m-750 | 23a3b4691 | [reviews/s120-mistral.md](reviews/s120-mistral.md) |
| s120-agy | a-797 | f1e285629 | [reviews/s120-agy.md](reviews/s120-agy.md) |

**The tree model was the owner's, not the panel's.** All four seats
recommended adjacency (B). The owner chose the nested set (A, msg d44d08f8),
for future features: the file system becoming its own document. The rc
(e6b1652a4) was written for B; v1.0-rc2 rewrites sections 3-9 to A and
keeps every guard the seats asked for.

**Agreed by all four** (in the spec as drafted, or extended):

- its own tree table; a single hidden root per workspace (owner confirmed,
  msg 90b4dc96);
- RLS in the 0157 shape with tenant-carrying composite FKs;
- the migration runs after the t1 purge and puts today's documents under
  the root;
- the cap is enforced in both the hub and the DB, with a WUI message.

**Changed from the draft, and settled by the panel** (who raised it; why it
holds):

| point | draft / some seats | settled | raised by | why |
|---|---|---|---|---|
| tenant column | `workspace_id` (draft, mistral) | `tenant_id` text | claude, claude-2 | F1: the column does not exist |
| cap status | 413 (draft, mistral, agy) | 409 `doc_cap_reached` | claude, claude-2 | 413 is a body-size status and is already `doc_too_large` (F4) |
| cap check | deferred `count(*)` trigger (draft, mistral, agy) | counter on the root row under a CHECK | claude, claude-2 | `count(*)` races under READ COMMITTED; T5 |
| non-empty folder delete | cascade (mistral, agy) | 409 unless `?recursive=1`, the WUI confirms with counts | claude, claude-2 | an unconfirmed cascade loses up to 10,000 documents on one click |
| parent FK action | CASCADE (mistral) | NO ACTION, subtree delete in one statement | claude-2 | a cascade bypasses the confirm |
| document is a leaf | not held (all) | parent FK on `(tenant, id, kind)` + `_leaf` CHECK | claude-2, editor (A) | no trigger needed |
| nested-set guards (A) | none (the draft rejected A) | `parent_id` kept, root lock, deferred unique bounds, the ordered commit check, repair from `parent_id` | editor, from seat s120-claude section 2 and spec 113 D1-D9 | the owner's own build broke without them |
| lock as an argument | "every write locks the whole workspace" was put as a cost of A only (rc) | both models lock per workspace; A holds the lock ~0.4 s, B ~0.2 ms | claude-2 (objection on the rc) | section 5 locks the root under B too; corrected in the owner post as well |
| folder cap, depth | none | 1,000 folders, depth 32 | claude, claude-2 | bounds `rgt`, the lazy reads and the walk; stated to the owner (11.4) |
| list route | the flat list | per-folder `GET .../nodes` | claude, claude-2 | F2: a 200-row list vs a 10,000 cap |
| document delete route | none | `DELETE /v1/workspace/doctree/{doc}` | claude, claude-2 | F3 |
| shared documents | not covered | a virtual group, never a node | claude, claude-2 | F5 |
| node-required trigger | n/a | second migration, after the hub | claude | an older hub would fail at commit |
| route shape | `/api/workspace/:id/...` (mistral, agy) | under `/v1/workspace/doctree` | claude, claude-2 | the hub's existing prefix; the tenant comes from the caller, never the URL |
| folder fields | name only (draft, all seats) | name, title, description | the owner (Q3) | msg 2b5a1ad4 |
| sibling order | `ord` (draft, mistral, agy) | `lft` order in the tree; the explorer sorts by name at read | claude, claude-2; A by the owner | under A the order is `lft` itself, no `ord` column |

Editor's note on the seats: the mistral file's signature is on line 3, not
line 1 (`git show 23a3b4691:csi-spl-doc/specs/120-qto-doc-tree/reviews/s120-mistral.md | head -3`).
Its content is signed against 77ffc9f8c, so it is accepted as is.

**Signatures.** The rc e6b1652a4 had s120-mistral `signed`, s120-claude-2
`object: 11.1` (folded, see the lock row above), and s120-agy no answer.
v1.0-rc2 changes the model by the owner's order, so every seat signs it
again:

| seat | v1.0-rc2 |
|---|---|
| s120-claude | signed (editor) |
| s120-claude-2 | pending |
| s120-mistral | pending |
| s120-agy | pending |

## 11. Owner questions

1. **The tree model: nested set or adjacency?** **Answered: A, the nested
   set** (msg d44d08f8, verbatim: "1. A stil l , because we will add more
   completely new features , such as the file system becomes it sown doc
   for eexample ... in the future").
   - What was asked: A, nested set: create 366-437 ms, move 364-487 ms at
     10,000 (n = 5), one missed shift breaks the hierarchy. B, adjacency:
     0.14-0.19 ms per write, the database enforces the tree. Both lock per
     workspace; A holds the lock ~0.4 s, B ~0.2 ms.
   - Every seat recommended B, and the owner chose A. Sections 4-9 build A
     with the guards in 4.3, 5 and 9.
2. **Root: one hidden root per workspace, or several top-level nodes?**
   **Answered: A, one hidden root** (msg 90b4dc96, verbatim: "2. A").
3. **What does a folder carry?** **Answered: Name, Title and Description**
   (msg 2b5a1ad4, verbatim: "3. when using the nested set it could contain
   anything , but let's use for now Name , Title and Descrption").
   - The seats had recommended a name only (A). The owner chose three
     fields now, and more later. Section 4.1 adds `title` and `description`
     to the folder.
4. **For the record, not a question:** beside your 10,000 documents, the
   panel caps a workspace at 1,000 folders and 32 levels of depth. Say
   otherwise if you want different limits.
