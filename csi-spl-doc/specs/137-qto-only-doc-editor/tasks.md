# Tasks: Spec 137 — Qto as the only doc editor, unified file system, and md retirement

Status vocabulary: `Implemented` (artifact exists and check passes), `Partial` (some exists), `Planned` (nothing built yet).  
Status: **Ready to build** (Step 2 panel consensus folded, SPL-1743).  
Authority: [spec.md](spec.md) for requirements; this file for task status and acceptance gates; [panel/consensus.md](panel/consensus.md) for consensus decisions.  
Docs only: this task list defines the work; implementation lanes execute it (`../README.md` §2.4).

---

## 0. Inventory & baseline

| ID | Status | Area | Summary & Gate |
|---|---|---|---|
| **T001** | **Implemented** | `doc` | **Catalog full Markdown feature inventory & measured scale** (§1, §2). 1,247 repo md files inspected; 27 markdown features evaluated across editor, round-trip, and renderer; import tool failure modes analyzed. Verified by check commands in §1. |
| **T002** | **Implemented** | `panel` | **Convene Step 2 expert panel** (§6). 4 vendor seats (`s137-claude`, `s137-grok`, `s137-mistral`, `s137-agy`) review questions P-Q1..P-Q5; `s137-qwen` not placed (no CLI on sat; load gate). Gate: 4 reviews committed in `panel/<seat>.md` and consensus folded in `panel/consensus.md`. |

---

## 1. Phase 1: Qto editor gap closure & parser upgrade

