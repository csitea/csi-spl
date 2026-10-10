signed against 77ffc9f8c

# Spec 120 review, seat s120-claude (c-748@sat, also the panel editor)

Reviewed: `csi-spl-doc/specs/120-qto-doc-tree/spec.md` at 77ffc9f8c (v0.1,
54 lines). Read against the live code on origin/master the same day
(2026-10-10): rdb `0157_workspace_docs.sql`, `0164_workspace_doc_description.sql`,
hub `internal/hub/wsdoc_tree.go`, store `internal/store/wsdoc_hub.go`, WUI
`csi-spl-wui/src/components/workspace-docs/QtoFileTree.vue`, and specs 113
(v1.0) and 114 (v0.2).

## 0. Facts from the code the draft must build on

Each comes with the command that shows it, so a reader can check it in a minute.

- F1. **There is no `workspace_id` column.** The workspace IS the tenant:
  `grep -n "so there is no separate workspace_id" csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql`
  -> 1 line. The draft's trigger (`count(*) WHERE workspace_id = ...`)
  names a column that does not exist; it is `tenant_id`.
- F2. **The explorer today lists at most 200 documents.**
  `grep -n "docTreeListMax  = 200" csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_tree.go`
  -> line 62. `QtoFileTree.vue` gets the whole list as one `docs` prop and
  draws every document as a depth-0 row. The 10,000 cap is 50x that list
  limit, so the folder tree has to load per folder (the children of one
  expanded folder). Spec 113 section 6 already uses that unit for items.
- F3. **There is no route that deletes a document.**
  `grep -c "DELETE /v1/workspace/doctree/{doc}\"" csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_tree.go`
  -> 0 (only `DELETE .../{doc}/items/{item}`). The context menu's Delete
  (msgs 635c2125, 500ca8f5, lane c-744) and the t1 purge (msg f5bc3948)
  both need one. Spec 120 must define it, or say which spec does.
- F4. **Spec 113's measurement, the only one we have** (`bench/result-2026-10-08.md`,
  landed 9257ed1e3): PostgreSQL 16.15, n = 5, median, load ~12 on 16
  cores, fanout 10. At 11,111 rows: nested-set insert-early 234.422 ms,
  move 215.527 ms, append 1.218 ms, read subtree 2.180 ms; adjacency +
  ordinal insert 0.770 ms, move 0.983 ms, read subtree 5.169 ms. Plus the
  wide-parent run (seat 4, n = 3, load ~26): adjacency + ordinal with
  10,000 flat siblings, insert-first 218-233 ms. The draft's "~0.8 ms" and
  "~1.0 ms" round these correctly but drop the wide-parent row, which
  matters here (section 2 below).
- F5. **Spec 114 makes documents private per workspace, with a deliberate
  cross-workspace share** (model (a), not built yet: only 0157 and 0164
  reference `workspace_doc` in `csi-spl-rdb/src/sql/postgres/spool-hub/`).
  A shared-in document belongs to another tenant, so it can never be a row
  of this workspace's tree.
- F6. Prd runs POSTGRES_16: `grep -n database_version csi-spl-cnf/csi-spl/all.env.yaml`
  -> `POSTGRES_16`.

## 1. Section by section

| draft section | verdict | one line |
|---|---|---|
| 1 Goals | change | The goal says "becomes a nested set" and section 2 then picks adjacency. The goal must state the owner's ask and say the model is his decision (owner question 1), not one the draft makes. |
| 2.1 Nested set vs adjacency | change | Keep the numbers and add n = 5, PG 16.15, load ~12, the sha 9257ed1e3, the wide-parent row (F4) and that 10,000 is the scale where both are measured. Drop "we choose": the panel recommends, the owner decides. |
| 3 Cap, hub | change | 413 Payload Too Large is wrong because the request body is small. Use 409 `doc_cap_reached` with the limit and the count, and say which ops count (create and copy count, move does not). |
| 3 Cap, DB | change | `workspace_id` does not exist (F1). A per-row `count(*)` trigger races under READ COMMITTED (two inserts both see 9,999). It needs a counter row taken FOR UPDATE (section 3.2 below). |
| 4 Migration | change | It runs after the t1 purge (msg f5bc3948), so prd t1 starts empty. The step for every other workspace must be one deterministic statement, and "by title or creation date" must pick one. |
| 5 RLS | agree | Add the spec 114 interaction (F5) and name the two gates `TestRLSCoversEveryTenantTable` and `TestCrossTenantEveryTable`. |
| 6 Q1 root | agree | Option A (one hidden root per workspace); reasons in section 4. |
| 6 Q2 folder fields | agree | Option A (name only). |
| - | missing | The table and its columns, delete/move/rename semantics, the API routes for the context menu, lazy loading (F2), document delete (F3), the tests, and the nested-set owner question with options. Proposals below. |

