# Spec 137: Qto doc editor panel consensus

Topic: t1 `bed3ed0a-dd34-46b9-a7ea-a8c89c5f596c` (HUM-10, task dispatch-bed3ed0a) · Written by: a-965 (agy, panel editor) · Date: 2026-10-14 · Issue: SPL-1743  
Inputs: [`spec.md`](../spec.md) and [`tasks.md`](../tasks.md) v0.1.0 at `43472c355` (SPL-1730), [`panel/claude.md`](claude.md) (`6216915b8`), [`panel/mistral.md`](mistral.md) (`e33014485`), [`panel/agy.md`](agy.md) (`06373720f`), [`panel/grok.md`](grok.md) (`d999a070f`).  
Seats: 4 placed seats (`s137-claude`, `s137-grok`, `s137-mistral`, `s137-agy`). The `s137-qwen` seat was not placed (no qwen CLI available on sat; primary box over its load gate). The panel has 4 seats.  
Result: Folded into [`spec.md`](../spec.md) v0.2.0 and [`tasks.md`](../tasks.md) v0.2.0. Docs only: this file builds nothing.

---

## 1. Decisions on Questions P-Q1..P-Q5

| Question | Claude (c-957) | Grok (g-959) | Mistral (m-xxx) | Agy (a-960) | Decision | Summary & Key Rationale |
|---|---|---|---|---|---|---|
| **P-Q1** (Unnumbered Headings) | **A** (`attrs.numbered = false`) | **A** (`attrs.numbered = false`) | **A** (`is_numbered` flag) | **A** (`attrs.numbered = false`) | **A** (`attrs.numbered = false`) | Stored in existing JSONB `attrs` with no database migration; preserves unnumbered headings without breaking derived outline numbering or renumbering external citations. |
| **P-Q2** (Repository Docs in File System) | **A** (One reserved repo workspace) | **A** (One reserved repo workspace) | **A** (Global `system` tenant) | **A** (One reserved repo workspace) | **A** (One reserved repo workspace) | Reuses existing nested-set tree and composite FKs under tenant `system`; grants read to all workspaces via permissive SELECT RLS while keeping writes operator-only. |
| **P-Q3** (Table Editor Interface) | **A** (Pipe-table skeleton in body) | **A** (Pipe-table skeleton in body) | **B** (Markdown template insertion) | **A** (Pipe-table skeleton in body) | **A** (Pipe-table skeleton in body) | Inserts pipe-table template into paragraph body via toolbar button; builds on existing CLI verbs and renderer support without new node kinds or JSONB cell compilers. |
| **P-Q4** (Blockquotes & Citations) | **A** (Markdown blockquote in body) | **A** (Markdown blockquote in body) | **A** (Stateful / markdown format) | **A** (Markdown blockquote in body) | **A** (Markdown blockquote in body) | Stores `> quote` and trailing attribution line `> — [Source](url)` in markdown body; styles quote cards and attribution in CSS without restricting items to single quotes. |
| **P-Q5** (Retirement Gate & Drift) | **A** (Hard gate on mapped files) | **A** (Hard gate on mapped files) | **A** (Hard gate / JSONB export) | **A** (Hard gate on mapped files) | **A** (Hard gate on mapped files) | Enforces hard pre-push and CI rejection strictly for files registered in `qto-docs.tsv`; expands incrementally with import without racing CI auto-commits. |

### 1.1 Weighing Mistral's reasoning on P-Q3 (3 A vs 1 B)

The vote on P-Q3 stands at 3 A (Claude, Grok, Agy) vs 1 B (Mistral).

- **Mistral's rationale for B**: Mistral labeled its vote as "B (Markdown Template Insertion)", arguing for:
  1. Low implementation cost by inserting pre-formatted templates (`| Header | Header |\n|---|---|`) directly into the textarea;
  2. High Markdown round-trip fidelity;
  3. Mobile-friendliness across all devices without complex spreadsheet UI;
  4. Extensibility to later evolve into an interactive visual editor if needed.
