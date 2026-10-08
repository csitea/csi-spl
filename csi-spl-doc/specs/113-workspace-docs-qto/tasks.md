# 113 Workspace documents, the Qto way: tasks

Authority for what is built. `spec.md` holds the behaviour; this file
follows its sections 2-6. Each task names its layer, its dependency, the
files it owns, and a Done line with its test pair from `spec.md` section 7.
Status vocabulary: `../README.md` item 3 (`[x]` Implemented, `[~]` Partial /
in progress in a live lane, `[ ]` Planned).

Version **v0.1** (2026-10-08).

## Order

T001 lands first (DDL). T002 (API) and T003 (WUI) follow. T004 (Agents) depends on T002.

## Tasks

- [x] T000 **doc**: `spec.md` + this file, v0.1.
- [ ] T001 **rdb**. A new migration:
  - Create `workspace_docs` table with `ltree` path, `NULLIF` tenant RLS, optimistic concurrency control.
  - Create index on `path` (GIST).
  - Create history table for revisions.
  
  Files: `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_workspace_docs.sql` (*new*).
  Done: applied on dev and prd, RLS test (7c) passes.
- [ ] T002 **hub Go API**. 
  - Add API endpoints for doc tree CRUD (doc view).
  - Add API endpoints for list/grid CRUD (grid view).
  - Integrate with spec 100 search index.
  
  Files: `csi-spl-api/src/go/spool-hub-api/internal/hub/workspace_docs.go` (*new*).
  Done: API tests pass, HTTP 412 on conflict.
- [ ] T003 **WUI**. 
  - Create `WorkspaceDocView` and `WorkspaceGridView`.
  - Lazy load components (initial JS delta <= 155 KB limit).
  - Context menu for doc view (add sibling/parent/child, move, delete).
  - Inline edit and sort for grid view.
  - i18n support.
  
  Files: `csi-spl-wui/src/pages/workspace/docs.vue` (*new*), components under `csi-spl-wui/src/components/workspace-docs/`.
  Done: WUI lazy loads correctly (7b).
- [ ] T004 **Agents**.
  - Add spool `doc-read`, `doc-write`, `doc-list` verbs.
  - Expose MCP tools for these verbs.
  
  Files: `csi-spl-api/src/go/spool-hub-api/internal/agent/doc_verbs.go` (*new*).
  Done: Verbs work and unauthenticated request fails (7a).
