# Tasks: Spec 137 — Qto as the only doc editor, unified file system, and md retirement

Status vocabulary: `Implemented` (artifact exists and check passes), `Partial` (some exists), `Planned` (nothing built yet).
Docs only: this task list defines the work; implementation lanes execute it (`../README.md` §2.4).
Authority: [spec.md](spec.md) for requirements; this file for task status and acceptance gates.

---

## 0. Inventory & baseline

| ID | Status | Area | Summary & Gate |
|---|---|---|---|
| **T001** | **Implemented** | `doc` | **Catalog full Markdown feature inventory & measured scale** (§1, §2). 1,247 repo md files inspected; 27 markdown features evaluated across editor, round-trip, and renderer; import tool failure modes analyzed. Verified by check commands in §1. |
| **T002** | **Planned** | `panel` | **Convene Step 2 expert panel** (§6). 5 vendor seats (`s137-claude`, `s137-grok`, `s137-mistral`, `s137-agy`, `s137-qwen`) review questions P-Q1..P-Q5 and sign consensus reviews. Gate: 5 reviews committed in `reviews/`. |

---

## 1. Phase 1: Qto editor gap closure & parser upgrade

| ID | Status | Area | Summary & Gate |
|---|---|---|---|
| **T010** | **Planned** | `wui` | **Interactive table insertion tool in Qto paragraph toolbar** (§3.1, Owner msg 2c82489a). Add `insert_table` button in `WorkspaceDocView.vue` toolbar; insert pipe table template into textarea; renders in `MdRun`. Gate: table editing test in `workspace-doctree.test.mjs`. |
| **T011** | **Planned** | `wui` | **Quote & citation tool in Qto paragraph toolbar** (§3.2, Owner msg b1661d1c). Add `insert_quote` button in `WorkspaceDocView.vue` toolbar; insert blockquote with attribution line; styled blockquote card. Gate: quote rendering test in `workspace-doctree.test.mjs`. |
| **T012** | **Planned** | `orc` | **Support unnumbered headings in `spl-doctree-md.py`** (§2 F07). Permit headings without numeric outlines; treat as outline-less node; preserve heading text on export. Gate: unit test with `## Overview` parses and exports cleanly. |
| **T013** | **Planned** | `orc` | **Support headings deeper than `####` and preserve levels on export** (§2 F04-F06). Allow depth 4-6 in Qto item model; export without artificial `#` shifting that caps at 6. Gate: 5-level nested outline test passes. |
| **T014** | **Planned** | `orc` | **Preserve YAML front matter** (§2 F10). Parse `---` YAML headers into `workspace_doc.attrs.front_matter` JSONB; regenerate on export. Gate: front matter round-trip test passes. |
| **T015** | **Planned** | `orc` | **Multi-backtick & nested fence tracking** (§2 F17). Replace naive regex toggle with stateful fence parser tracking fence character count (` ```` ` vs ` ``` `). Gate: nested code fence round-trip test. |
| **T016** | **Planned** | `orc` | **Transactional import in `spl-doctree-import-md.func.sh`** (§1.3, FR-008). Execute import inside a single transaction or rollback atomically on failure; eliminate orphaned partial docs. Gate: failure test leaves 0 DB rows. |
| **T017** | **Planned** | `orc` | **Remove `csi-spl-doc/*.md` path restriction** (§1.3, FR-009). Update `_spl_doctree_md_path` in `spl-doctree-export-md.func.sh` and `spl-doctree-import-md.func.sh` to permit any repo-relative `.md` path. Gate: export works on root `README.md`. |
| **T018** | **Planned** | `wui` | **WUI Markdown renderer extensions** (§1.4, F18-F20). Add plugins to `markdown.mjs` for task lists (`- [ ]`), footnotes (`[^1]`), and heading slug IDs. Gate: `markdown.test.mjs` verifies rendered tokens. |
| **T019** | **Planned** | `proof` | **Live production proof for tables and citations** (§3.1, §3.2). Create test doc in prd workspace `t1` with table and quote; verify render and export. Gate: `do_spl_doctree_export_md` round trip succeeds on prd. |

---

## 2. Phase 2: Unified spool-hub file system & tenant segregation

| ID | Status | Area | Summary & Gate |
|---|---|---|---|
| **T020** | **Planned** | `rdb` | **Unified file system migration: `system` tenant & RLS policies** (§4.1, §4.2, rdb migration `01NN`). Establish `system` tenant for repo docs; apply `FORCE ROW LEVEL SECURITY` on `workspace_doc_node`, `workspace_doc`, `workspace_doc_item`; allow read of `system` to all tenants, write to operators only. Gate: RLS isolation test proves cross-tenant blindness and system immutability. |
| **T021** | **Planned** | `rdb` | **Extensible capability ACL schema** (§4.3). Create `workspace_doc_acl` table (node_id, subject, action, effect); default to Layer 1 workspace RBAC. Gate: ACL evaluation tests prove allow/deny inheritance over nested set. |
| **T022** | **Planned** | `api` | **Hub API unified file system routing** (§4.1). Unify `/v1/docs/*` (Spec 075) and `/v1/workspace/docs/*` (Spec 113/120) under unified tree endpoints; serve repo docs from `system` tenant DB rows. Gate: API tests pass under both workspace and operator sessions. |
| **T023** | **Planned** | `wui` | **Unified Explorer Tree UI** (§4.1). Single Explorer tree component in WUI displaying `/repo` (system docs) and `/workspace` (team docs) in one seamless hierarchy. Gate: Cypress/Playwright e2e test verifies navigation across both trees. |

---

## 3. Phase 3: Bulk import & byte-stable export parity

| ID | Status | Area | Summary & Gate |
|---|---|---|---|
| **T030** | **Planned** | `orc` | **Bulk import runner for all 1,247 repository Markdown files** (§5.2 Phase 2). Batch-import all `.md` files into `system` tenant; populate `csi-spl-doc/doc/md/qto-docs.tsv`. Gate: `do_spl_doc_tree_check` reports 0 hierarchy violations across 1,247 documents. |
| **T031** | **Planned** | `orc` | **Byte-stable export parity verification** (§5.2 Phase 3). Run `do_spl_doctree_export_md` across all 1,247 mapped docs; verify `git diff` produces zero unintended changes. Gate: `git status --porcelain` is clean after full export. |
| **T032** | **Planned** | `test` | **Compiled Go binary export test** (§1.3). Replace Python stub in `doctree-export-md.tst.sh` with direct testing of compiled `spool doctree export` binary. Gate: test runs green using compiled `spool`. |

---

## 4. Phase 4: Git pre-push gate & CI enforcement

| ID | Status | Area | Summary & Gate |
|---|---|---|---|
| **T040** | **Planned** | `orc` | **Pre-push gate checks mapped `.md` files against export** (§5.2 Phase 4). Add check to `spl-check-pre-push.func.sh` refusing commits that modify mapped `.md` files without corresponding database update. Gate: test commits manual edit; hook refuses push with diagnostic error. |
| **T041** | **Planned** | `ci` | **CI quality gate export drift verification** (§5.2 Phase 4). Workflow `10_ci-quality.yml` checks that committed `.md` files match database export hash. Gate: CI turns red on manual markdown tampering. |

---

## 5. Phase 5: Complete retirement of manual markdown editing

| ID | Status | Area | Summary & Gate |
|---|---|---|---|
| **T050** | **Planned** | `doc` | **Update developer guides & agent seed rules** (§5.2 Phase 5). Update `csi-spl-doc/doc/md/developer-guide.md`, `CLAUDE.md`, and agent prompts; document that Qto and `spool doc-*` are the sole authoring interfaces. Gate: documentation reflects Qto-only workflow. |
| **T051** | **Planned** | `sa` | **Agent harness tooling for doc management** (§5.1). Ensure claude, grok, mistral, agy, and qwen harnesses expose `spool doc-*` CLI and MCP tools for seamless agent documentation tasks. Gate: agent harness test verifies doc operations. |

<!-- version: 0.1.0 · updated: 2026-10-13 · last-edit: 2026-10-13T21:00:00Z -->