- **Analysis and alignment**: In [`spec.md`](../spec.md) §6.2, Option A is defined as *"Toolbar button inserts pipe table markdown into the textarea; user edits plain text with live preview in read mode"*, whereas Option B is defined as an interactive spreadsheet grid modal. Mistral's reasoning describes the exact mechanism of Option A (Markdown template insertion into textarea), while calling visual editing "Option A" and template insertion "Option B".
- **Conclusion**: In substantive intent, all 4 seats agree that a toolbar button inserting a Markdown pipe skeleton into the paragraph textarea is the correct path. Even treating Mistral's choice formally as B, the 3-to-1 majority for Option A holds. An interactive grid modal helper can be introduced in a future enhancement as a client-side convenience over the same Markdown body text. Option A is adopted.

---

## 2. Verified Corrections to spec.md and tasks.md

The panel identified 5 required corrections across `spec.md` and `tasks.md`. Each correction was verified against the repository codebase and migrations prior to adoption:

### 2.1 Correction 1: Rescope T020 and fix spec SQL in §4.2.2 (RLS and GUCs already live)

- **Finding**: Spec §4.2.2 and `tasks.md` T020 proposed creating RLS policies from scratch using draft GUC names `spool.tenant_id` and `spool.operator_scope`. In reality, Row-Level Security, `FORCE ROW LEVEL SECURITY`, and composite foreign keys are already active on all four doctree tables, using GUCs `app.tenant_id` and `app.rls_scope = 'operator'`.
- **Verification command**:
  ```bash
  grep -n -E "ROW LEVEL SECURITY|app\.tenant_id|app\.rls_scope|spool\.tenant_id" \
    csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql \
    csi-spl-rdb/src/sql/postgres/spool-hub/0165_workspace_doc_node.sql
  ```
- **Output confirmed**:
  - `0157_workspace_docs.sql:84-109`: `ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY` applied to `workspace_doc`, `workspace_doc_item`, and `workspace_doc_rev_log`, with policies checking `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')` and `current_setting('app.rls_scope', true) = 'operator'`.
  - `0165_workspace_doc_node.sql:83-90`: `ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY` applied to `workspace_doc_node` using identical `app.*` GUCs.
  - `0157_workspace_docs.sql:64-67,79-80`: Composite FKs `(tenant_id, doc_id)` already enforce tenant isolation.
- **Application**:
  - Update `spec.md` §4.2.2 to cite the live GUCs (`app.tenant_id`, `app.rls_scope`) and remove redundant `ENABLE/FORCE ROW LEVEL SECURITY` statements.
  - Rescope `tasks.md` T020: Do not re-enable RLS; instead, insert the reserved `system` row into `tenants`, add the permissive `FOR SELECT` policy for `tenant_id = 'system'`, and filter the `system` tenant from workspace listing endpoints.

### 2.2 Correction 2: Deprecate Spec 075 repo-edit path before T040

- **Finding**: Spec 075 introduced `PUT /v1/docs/{path}` saving GCS overlays and a background worker (`repodocs.Worker`) pushing direct Git commits. If T040 (pre-push gate) lands without deprecating or disabling this path for mapped documents, the background worker will attempt to push `.md` commits and fail against the gate.
- **Verification command**:
  ```bash
  git grep -n -E "repo_docs_edit|repodocs" csi-spl-api/
  ```
- **Output confirmed**:
  - `csi-spl-api/src/go/spool-hub-api/internal/hub/repo_docs_edit.go`: Active HTTP handler for `PUT /v1/docs/{path}` saving to GCS overlay bucket.
  - `csi-spl-api/src/go/spool-hub-api/internal/repodocs/worker.go`: Active worker polling overlays and pushing git commits.
- **Application**:
  - Add task T024 ahead of T040 to disable or reject Spec 075 repo-edit requests for any file path registered in `qto-docs.tsv`, and specify the decommission plan for the docs bucket in T022.

### 2.3 Correction 3: Add exporter support for `attrs.numbered` and move T032 to Phase 1

- **Finding**: `spl-doctree-md.py` cannot support unnumbered headings in isolation. Outline numbers are computed at read time by `outlineOf()` in `workspace_docs_read.go:112`, and both exporters (`doctree_export.go:157` and `-doctree-export.ts:24`) unconditionally prepend `${it.outline}`. Furthermore, `doctree-export-md.tst.sh` tests against a Python stub instead of the compiled Go `spool` binary.
- **Verification commands**:
  ```bash
  sed -n '105,125p' csi-spl-api/src/go/spool-hub-api/internal/store/workspace_docs_read.go
  sed -n '150,165p' csi-spl-api/src/go/spool-hub-api/cmd/spool/doctree_export.go
  sed -n '20,30p' csi-spl-wui/src/components/workspace-docs/-doctree-export.ts
  sed -n '30,55p' csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh
  ```