## 2. The model, measured against THIS tree (input to owner question 1)

The draft reuses spec 113's argument, but a file explorer is not a
document outline. Three differences change the numbers that matter:

1. **A file explorer orders by name, not by a hand-kept position.** Folders
   come first, then documents, each alphabetical. Every file system the
   owner compares it to (msg ad20e44a) works this way. With order by name
   there is **no `ord` column at all**: an insert is one row, a move is one
   `parent_id` update, and there is no sibling shift and no gap invariant.
   The wide-parent cost of F4 (218-233 ms for an insert-first among 10,000
   flat siblings) disappears, because nothing shifts. I recommend
   adjacency without `ord` as option B. A manual order can be added later
   as an `ord` column.
2. **10,000 is a hard cap here, not a soft target.** The nested set's
   O(rows) write is bounded at about 234 ms (F4 at 11,111 rows). For a
   person creating a document that latency is tolerable. So speed alone
   does NOT rule the nested set out at this cap, and the owner should get
   that fair version.
3. **What still rules against it is integrity and locking**, the reasons
   the owner's own build broke (spec 113 section 3.6, D1-D9). Every write
   renumbers lft/rgt across up to the whole workspace, so every write takes
   a workspace-wide lock: the whole workspace's explorer serialises on one
   row, where adjacency locks one folder. And "no gaps, no overlaps in 2N
   bounds" can only be checked by a full-table scan, never by a constraint.
   Adjacency's invariants are an FK, a UNIQUE key and a bounded cycle walk.

