# Spec 120: Qto document tree (workspace file explorer)

Version **v0.1** (draft).

## 1. Goals

The Qto file explorer (folders and documents of a workspace) gets its own DB tree table. It becomes a hierarchical nested set table on its own in the database (msg ad20e44a). We cap it at no more than 10,000 documents per workspace (msg a14e799f).

## 2. Tree model

### 2.1 Nested set vs adjacency + ordinal

We weigh the nested set model against parent id + sibling position (adjacency + ordinal), using spec 113's Postgres benchmark (specs/113-workspace-docs-qto/spec.md section 2.1).

At 11,111 nodes:
- Nested-set insert near the top: 234 ms
- Nested-set move: 216 ms
- Adjacency + ordinal insert near the top: ~0.8 ms
- Adjacency + ordinal move: ~1.0 ms

The owner quotes (msg 7370f63e, msg baad764f) say his own nested-set build kept breaking the hierarchy. Spec 113 avoids the nested set because writes are O(document), and a missed shift breaks the tree. Because the workspace file explorer is a hierarchy similar to spec 113's item tree, we choose the **adjacency list + sibling ordinal** model (`parent_id` + `ord`) to ensure integrity and fast writes.

## 3. Cap enforcement

The tree is capped at 10,000 documents per workspace.

- **Hub:** The API checks the workspace's total document count before allowing a new document or folder creation. It returns 413 Payload Too Large when the limit is reached.
- **DB:** A deferred trigger on the tree table AFTER INSERT checks `count(*) WHERE workspace_id = NEW.workspace_id`. If it exceeds 10,000, it raises an exception, rolling back the transaction. This acts as the final DB backstop.

## 4. Migration from today's `workspace_doc`

Today's `workspace_doc` rows are flat within a workspace. The migration will:
1. Create the new tree table for folders and documents.
2. For each workspace, create a single hidden root folder (if required) or insert all existing `workspace_doc` rows as top-level children of the workspace.
3. Assign `ord` by sorting the existing documents (e.g. by title or creation date), preserving their current flat order as a single list of siblings.

## 5. RLS (Row Level Security)

ENABLE and FORCE ROW LEVEL SECURITY on the new tree table.
The policies mirror `workspace_doc`: the `operator_scope` policy and the repo's `NULLIF` tenant policy. The store reaches the table only through `inTenant` / `asOperator`. Composite FKs carry the tenant to ensure FK checks do not bypass RLS.

## 6. Owner questions

1. **Root node structure**
   Does each workspace have a single hidden root folder node, or can multiple nodes have `parent_id = NULL`?
   - **Option A:** Single hidden root node per workspace (like spec 113's document root). Simplifies the tree invariant checks.
   - **Option B:** Multiple top-level nodes (`parent_id = NULL`).
   - **Recommendation:** Option A, to reuse the exact invariant checks and deferred triggers from spec 113.

2. **Folder capability**
   Do folders have metadata (like a description or color), or just a name?
   - **Option A:** Just a name, stored in a `name` column.
   - **Option B:** Full attributes JSONB column.
   - **Recommendation:** Option A for simplicity; we can add JSONB later if needed.