- **Output confirmed**:
  - `workspace_docs_read.go:112`: Computes `it.Outline = outlineOf(path)` unconditionally from ord path.
  - `doctree_export.go:157`: Formats `strings.Repeat("#", level)+" "+it.Outline+" "+title`.
  - `-doctree-export.ts:24`: Formats `${'#'.repeat(level)} ${it.outline} ${it.title || untitled}`.
  - `doctree-export-md.tst.sh:36-52`: Embeds a Python mock stub for `spool`.
- **Application**:
  - Add task T012a ahead of T012: Update `workspace_docs_read.go`, `doctree_export.go`, `-doctree-export.ts`, and `WorkspaceDocView.vue` to respect `attrs.numbered = false` (suppressing outline prefix when false).
  - Move T032 (compiled Go export test) to Phase 1 ahead of T012-T015 so all export alterations are validated against the actual compiled binary.

### 2.4 Correction 4: Target schema for front matter in T014 (`workspace_doc` has no `attrs`)

- **Finding**: `tasks.md` T014 proposed storing YAML front matter in `workspace_doc.attrs.front_matter`. However, `workspace_doc` has no `attrs` column. In contrast, `workspace_doc_item` has an `attrs JSONB` column, and each document already possesses a hidden root item (`WHERE parent_id IS NULL`) whose `body` holds the document preamble.
- **Verification commands**:
  ```bash
  sed -n '33,43p' csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql
  cat csi-spl-rdb/src/sql/postgres/spool-hub/0164_workspace_doc_description.sql
  ```
- **Output confirmed**:
  - `workspace_doc` columns: `id`, `tenant_id`, `title`, `rev`, `created_by`, `created_at`, `updated_at`, and `description` (0164). No `attrs` column exists.
  - `workspace_doc_item` (0157:52): `attrs jsonb NOT NULL DEFAULT '{}'::jsonb`.
  - `workspace_doc_item_one_root` (0157:69): Unique index ensuring exactly one root item per document.
- **Application**:
  - Update `spec.md` §2 (F10) and `tasks.md` T014 to store parsed YAML front matter in the root item's `attrs.front_matter` JSONB, requiring zero schema migrations.

### 2.5 Correction 5: Decompose T030 into incremental slices, fix T002 gate, and clarify T031

- **Finding**: Batch-importing all 1,257 repository Markdown files in a single execution carries high operational risk because tree modifications lock the tenant root node (`0165_workspace_doc_node.sql:177`). Additionally, `tasks.md` T002 cited `reviews/` rather than `panel/<seat>.md`, and T031's gate (`git status --porcelain` clean) contradicted the required export stamp header.
- **Verification commands**:
  ```bash
  cat csi-spl-doc/doc/md/qto-docs.tsv
  echo -n "doc: "; git ls-files 'csi-spl-doc/doc/*.md' | wc -l; \
  echo -n "specs: "; git ls-files 'csi-spl-doc/specs/*.md' | wc -l; \
  echo -n "outside: "; git ls-files '*.md' ':!:csi-spl-doc/*.md' | wc -l
  git ls-files '*.md' | wc -l
  ```
- **Output confirmed**:
  - `qto-docs.tsv` currently tracks exactly 2 documents.
  - Markdown file counts: 220 under `csi-spl-doc/doc/`, 504 under `csi-spl-doc/specs/`, 99 outside `csi-spl-doc/` (total 1,257 files at current HEAD).
  - Panel files are committed in `panel/claude.md`, `panel/mistral.md`, `panel/agy.md`, and `panel/grok.md`.
- **Application**:
  - Decompose T030 into four manageable subtasks:
    - `T030a`: Migrate initial 2 mapped documents to `system` tenant.
    - `T030b`: Bulk import `csi-spl-doc/doc/*.md` (220 files).
    - `T030c`: Bulk import `csi-spl-doc/specs/*.md` (504 files).
    - `T030d`: Bulk import remaining repository docs (99 files).
  - Update T002 gate to verify reviews committed in `panel/<seat>.md` and folded in `panel/consensus.md`.
  - Clarify T031 pass criteria: `git diff` produces zero modifications other than the intentional export stamp line (`> Generated from qto doc <id>; edit it there.`).