Reads: the explorer reads one folder's children at a time (F2). Adjacency
answers that from the `(tenant_id, parent_id)` index. The nested set needs
`parent_id` too (spec 113's `ns` bench carries it) or a depth filter over a
range. A whole-subtree read (to delete a folder, find what is under it) is
the nested set's one advantage: 2.180 vs 5.169 ms at 1,111 rows. That gap is
within ~3x the ~1 ms noise floor, so it does not decide anything.

**My recommendation for owner question 1: B, adjacency list ordered by name
(no `ord`).** If he keeps A, the panel's job is to make A safe:
- lft/rgt plus `parent_id` (D1)
- a workspace lock on every write (D4)
- the full-scan check as a deferred trigger and as `do_spl_doc_folder_check` (D3)
- CHECK `lft < rgt` (D9)
- the same property test

## 3. Proposals for what is missing

### 3.1 The table (model B as written; A adds `lft`, `rgt`, a workspace lock)

One new table `workspace_doc_node` holds one row per folder and per
document, plus the hidden root. Documents keep their header row in
`workspace_doc` (0157 stays as it is), and a document node points at it 1:1.

```sql
CREATE TABLE workspace_doc_node (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    parent_id  uuid        NULL,
    kind       text        NOT NULL CHECK (kind IN ('root', 'folder', 'doc')),
    name       text        NOT NULL DEFAULT '' CHECK (length(name) <= 500),
    doc_id     uuid        NULL,
    created_by text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 200),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_node_tenant_id UNIQUE (tenant_id, id),
    CONSTRAINT workspace_doc_node_root_shape CHECK ((kind = 'root') = (parent_id IS NULL)),
    CONSTRAINT workspace_doc_node_doc_shape  CHECK ((kind = 'doc') = (doc_id IS NOT NULL)),
    CONSTRAINT workspace_doc_node_name_shape CHECK (kind <> 'folder' OR length(name) BETWEEN 1 AND 500),
    CONSTRAINT workspace_doc_node_parent_fk FOREIGN KEY (tenant_id, parent_id)
        REFERENCES workspace_doc_node (tenant_id, id) ON DELETE RESTRICT,
    CONSTRAINT workspace_doc_node_doc_fk FOREIGN KEY (tenant_id, doc_id)
        REFERENCES workspace_doc (tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT workspace_doc_node_doc_once UNIQUE (doc_id)
);
CREATE UNIQUE INDEX workspace_doc_node_one_root ON workspace_doc_node (tenant_id) WHERE parent_id IS NULL;
CREATE UNIQUE INDEX workspace_doc_node_folder_name ON workspace_doc_node (tenant_id, parent_id, lower(name)) WHERE kind = 'folder';
CREATE INDEX workspace_doc_node_children ON workspace_doc_node (tenant_id, parent_id, kind, lower(name));
```

- A document's display name stays in `workspace_doc.title`, one place with
  no drift: the node's `name` is `''` for a doc. Two documents with the
  same title in one folder are allowed, as today. Two folders with the same
  name in one folder are not.
- Composite FKs carry the tenant because FK checks bypass RLS (spec 113
  seat 5's finding). A node can therefore only point at a parent and a
  document of its own workspace.
- **Invariants**:
  - one root per workspace: the partial unique index, plus a deferred
    trigger that requires the root once the workspace has its first node
  - one parent: the FK
  - no cycle: a deferred constraint trigger on a `parent_id` change, running
    the bounded walk of 0157's `workspace_doc_item_tree`, bounded by the
    11,001-node cap
  - every `workspace_doc` has exactly one node: UNIQUE `doc_id`, plus a
    deferred trigger on `workspace_doc` INSERT, the way
    `workspace_doc_root_required` does it for items

### 3.2 The 10,000 cap

- **What counts**: document nodes (`kind = 'doc'`), per workspace. Folders
  get their own cap of **1,000**, so the node count stays bounded at 11,001,
  the size the bench measured. Move and rename never count; create and a
  future copy do.
- **DB** (the race-free backstop): a counter row per workspace,
  `workspace_doc_quota (tenant_id PK, docs int CHECK (docs BETWEEN 0 AND 10000), folders int CHECK (folders BETWEEN 0 AND 1000))`.
  An AFTER INSERT / DELETE row trigger on `workspace_doc_node` keeps it
  with `UPDATE .. SET docs = docs + 1`. The UPDATE's row lock serialises two
  concurrent creates, so they cannot both pass the CHECK. A plain
  `count(*)` trigger cannot guarantee that under READ COMMITTED. The CHECK
  raises `check_violation` with constraint name `workspace_doc_quota_docs`.
- **Hub**: it maps that constraint to **409 `doc_cap_reached`**
  `{limit: 10000, count: n}` (and `folder_cap_reached` for folders). It
  also checks the counter before the create, so the common case never
  reaches the DB error. No 413, because the request is not too large.
- **WUI**: the create dialog and the context menu's New document show
  "This workspace has reached its 10,000-document limit. Delete documents
  to add new ones." This is an i18n key in all locales, reviewed by agy
  under the language rule. The explorer footer shows `n / 10,000` once n
  passes 9,000.

### 3.3 Operations and their semantics

| op | rule |
|---|---|
| create folder / doc | in a folder the caller can see. A doc create inserts `workspace_doc`, its 0157 root item and the node in ONE transaction |
| rename | folder: `name` (409 `name_taken` on a sibling clash); doc: `workspace_doc.title` (the existing PATCH, rev-checked) |
| move | a `parent_id` update. The target must be a folder or the root; a cycle is refused (422 `cycle`). A doc moves alone; a folder moves with its subtree (one row update) |
| delete doc | deletes the `workspace_doc` row: 0157's cascades take its items and rev log, and the node cascades by the `doc_id` FK |
| delete folder, empty | deletes the node |
| delete folder, with children | refused by default with 409 `folder_not_empty {docs, folders}`. With `?recursive=1` (the menu asks "Delete folder and its N documents?"), one transaction deletes the subtree deepest-first under the workspace lock |
| restore | none in v1.0 (no trash), so a deleted doc's rev log goes with it. It becomes an owner question only if he wants a trash; I do not add one |

Locking: move and recursive delete take one advisory lock per workspace
(`pg_advisory_xact_lock` on the tenant, the pattern of 0157's per-doc lock).
Create and rename need nothing beyond the counter row and the unique index.
Under option A every op takes the lock.

### 3.4 API routes (what the context menu needs, lane c-744)

These go under the existing `/v1/workspace/doctree` family, with the same
caller rule (`docTreeCaller`) and the same 412/404/422 mapping:

- `GET    /v1/workspace/doctree/nodes/{node}/children`: one folder's
  children, folders first, then by `lower(name)`, paged by keyset
  (`after=<kind,name,id>`, limit 200). This is the explorer's only list
  call (F2).
- `POST   /v1/workspace/doctree/nodes`: `{parent, kind: folder|doc, name|title}`.
- `PATCH  /v1/workspace/doctree/nodes/{node}`: `{name}` (folder rename).
- `POST   /v1/workspace/doctree/nodes/{node}/move`: `{parent}`.
- `DELETE /v1/workspace/doctree/nodes/{node}[?recursive=1]`: the context
  menu's Delete for both kinds (this closes F3).
- `GET    /v1/workspace/doctree/nodes/{node}/path`: the ancestors, for the
  breadcrumb and to open the explorer at a document.
- `GET /v1/workspace/doctree` (today's flat list, max 200) stays for the CLI
  and the omnibox; the explorer stops using it.

c-744's menu ships Delete and Edit on documents now. Once the
`DELETE .../nodes/{node}` route exists, the menu should call it rather than
grow a second delete path. I do not message c-744 myself (not my lane); the
editor's fold names it for the dispatcher.

### 3.5 RLS

ENABLE + FORCE on `workspace_doc_node` and `workspace_doc_quota`, with the
0021 `NULLIF` `tenant_scope` policy plus `operator_scope`. The store reaches
them only via `inTenant` / `asOperator`. **The node table gets no spec 114
share policy.** A shared-in document is another tenant's row (F5), so the
recipient's explorer shows it in a separate virtual "Shared with us" group,
read through 114's own call and never as a node. That keeps the node
table's isolation a pure tenant fence.

### 3.6 Migration from today's workspace_doc

Order:

1. The t1 purge on prd (msg f5bc3948, c-001).
2. The additive migration, under the next free number at build time (0164
   is the last today). It creates both tables. In the same file, for every
   tenant that has a `workspace_doc` row, it inserts one root node, one doc
   node per document under the root, and the quota row from the count.
   Each is one deterministic `INSERT .. SELECT`, and no ordering is needed
   because order is by name at read. A workspace already over 10,000
   documents would fail the CHECK, so the migration first asserts
   `max(count) <= 10000` and otherwise stops with the offending tenant ids.
   None are expected; the build lane reads the prd count (operator scope,
   read-only) before the migration lands.
3. The hub that writes nodes.
4. The WUI.

Between steps 2 and 3 an older hub keeps working only if a doc create
without a node is still allowed. The deferred "every doc has a node"
trigger therefore ships in step 3's migration, not in step 2's.

### 3.7 Tests

- Store, on testkit Postgres: create, rename, move and delete for both
  kinds; a folder name clash gives 409; a move into the node's own subtree
  is refused (cycle); a recursive delete removes exactly the subtree (count
  before and after), including the docs' items and rev logs.
- **RLS negative**: tenant a's session sees 0 of tenant b's nodes. It
  cannot insert a node whose `parent_id` or `doc_id` is tenant b's (the
  composite FK refuses it even though RLS hides the row), and it cannot
  move a node under b's folder. Control: in a throwaway DB, drop the tenant
  column from the FK; the cross-tenant insert must then succeed, which
  proves the test can fail. `TestRLSCoversEveryTenantTable` and
  `TestCrossTenantEveryTable` pick up both new tables.
- **Cap**: seed a workspace at 9,999 docs and run two concurrent creates.
  Exactly one gets 201 and one gets 409 `doc_cap_reached`, and the counter
  ends at 10,000 = `count(*)`. Delete one and the next create succeeds. The
  same holds for 1,000 folders. Control: the `count(*)`-trigger variant
  must let both creates through at least once in 50 tries, which shows the
  race the counter row closes.
- Property test (the pattern of spec 113 section 3.5): 1,000 random ops.
  After each one: one root, no cycle, every doc has one node, and
  counter = count.
- Timing (printed, not gated): a folder's children with 10,000 docs flat in
  one folder, first page under 5 ms; a move and a recursive delete of 1,000
  nodes.
- WUI e2e (mock bundle): expanding a folder loads only its children; the
  cap message renders; Delete on a non-empty folder asks before deleting.

## 4. Owner questions (each with options and my recommendation)

1. **Nested set, as you asked, or adjacency list?** (msg ad20e44a)
   - **A. Nested set** (`lft`/`rgt` + `parent_id`): the fastest
     whole-subtree read. Every write renumbers rows across up to the whole
     workspace: about 234 ms at 11,111 rows (spec 113 bench, PG 16.15,
     n = 5). It needs a lock on the whole workspace, and its "no gap, no
     overlap" rule can only be checked by scanning the whole table. This is
     the model whose hierarchy broke in your earlier build (spec 113 quotes
     7370f63e, baad764f).
   - **B. Adjacency list, ordered by name** (`parent_id` only): an insert
     or a move writes one row, about 1 ms at the same size. The database
     itself enforces one parent, one root and no cycle, and folders sort
     like a file system.
   - **Recommendation: B.** At the 10,000 cap A is fast enough, so the
     reason is integrity, not speed.
2. **One hidden root per workspace, or several top-level nodes?** (draft Q1)
   - A. One hidden root; B. several `parent_id IS NULL` rows.
   - **Recommendation: A.** "Move to top level" becomes "move under the
     root", so one rule covers every move, and the single-root unique index
     is the same check 0157 already runs.
3. **What does a folder carry?** (draft Q2)
   - A. A name only; B. a name and free attributes (JSONB: colour, description).
   - **Recommendation: A.** A column can be added later without migrating
     existing rows.
4. Not a question, stated for the record: the panel proposes a cap of 1,000
   folders per workspace beside the 10,000 documents. The owner may say
   otherwise.
