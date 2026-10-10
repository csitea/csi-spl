signed against 77ffc9f8c

## Sections
- 1. Goals: agree
- 2. Tree model: agree
- 3. Cap enforcement: change (missing WUI error behavior)
- 4. Migration from today's `workspace_doc`: change (missing the t1 purge pre-condition in the steps)
- 5. RLS (Row Level Security): agree

## Missing Proposals

**Table, columns, and constraints**
- Table: `qto_doc_tree`
- Columns:
  - `id` (uuid, pk)
  - `tenant_id` (uuid, fk to `tenants(id)`)
  - `parent_id` (uuid, fk to `qto_doc_tree(id)`, null for the single hidden root)
  - `ord` (int, 1-based, sibling position)
  - `kind` (varchar, 'folder' or 'document')
  - `doc_id` (uuid, fk to `workspace_doc(id)`, nullable)
  - `name` (varchar)
- Constraints:
  - Unique index on `(tenant_id, parent_id, name)` for folders.
  - Check constraint on `kind`: `kind IN ('folder', 'document')`.
  - Check constraint: `(kind = 'document' AND doc_id IS NOT NULL) OR (kind = 'folder' AND doc_id IS NULL)`.

**Cap enforcement**
- **DB:** A deferred constraint trigger AFTER INSERT checks `count(*) FROM qto_doc_tree WHERE tenant_id = NEW.tenant_id AND kind = 'document'`. If > 10,000, raises an exception rolling back the transaction.
- **Hub:** API checks total document count before creation. Returns 413 Payload Too Large if at limit.
- **WUI error:** Displays a user-friendly error dialog: "Workspace limit reached: Maximum of 10,000 documents allowed."

**RLS (Row Level Security)**
- `ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY` on `qto_doc_tree`.
- `operator_scope` policy and `NULLIF` tenant policy to mirror `workspace_doc`.
- Store queries must use `inTenant` / `asOperator`.
- Use composite FK `(tenant_id, doc_id) REFERENCES workspace_doc (tenant_id, id)` to prevent RLS bypass via FK checks.

**Move, rename, delete semantics**
- **Move:** Update `parent_id` and `ord`. Children move implicitly with the folder since they reference its `id`.
- **Rename:** Update the `name` column.
- **Delete:** Deleting a folder recursively deletes all descendant nodes in `qto_doc_tree` (via cascading delete). Deleting a document node also deletes the referenced `workspace_doc` row.

**Migration from today's workspace_doc**
1. Wait for the t1 purge of existing documents to complete.
2. Create the `qto_doc_tree` table.
3. For each tenant with existing `workspace_doc` rows, insert a single hidden root folder (kind='folder', parent_id=NULL).
4. Insert all existing `workspace_doc` rows for that tenant as children of the hidden root (kind='document'), assigning sequential `ord` values.

**API routes for the context menu**
- `POST /api/v1/workspaces/:workspaceId/tree/folders` (Create folder)
- `PATCH /api/v1/workspaces/:workspaceId/tree/nodes/:nodeId/move` (Move node)
- `PATCH /api/v1/workspaces/:workspaceId/tree/nodes/:nodeId/rename` (Rename node)
- `DELETE /api/v1/workspaces/:workspaceId/tree/nodes/:nodeId` (Delete node)

**Tests**
- Cap test: verify inserting the 10,001st document fails with 413 on the Hub and raises the deferred DB trigger.
- RLS negative test: verify an operator in tenant A cannot view, move, or delete a node in tenant B.
- Move invariant test: verify that moving a node updates sibling ordinals correctly and prevents cycles (e.g. moving a folder into its own child).

## Owner Questions

**Tree model**
- **Option A:** A nested set as he asked.
- **Option B:** Adjacency list + sibling ordinal (`parent_id` + `ord`).
- **Recommendation:** Option B (adjacency + ordinal). As measured in spec 113, inserting near the top in a 11,111 node tree takes 234 ms for a nested set vs ~0.8 ms for an adjacency list. Given the 10,000 document cap, adjacency provides superior write performance and avoids the tree breakages the owner experienced previously with nested sets.

**Q1: Root node structure**
- **Option A:** Single hidden root node per workspace (`parent_id = NULL`).
- **Option B:** Multiple top-level nodes (`parent_id = NULL`).
- **Recommendation:** Option A. It simplifies tree invariant checks and mirrors the single document root pattern already established in spec 113.

**Q2: Folder capability**
- **Option A:** Just a name (`name` column).
- **Option B:** Full attributes JSONB column.
- **Recommendation:** Option A. We should start simple with just a name column. A JSONB attributes column can be safely added in a future migration if folder metadata becomes necessary.
