# Spec 137 panel: seat s137-agy

Seat: `s137-agy` (agent a-960), spec 137 section 6, step 2 of task
dispatch-bed3ed0a. Reviewed: `spec.md` v0.1.0 and `tasks.md` as landed in
`43472c355` (SPL-1730), against the code on origin/master on 2026-10-14.
Doc only: this file builds nothing.

## 0. The five choices in one line

P-Q1 **A** (stored as `attrs.numbered = false`), P-Q2 **A** (one reserved repo workspace with permissive SELECT RLS), P-Q3 **A** (pipe-table skeleton in paragraph body), P-Q4 **A** (Markdown blockquote in paragraph body), P-Q5 **A** (hard gate, scoped strictly to files mapped in `qto-docs.tsv`).

## 1. Facts from the code that the choices rest on

| # | fact | where |
|---|---|---|
| K1 | An item represents a heading; its body holds paragraph markdown text; its `attrs` holds one code block and one image. The table has no `kind` column. | `csi-spl-api/src/go/spool-hub-api/cmd/spool/doctree.go:41-51`, `csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql:44-55` |
| K2 | `workspace_doc_item.attrs` is a generic JSONB object (`CHECK (jsonb_typeof(attrs) = 'object')`), so adding `attrs.numbered` requires no SQL schema migration. | `csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql:52` |
| K3 | `workspace_doc` does not have an `attrs` column (only `id`, `tenant_id`, `title`, `rev`, `created_by`, timestamps, and `description` added in 0164). | `csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql:33-42`, `0164_workspace_doc_description.sql:9` |
| K4 | Outline numbers are computed dynamically at read time from the ancestor ord path; they are never stored in the database. | `csi-spl-api/src/go/spool-hub-api/internal/store/workspace_docs_read.go:107-123` |
| K5 | Heading export formats are implemented identically in Go and TypeScript ("Change both together"); both currently prefix every heading with its outline number. | `csi-spl-api/src/go/spool-hub-api/cmd/spool/doctree_export.go:13,156-157`, `csi-spl-wui/src/components/workspace-docs/-doctree-export.ts:23-24` |
| K6 | The CLI already implements table insertion into the item body: `spool doctree add <doc> --kind table` appends Markdown table text. | `csi-spl-api/src/go/spool-hub-api/cmd/spool/doctree.go:47` |
| K7 | The WUI renderer already permits `blockquote` and table tags (`table`, `thead`, `tbody`, `tr`, `th`, `td`), and pipe tables parse natively with markdown-it. | `csi-spl-wui/src/utils/markdown.mjs:41-47,196-211` |
| K8 | RLS and composite tenant foreign keys are already live on all doctree tables. The actual runtime GUCs are `app.tenant_id` and `app.rls_scope = 'operator'` (not the `spool.*` GUCs drafted in spec §4.2.2). | `csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql:64-67,83-109`, `0165_workspace_doc_node.sql:71-91` |
| K9 | Every node and document belongs to a registered tenant via foreign key to `tenants(tenant_id)`. Each tenant has exactly one root node, a 10,000 document cap, and max tree depth of 32. | `csi-spl-rdb/src/sql/postgres/spool-hub/0165_workspace_doc_node.sql:41,69,76,243-244` |
| K10 | Spec 075 repo-edit provides an existing alternative writer for repo docs (`PUT /v1/docs/{path}` saving overlays to GCS and `repodocs.Worker` pushing commits to git), which spec 137 does not address. | `csi-spl-api/src/go/spool-hub-api/internal/hub/repo_docs_edit.go:28-43`, `internal/repodocs/author.go` |
| K11 | The import script refuses to renumber headings to prevent breaking citations; export already emits the immutable provenance stamp on line 2 (`> Generated from qto doc <id>; edit it there.`). | `csi-spl-orc/src/bash/run/spl-doctree-md.py:12-14,114-116` |
| K12 | The export map `qto-docs.tsv` currently tracks exactly 2 production documents (`runbook-dispatcher.md`, `runbook-orchestrator.md`) assigned to a workspace tenant rather than a system repo tenant. | `csi-spl-doc/doc/md/qto-docs.tsv:1-2` |

## 2. The decisions

### 2.1 P-Q1 unnumbered headings: A, stored as `attrs.numbered = false`

