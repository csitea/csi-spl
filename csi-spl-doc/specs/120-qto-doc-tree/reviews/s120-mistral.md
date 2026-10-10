# Review: s120-mistral

signed against 77ffc9f8c

## 1. Goals
agree

## 2. Tree model
### 2.1 Nested set vs adjacency + ordinal
change: Recommend **adjacency + ordinal** (parent_id + ord) for integrity and fast writes, as the draft does. The nested-set model is not viable due to O(document) writes and hierarchy breakage risk.

## 3. Cap enforcement
missing: Enforcement details are incomplete. Proposal:
- **Hub**: API checks `count(*) FROM tree WHERE workspace_id = ?` before allowing a new document/folder. Returns 413 Payload Too Large if the limit is reached.
- **DB**: A deferred trigger on the tree table AFTER INSERT checks `count(*) WHERE workspace_id = NEW.workspace_id`. If > 10,000, raises an exception, rolling back the transaction.
- **WUI error**: "This workspace has reached its 10,000-document limit. Delete documents to free up space."

## 4. Migration from today's `workspace_doc`
missing: Migration steps are incomplete. Proposal:
1. Create the new tree table (see table proposal below).
2. For each workspace, create a single hidden root folder (id = `workspace_id`, name = "root", hidden = true).
3. Insert all existing `workspace_doc` rows as children of the hidden root, preserving their current order (e.g., by `created_at` or `title`).
4. Assign `ord` sequentially (0, 1, 2, ...) to siblings.

## 5. RLS (Row Level Security)
agree: Policies mirror `workspace_doc` (operator_scope + tenant policy). Composite FKs carry the tenant to ensure FK checks do not bypass RLS.

## 6. Owner questions
### Q1: Root node structure
- **Option A**: Single hidden root node per workspace (recommended). Simplifies invariant checks and reuses spec 113's deferred triggers.
- **Option B**: Multiple top-level nodes (`parent_id = NULL`).

### Q2: Folder capability
- **Option A**: Just a `name` column (recommended for simplicity).
- **Option B**: Full attributes JSONB column (can be added later if needed).

### Nested-set question
- **Option A**: Nested set (as owner requested).
- **Option B**: Adjacency + ordinal (recommended).
  - **Rationale**: Nested-set writes are O(document) and prone to hierarchy breakage. Adjacency + ordinal ensures integrity and fast writes.

## Concrete proposals
### Table: `qto_doc_tree`
```sql
CREATE TABLE qto_doc_tree (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES qto_doc_tree(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    is_folder BOOLEAN NOT NULL DEFAULT false,
    is_hidden BOOLEAN NOT NULL DEFAULT false,
    ord INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT valid_name CHECK (name ~ '^[^/\\:*?"<>|]+$' AND name != ''),
    CONSTRAINT no_circular_ref CHECK (id != parent_id),
    CONSTRAINT composite_tenant_fk FOREIGN KEY (workspace_id, parent_id) REFERENCES qto_doc_tree(workspace_id, id) ON DELETE CASCADE
);

CREATE INDEX idx_qto_doc_tree_workspace_id ON qto_doc_tree(workspace_id);
CREATE INDEX idx_qto_doc_tree_parent_id ON qto_doc_tree(parent_id);
CREATE INDEX idx_qto_doc_tree_workspace_id_parent_id_ord ON qto_doc_tree(workspace_id, parent_id, ord);
```

### Constraints
- **Name**: No invalid filesystem characters (`/\:*?"<>|`) and not empty.
- **Circular ref**: `id != parent_id`.
- **Composite FK**: Ensures `parent_id` belongs to the same workspace.

### Move/rename/delete semantics
- **Move**: Update `parent_id` and `ord`. If the new parent is in a different workspace, reject (400 Bad Request).
- **Rename**: Update `name`.
- **Delete**: Cascade to children. If the deleted node is a folder, all descendants are deleted.

### API routes for context menu
- `POST /api/workspace/:workspace_id/doc-tree/:id/delete`
- `POST /api/workspace/:workspace_id/doc-tree/:id/rename` (body: `{ name: "new-name" }`)
- `POST /api/workspace/:workspace_id/doc-tree/:id/move` (body: `{ parent_id: "new-parent-id", ord: 3 }`)

### Tests
- **RLS negative**: Attempt to access a document in a workspace the operator does not belong to. Expect 403 Forbidden.
- **Cap test**: Insert 10,000 documents, then attempt to insert a 10,001st. Expect 413 Payload Too Large.
- **Move/rename/delete**: Verify cascading deletes, name validation, and circular ref rejection.
- **Migration**: Verify all `workspace_doc` rows are migrated as children of the hidden root, with correct `ord`.