| ID | Status | Area | Lane | Summary & Gate |
|---|---|---|---|---|
| **T010** | **Implemented** | `wui` | `wui-editor` | **Interactive table insertion tool in Qto paragraph toolbar** (§3.1, Owner msg 2c82489a, P-Q3 Choice A). Add `insert_table` button (`ws-doc-insert-table`) in `WorkspaceDocView.vue` toolbar; insert pipe table skeleton template into textarea; renders in `MdRun`. Gate: table editing test in `workspace-doctree.test.mjs`. Built (SPL-1744): `ws-doc-insert-table` beside Insert picture; `-doc-blocks.ts` `tableBlock` + `insertBlock` (own block, blank line each side, Header 1 selected). Checked: `tests/unit/doc-blocks.test.mjs` (n=9) and `workspace-doctree.test.mjs` T010/T011 steps (rendered table, hub body, Markdown export). |
| **T011** | **Implemented** | `wui` | `wui-editor` | **Quote & citation tool in Qto paragraph toolbar** (§3.2, Owner msg b1661d1c, P-Q4 Choice A). Add `insert_quote` button (`ws-doc-insert-quote`) in `WorkspaceDocView.vue` toolbar; insert blockquote template with attribution line (`> passage\n>\n> — [Source](url)`); styled blockquote card and citation footer in `MarkdownBlock.vue`. Gate: quote rendering test in `workspace-doctree.test.mjs`. Built (SPL-1744): `ws-doc-insert-quote` (a selection becomes the passage); `markdown.mjs` marks a quote's last `— ` / `-- ` paragraph `p[data-cite]`; `MarkdownBlock.vue` styles the quote card and the citation line. Checked: same tests as T010 (computed italic quote, upright citation). |
| **T032** | **Implemented** | `test` | `orc-parser` | **Compiled Go binary export test harness** (§1.3, moved ahead of T012 per Correction 3). Replace Python stub in `doctree-export-md.tst.sh` with direct testing of compiled `spool doctree export` binary. Gate: test runs green using compiled `spool`. Done (SPL-1745): the test builds `spool` and its fake runs `spool doctree export <doc> --from <read.json>` (new flag: a saved read answer, no hub). `bash csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` -> 28 PASS (19 FAIL on the old code). |
| **T012a** | **Implemented** | `orc`/`api` | `orc-parser` | **Support unnumbered headings in outline derivation and exporters** (§2 F07, P-Q1 Choice A, added per Correction 3). Update `workspace_docs_read.go:112`, `doctree_export.go:157`, `-doctree-export.ts:24`, and WUI view to honor `attrs.numbered = false` (suppress outline prefix when false, skip in sibling ord). Gate: Go and TS export tests verify unnumbered item produces no outline prefix. Done in this lane (SPL-1745): the store derives no outline for an unnumbered item or one under it and skips it among its siblings (`workspace_docs_read.go`, `TestWorkspaceDocUnnumberedOutline`, `TestOutlineOfUnnumbered` (Postgres, red on the old code)); `doctree_export.go` prints no number for it and finds a branch by depth; `spool doctree add --kind heading --unnumbered` and `edit --field attrs.<key>` (`go test -run DocTree ./cmd/spool/` (3 new tests + the refusals, red on the old code)). Hub (SPL-1752): the lazy children route's parent `outline` is the store's number (`DocChildrenResult.Outline`), not its ord path (`TestWorkspaceDocLazyChildrenUnnumbered`, Postgres, red on the old code). WUI half done (SPL-1753): one helper `-doc-outline.ts` (`siblingNumbers`, `outlineOf`, `headingText`, `branchOf` by depth) used by `-doctree-export.ts` (no number on an unnumbered heading, the CLI's text), `WorkspaceDocView.vue` (no prefix in the heading or the contents, branch by depth) and the mock tenant's outline (`node tests/unit/doc-outline.test.mjs` (12 tests, the CLI parity case, red on the old code, numbered controls)). |
| **T012** | **Implemented** | `orc` | `orc-parser` | **Support unnumbered headings in `spl-doctree-md.py`** (§2 F07, P-Q1 Choice A). Update splitter/composer to parse `## Heading` without numeric prefix and set `attrs.numbered = false`. Gate: unit test with `## Overview` parses and exports cleanly. Done (SPL-1745): `## Overview` imports with `--unnumbered`; a heading under an unnumbered one is unnumbered, its text kept whole as the title. `bash csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` -> 28 PASS (19 FAIL on the old code). |
| **T013** | **Implemented** | `orc` | `orc-parser` | **Support headings deeper than `####` and preserve levels on export** (§2 F04-F06). Allow depth 4-6; do not fold depths onto h6 or truncate; preserve `#` levels. Gate: 5-level nested outline test passes. Done (SPL-1745): `####` .. `######` import; a 5-level outline round-trips with no level folded. `bash csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` -> 28 PASS (19 FAIL on the old code). |
| **T014** | **Implemented** | `orc` | `orc-parser` | **Preserve YAML front matter** (§2 F10, updated per Correction 4). Parse `---` YAML headers into root item's `attrs.front_matter` JSONB (`workspace_doc_item` where `parent_id IS NULL`, zero SQL migrations); regenerate YAML header on export. Gate: front matter round-trip test passes. Done (SPL-1745): the YAML text is stored as the string `attrs.front_matter` (byte-stable, no YAML parser) and written back as `---` block, blank line, `# ` title. `bash csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` -> 28 PASS (19 FAIL on the old code). |
| **T015** | **Implemented** | `orc` | `orc-parser` | **Multi-backtick & nested fence tracking** (§2 F17). Replace naive regex toggle with stateful fence parser tracking fence backtick count (` ```` ` vs ` ``` `). Gate: nested code fence round-trip test. Done (SPL-1745): `Fences` in `spl-doctree-md.py` tracks the opening run (CommonMark); split and compose both use it. `bash csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` -> 28 PASS (19 FAIL on the old code). |
| **T016** | **Implemented** | `orc` | `orc-parser` | **Transactional import in `spl-doctree-import-md.func.sh`** (§1.3, FR-008). Execute import inside a single transaction or rollback atomically on failure; eliminate orphaned partial docs. Gate: failure test leaves 0 DB rows. Done (SPL-1745): the hub has no multi-write transaction, so a failed write after the create deletes the doc (`doctree delete`): 0 items, no map row. `bash csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` -> 28 PASS (19 FAIL on the old code). |
| **T017** | **Implemented** | `orc` | `orc-parser` | **Remove `csi-spl-doc/*.md` path restriction** (§1.3, FR-009). Update `_spl_doctree_md_path` in `spl-doctree-export-md.func.sh` and `spl-doctree-import-md.func.sh` to permit any repo-relative `.md` path. Gate: export works on root `README.md`. Done (SPL-1745): any repo-relative `.md` path (no leading `/`, no `.`/`..` step, not under `.git/`). `bash csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` -> 28 PASS (19 FAIL on the old code). |
| **T018** | **Implemented** | `wui` | `wui-editor` | **WUI Markdown renderer extensions** (§1.4, F18-F20). Add plugins to `markdown.mjs` for task lists (`- [ ]`), footnotes (`[^1]`), and heading slug IDs. Gate: `markdown.test.mjs` verifies rendered tokens. Built (SPL-1744) as passes in `markdown.mjs`, no markdown-it plugin: task items `li[data-task]`, footnotes (`splitFootnotes`, `sup` + `ol[data-footnotes]`), and with `anchors` (the /docs page, the repo pane) `md-`-prefixed heading slugs, footnote links and `#slug` links. Checked: `markdown.test.mjs` (9 new tests, 6 red on the old renderer). |
| **T019** | **Planned** | `proof` | `bulk-import` | **Live production proof for tables and citations** (§3.1, §3.2). Create test doc in prd workspace `t1` with table and quote; verify render and export. Gate: `do_spl_doctree_export_md` round trip succeeds on prd. |

---

## 2. Phase 2: Unified spool-hub file system & tenant segregation

| ID | Status | Area | Lane | Summary & Gate |
|---|---|---|---|---|
| **T020** | **Planned** | `rdb` | `rdb-api` | **Unified file system migration: `system` tenant & permissive SELECT RLS** (§4.1, §4.2, rescoped per Correction 1, rdb migration `0170`). Insert reserved `system` row in `tenants`; add permissive `FOR SELECT` policy for `tenant_id = 'system'` across `workspace_doc_node`, `workspace_doc`, `workspace_doc_item`, `workspace_doc_rev_log`; filter `system` tenant from workspace listing APIs. Gate: RLS isolation test proves cross-tenant blindness and system immutability. |
| **T021** | **Planned** | `rdb` | `rdb-api` | **Extensible capability ACL schema** (§4.3). Create `workspace_doc_acl` table (node_id, subject, action, effect); default to Layer 1 workspace RBAC. Gate: ACL evaluation tests prove allow/deny inheritance over nested set. |
| **T022** | **Planned** | `api` | `rdb-api` | **Hub API unified file system routing** (§4.1). Unify `/v1/docs/*` (Spec 075) and `/v1/workspace/docs/*` (Spec 113/120) under unified tree endpoints; serve repo docs from `system` tenant DB rows; specify docs bucket deprecation. Gate: API tests pass under both workspace and operator sessions. |
| **T023** | **Implemented** | `wui` | `wui-editor` | **Unified Explorer Tree UI** (§4.1). Single Explorer tree component in WUI displaying `/repo` (system docs) and `/workspace` (team docs) in one seamless hierarchy. Gate: Cypress/Playwright e2e test verifies navigation across both trees. Built (SPL-1744), desktop: a Repository row under the workspace documents in `QtoFileTree.vue` holds the repo docs (tree.json) as folders and files; a file opens read-only in `WorkspaceRepoDoc.vue` (`?repo=<path>`), a workspace row opens the Qto doc again. Repo docs are still read through `/v1/docs` until T020..T024 move them into the database; the phone's drill list keeps the workspace docs only. Checked: `tests/e2e/qto-unified-explorer.test.mjs` (n=17). |
| **T024** | **Planned** | `api` | `rdb-api` | **Deprecate Spec 075 repo-edit path before T040** (§5.2, K10, added per Correction 2). Disable or reject `PUT /v1/docs/{path}` repo-edit overlay calls for any files mapped in `qto-docs.tsv`, preventing background git commit collisions. Gate: test verifies `PUT /v1/docs/{path}` returns 409/403 for mapped docs. |

---

## 3. Phase 3: Bulk import & byte-stable export parity

| ID | Status | Area | Lane | Summary & Gate |
|---|---|---|---|---|
| **T030a** | **Planned** | `orc` | `bulk-import` | **Migrate initial 2 mapped docs into `system` tenant** (split per Correction 5). Repoint `runbook-dispatcher.md` and `runbook-orchestrator.md` in `qto-docs.tsv` to `system` tenant. Gate: 2 docs accessible under `system` tenant. |
| **T030b** | **Planned** | `orc` | `bulk-import` | **Bulk import `csi-spl-doc/doc/*.md`** (220 files, split per Correction 5). Batch-import into `system` tenant; append to `qto-docs.tsv`. Gate: `do_spl_doc_tree_check` reports 0 hierarchy violations on doc slice. |
| **T030c** | **Planned** | `orc` | `bulk-import` | **Bulk import `csi-spl-doc/specs/*.md`** (504 files, split per Correction 5). Batch-import into `system` tenant; append to `qto-docs.tsv`. Gate: `do_spl_doc_tree_check` reports 0 hierarchy violations on specs slice. |
| **T030d** | **Planned** | `orc` | `bulk-import` | **Bulk import remaining repository docs outside `csi-spl-doc/`** (99 files, split per Correction 5). Import root and module markdown after T017. Gate: `do_spl_doc_tree_check` reports 0 violations across all 1,257 documents. |
| **T031** | **Planned** | `orc` | `bulk-import` | **Byte-stable export parity verification** (§5.2 Phase 3, updated per Correction 5). Run `do_spl_doctree_export_md` across all mapped docs; verify `git diff` produces zero unintended changes. Gate: `git diff` shows only the standardized export stamp header line (`> Generated from qto doc <id>; edit it there.`). |

---

## 4. Phase 4: Git pre-push gate & CI enforcement

| ID | Status | Area | Lane | Summary & Gate |
|---|---|---|---|---|
| **T040** | **Planned** | `orc` | `gates-retire` | **Pre-push gate checks mapped `.md` files against export** (§5.2 Phase 4, P-Q5 Choice A). Add check to `spl-check-pre-push.func.sh` refusing commits that modify mapped `.md` files without corresponding database update. Gate: test commits manual edit; hook refuses push with diagnostic error. |
| **T041** | **Planned** | `ci` | `gates-retire` | **CI quality gate export drift verification** (§5.2 Phase 4). Workflow `10_ci-quality.yml` checks that committed `.md` files match database export hash. Gate: CI turns red on manual markdown tampering. |

---

## 5. Phase 5: Complete retirement of manual markdown editing

| ID | Status | Area | Lane | Summary & Gate |
|---|---|---|---|---|
| **T050** | **Planned** | `doc` | `gates-retire` | **Update developer guides & agent seed rules** (§5.2 Phase 5). Update `csi-spl-doc/doc/md/developer-guide.md`, `CLAUDE.md`, and agent prompts; document that Qto and `spool doc-*` are the sole authoring interfaces. Gate: documentation reflects Qto-only workflow. |
| **T051** | **Planned** | `sa` | `gates-retire` | **Agent harness tooling for doc management** (§5.1). Ensure claude, grok, mistral, agy, and qwen harnesses expose `spool doc-*` CLI and MCP tools for seamless agent documentation tasks. Gate: agent harness test verifies doc operations. |

---

## 6. Parallel Lane Groups (Disjoint File Sets)

To allow multiple lanes to execute simultaneously without worktree merge collisions, tasks are partitioned into 5 independent lane groups with completely disjoint file paths:

| Lane Group | Task IDs | Target File Paths | Concurrent With |
|---|---|---|---|
| **`wui-editor`** | `T010`, `T011`, `T018`, `T023` | `csi-spl-wui/src/components/workspace-docs/*`<br>`csi-spl-wui/src/utils/markdown.mjs`<br>`csi-spl-wui/src/tests/*` | Can run in parallel with `orc-parser` and `rdb-api` immediately in Phase 1. |
| **`orc-parser`** | `T032`, `T012a`, `T012`, `T013`, `T014`, `T015`, `T016`, `T017` | `csi-spl-orc/src/bash/run/spl-doctree*`<br>`csi-spl-orc/src/bash/tests/doctree*`<br>`csi-spl-api/cmd/spool/doctree*`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/workspace_docs_read.go` | Can run in parallel with `wui-editor` and `rdb-api` immediately in Phase 1. |
| **`rdb-api`** | `T020`, `T021`, `T022`, `T024` | `csi-spl-rdb/src/sql/postgres/spool-hub/*`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/*` | Can run in parallel with `wui-editor` immediately in Phase 1/2. |
| **`bulk-import`** | `T030a`, `T030b`, `T030c`, `T030d`, `T031`, `T019` | `csi-spl-doc/doc/md/qto-docs.tsv`<br>`csi-spl-doc/**` | Runs in Phase 3 after `orc-parser` and `rdb-api` land. |
| **`gates-retire`** | `T040`, `T041`, `T050`, `T051` | `csi-spl-iac/src/bash/run/spl-check-pre-push.func.sh`<br>`.github/workflows/10_ci-quality.yml`<br>`csi-spl-doc/doc/md/developer-guide.md`<br>`CLAUDE.md` | Runs in Phase 4 & 5 after bulk import parity is proven. |

<!-- version: 0.2.1 · updated: 2026-10-14 · last-edit: 2026-10-13T22:08:49Z -->