- **Choice**: A, store an explicit opt-out flag `attrs.numbered = false` on `workspace_doc_item`.
- **Why**:
  Using `attrs.numbered = false` in the existing JSONB column requires zero database migrations and leaves all existing numbered items unchanged (K2). It cleanly supports both the 559 unnumbered files (F07) and the 110 outline mismatches (F09) by preserving non-standard outline numbering literally in the title string. Option B introduces redundant stored state and numbering desynchronization, while Option C forcibly renumbers headings and breaks external citations (K11).
- **Risk**:
  Sibling numbering must handle unnumbered items gracefully so that subsequent numbered sections do not skip integers (e.g. `## Overview` followed by `## 1. Setup` must keep `Setup` at `1`). The outline generator (`workspace_docs_read.go`) and the paired Go/TypeScript exporters (`doctree_export.go`, `-doctree-export.ts`) must be updated in lockstep.
- **Fit**:
  `workspace_docs_read.go:110-113` computes `outlineOf(path)` during scan; reading `attrs["numbered"]` here allows suppressing the outline prefix at the source. Both exporters (`doctree_export.go:157` and `-doctree-export.ts:24`) format `${it.outline} ${it.title}` and can omit the outline when empty.

### 2.2 P-Q2 repo docs in the unified file system: A, one reserved repo workspace

- **Choice**: A, one reserved workspace tenant for repository documentation with a permissive `FOR SELECT` RLS policy.
- **Why**:
  The system's data model, nested set tree, and security boundaries are designed around tenant isolation (K8, K9). A single reserved tenant (e.g. `system` or `_repo`) reuses the existing schema without duplication, storing exactly one copy of the 1,247 documents. Option B multiplies data by every workspace and introduces massive synchronization overhead, while Option C preserves two separate document stores and APIs, defeating owner requirement B3 (msg `0e9d17b5`).
- **Risk**:
  The reserved tenant requires an entry in `tenants` due to foreign keys (K9); tenant listings, workspace switchers, and billing sweeps must explicitly exclude it. Additionally, concurrent writes to repo docs lock the tenant root (`0165_workspace_doc_node.sql:177`), so bulk imports must be serialized.
- **Fit**:
  `0157_workspace_docs.sql:84-106` and `0165_workspace_doc_node.sql:83-91` already enforce RLS via `tenant_scope` and `operator_scope`. Adding a single permissive `doc_select_repo` policy (`USING (tenant_id = '<repo_id>')`) grants universal read access while existing write policies strictly prevent non-operator writes.

### 2.3 P-Q3 table editor: A, pipe-table skeleton into paragraph body

- **Choice**: A, paragraph toolbar button inserting a Markdown pipe table skeleton directly into the paragraph body.
- **Why**:
  Paragraph bodies already store Markdown text, the CLI already appends tables directly to bodies (K6), and the WUI renderer already parses and renders GFM pipe tables and HTML tables (K7). Option A delivers immediate owner functionality (msg `2c82489a`) with zero schema changes. Option C introduces a new item kind that contradicts the existing data model (K1) and requires building complex bidirectional Markdown AST compilers.
- **Risk**:
  Users can introduce malformed pipes or uneven rows when editing raw Markdown. Escaped pipe characters (`\|`) and trailing whitespace must be preserved without corruption by `spl-doctree-md.py:55`. An interactive grid helper (Option B) can be added later as a client-side convenience over the same underlying Markdown body.
- **Fit**:
  `WorkspaceDocView.vue:162-174` defines the paragraph tools container (`wsdoc__paratools`), where `ws-doc-insert-pic` is already mounted. The new `ws-doc-insert-table` button integrates into this exact slot, matching the existing CLI verb in `doctree.go:47`.

### 2.4 P-Q4 blockquotes and citations: A, Markdown blockquote in paragraph body

- **Choice**: A, standard Markdown blockquotes with an attribution line (`> passage\n> \n> — Source`) stored in `body`.
- **Why**:
  Storing blockquotes as Markdown in `body` supports multiple quotes, nested blockquotes (`> > quote`, 18 repo files), and GitHub callout alerts (`> [!NOTE]`, 15 repo files) within a single paragraph. Item `attrs` currently holds only a single code block and one image (K1); moving citations to structured `attrs` (Option B) restricts items to a single quote and complicates export logic across both exporters.
- **Risk**:
  Detecting the attribution line relies on an authoring convention (a trailing paragraph starting with `—`) rather than structured columns. If the em-dash prefix is omitted, the attribution renders as standard blockquote text, which is an acceptable and graceful fallback.
- **Fit**:
  `csi-spl-wui/src/utils/markdown.mjs:43` already includes `blockquote` in `TAGS`. Adding CSS styling for `blockquote` and citation lines (`blockquote p:last-child`) in `MarkdownBlock.vue` delivers styled cards without any changes to Go backend code or export scripts.