---

## 3. Implementation Lane Groups (Disjoint File Sets)

To enable concurrent development without file collisions, tasks are grouped into independent lanes operating on disjoint file paths:

### Lane Group 1: `wui-editor` (Web UI components & styles)
- **Primary file paths**: `csi-spl-wui/src/components/workspace-docs/*`, `csi-spl-wui/src/utils/markdown.mjs`, `csi-spl-wui/src/tests/*`
- **Tasks**:
  - `T010`: Interactive table insertion tool in `WorkspaceDocView.vue`.
  - `T011`: Blockquote and citation tool in `WorkspaceDocView.vue` and `MarkdownBlock.vue`.
  - `T018`: WUI Markdown renderer extensions in `markdown.mjs` (task lists, footnotes, heading slugs).
  - `T023`: Unified Explorer tree UI navigation component.

### Lane Group 2: `orc-parser` (CLI, Go exporters, and import/export tooling)
- **Primary file paths**: `csi-spl-orc/src/bash/run/spl-doctree*`, `csi-spl-orc/src/bash/tests/doctree*`, `csi-spl-api/cmd/spool/doctree*`, `csi-spl-api/src/go/spool-hub-api/internal/store/workspace_docs_read.go`
- **Tasks**:
  - `T032`: Compiled Go binary export test harness in `doctree-export-md.tst.sh`.
  - `T012a`: Honor `attrs.numbered = false` in `workspace_docs_read.go` and paired exporters (`doctree_export.go`, `-doctree-export.ts`).
  - `T012`: Support unnumbered headings in `spl-doctree-md.py`.
  - `T013`: Deep heading level support (levels 4-6) without truncation.
  - `T014`: YAML front matter extraction and preservation in root item `attrs.front_matter`.
  - `T015`: Multi-backtick and nested code fence tracking in parser.
  - `T016`: Transactional execution and rollback in `spl-doctree-import-md.func.sh`.
  - `T017`: Removal of `csi-spl-doc/*.md` path restriction in import/export scripts.

### Lane Group 3: `rdb-api` (PostgreSQL schemas, RLS, and Hub API routing)
- **Primary file paths**: `csi-spl-rdb/src/sql/postgres/spool-hub/*`, `csi-spl-api/src/go/spool-hub-api/internal/hub/*`
- **Tasks**:
  - `T020`: Unified file system migration: `system` tenant row in `tenants`, permissive SELECT policy for `system` across doctree tables, tenant list filtering.
  - `T021`: Extensible capability ACL schema (`workspace_doc_acl`).
  - `T022`: Hub API unified file system routing (`/v1/docs/*` to `system` tenant).
  - `T024`: Deprecate and reject Spec 075 repo-edit overlay calls for mapped paths.

### Lane Group 4: `bulk-import` (Phase 3 data migration & export parity)
- **Primary file paths**: `csi-spl-doc/doc/md/qto-docs.tsv`, `csi-spl-doc/**`
- **Tasks**:
  - `T030a`: Migrate initial 2 mapped documents to `system` tenant.
  - `T030b`: Bulk import `csi-spl-doc/doc/*.md` (220 files).
  - `T030c`: Bulk import `csi-spl-doc/specs/*.md` (504 files).
  - `T030d`: Bulk import remaining repository docs (99 files).
  - `T031`: Byte-stable export parity validation.
  - `T019`: Live production proof in prd workspace `t1`.

### Lane Group 5: `gates-retire` (Phase 4 & 5 gates, tooling, and documentation)
- **Primary file paths**: `csi-spl-iac/src/bash/run/spl-check-pre-push.func.sh`, `.github/workflows/10_ci-quality.yml`, `csi-spl-doc/doc/md/developer-guide.md`, `CLAUDE.md`
- **Tasks**:
  - `T040`: Pre-push gate rejecting direct manual edits to mapped `.md` files.
  - `T041`: CI quality gate export drift verification.
  - `T050`: Update developer guide and agent seed instructions.
  - `T051`: Agent harness tooling verification across vendor seats.

---

<!-- version: 0.2.0 · updated: 2026-10-14 · last-edit: 2026-10-14T00:45:00Z -->