### 2.5 P-Q5 retirement gate: A, hard gate scoped to mapped files in `qto-docs.tsv`

- **Choice**: A, hard pre-push and CI quality gate enforced incrementally on every file registered in `qto-docs.tsv`.
- **Why**:
  Owner requirement B1 (msgs `25579adb`, `ae9d80a4`) explicitly demands retiring manual `.md` file editing. Option C (advisory warnings) fails to prevent drift. Option B (automated CI commits) creates commit races with active developer worktrees, breaks linear rebase workflows, and generates merge conflicts. Enforcing a hard rejection per mapped file allows retirement to expand incrementally from the current 2 files to all 1,247 files.
- **Risk**:
  Local offline edits cannot be verified if the developer's machine cannot communicate with the hub API. Furthermore, the legacy Spec 075 repo-edit background worker (K10) pushes direct Git commits and will be blocked by the gate unless it is disabled for mapped files.
- **Fit**:
  `spl-doctree-md.py:114-116` already embeds the deterministic export stamp (`> Generated from qto doc <id>; edit it there.`), and `qto-docs.tsv` (K12) provides the authoritative registry for pre-push and CI scanners.

## 3. Corrections to tasks.md

1. **Rescope T020 and Correct GUC Names in Spec §4.2.2**:
   `tasks.md` T020 describes building RLS and tenant segregation from scratch. However, RLS, `FORCE ROW LEVEL SECURITY`, and composite tenant foreign keys are already implemented and active on all four doctree tables (K8). Furthermore, the actual database uses GUCs `app.tenant_id` and `app.rls_scope = 'operator'` rather than `spool.tenant_id` and `spool.operator_scope` drafted in spec §4.2.2. T020 must be rescoped to: insert the reserved repo workspace in `tenants`, add the permissive `FOR SELECT` policy on each table, and filter the repo tenant from workspace management APIs.
2. **Add Missing Prerequisite Task: Deprecate Spec 075 Repo-Edit Path**:
   Spec 075 implemented `PUT /v1/docs/{path}` and `repodocs.Worker` (K10), which allows editing repo docs by writing GCS overlays and committing to Git. If T040 (pre-push gate) lands without retiring or disabling this path for mapped documents, the background worker will attempt to push direct `.md` commits and fail against the gate. A task must be added before T040 to disable repo-edit overlays for any path present in `qto-docs.tsv`.
3. **Reorder T032 (Compiled Go Export Test) Ahead of T012-T015**:
   T032 (replacing the Python stub in `doctree-export-md.tst.sh` with the compiled `spool doctree export` Go binary) is currently placed in Phase 3. However, Phase 1 tasks T012-T015 directly alter heading parsing, unnumbered outlines, and fence formatting. Testing Phase 1 changes against the simplistic Python mock (`doctree-export-md.tst.sh:36-52`) risks masking discrepancies with the compiled Go exporter. T032 must be moved to Phase 1 as an upfront validation gate.
4. **Correct Target Schema in T014 (`workspace_doc` Lacks `attrs`)**:
   T014 specifies saving YAML front matter into `workspace_doc.attrs.front_matter`. However, `workspace_doc` does not have an `attrs` column (K3). Front matter must either be stored in the root item's `workspace_doc_item.attrs` (where the document preamble is already stored in `body`), or T014 must be expanded to include an explicit database migration adding `attrs JSONB` to `workspace_doc`.
5. **Decompose T030 into Incremental Batches and Fix T002 Gate Path**:
   Batch-importing all 1,247 Markdown files in a single task (T030) carries high blast radius: because tree operations lock the root node (`0165_workspace_doc_node.sql:177`), a failure midway requires complex rollback. T030 should be divided into manageable subtasks: (a) migrate existing 2 mapped docs into the repo workspace, (b) import `csi-spl-doc/doc/`, (c) import `csi-spl-doc/specs/`, and (d) import remaining root and module files after T017. Additionally, T002's gate in `tasks.md` cites `reviews/`, while the panel review files are located under `panel/<seat>.md`; the gate text must be aligned.

## 4. Version log

| version | date | author | change |
|---|---|---|---|
| 1.0 | 2026-10-14 | s137-agy (a-960) | Initial consensus review: decisions P-Q1..P-Q5 and five tasks.md corrections. |

<!-- version: 1.0 · updated: 2026-10-14 · last-edit: 2026-10-14T00:15:00Z -->
