# Spec 137 panel: seat s137-claude

Seat: `s137-claude` (agent c-957), spec 137 section 6, step 2 of task
dispatch-bed3ed0a. Reviewed: `spec.md` v0.1.0 and `tasks.md` as landed in
43472c355 (SPL-1730), against the code on origin/master on 2026-10-14.
Doc only: this file builds nothing.

## 0. The five choices in one line

P-Q1 **A** (as `attrs.numbered = false`), P-Q2 **A** (one reserved repo
workspace, read-only by RLS), P-Q3 **A** (pipe-table skeleton in the body),
P-Q4 **A** (Markdown blockquote in the body), P-Q5 **A** (hard gate, keyed on
the map and the export stamp, phased in per mapped file).

## 1. Facts from the code that the choices rest on

| # | fact | where |
|---|---|---|
| K1 | An item is a heading; its body is the paragraph text; its attrs carry one code block and one image. There is no item `kind` column. | `csi-spl-api/src/go/spool-hub-api/cmd/spool/doctree.go:42-52`, `csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql:44-62` |
| K2 | `workspace_doc_item.attrs` is a free JSONB object: a new per-item flag needs no migration. | `0157_workspace_docs.sql:52` |
| K3 | `workspace_doc` has NO `attrs` column (id, tenant_id, title, rev, created_by, timestamps; 0164 adds `description`). | `0157_workspace_docs.sql:33-42`, `0164_workspace_doc_description.sql:9` |
| K4 | The outline is derived from the ord path at read, never stored. | `csi-spl-api/src/go/spool-hub-api/internal/store/workspace_docs_read.go:107-113` |
| K5 | Both exporters print the outline on every heading unconditionally. | `cmd/spool/doctree_export.go:156-157`, `csi-spl-wui/src/components/workspace-docs/-doctree-export.ts:24` |
| K6 | The CLI already has `doctree add --kind table`: it appends a Markdown table to the item body. | `cmd/spool/doctree.go:34,51` |
| K7 | The renderer already allows `blockquote` and the table tags, and pipe tables parse. | `csi-spl-wui/src/utils/markdown.mjs:43-45` |
| K8 | RLS with composite tenant FKs is ALREADY live on all four tables. The GUCs are `app.tenant_id` and `app.rls_scope = 'operator'`, not the `spool.tenant_id` / `spool.operator_scope` of spec section 4.2.2. | `0157_workspace_docs.sql:64-67,84-106`, `0165_workspace_doc_node.sql:71-90` |
| K9 | `workspace_doc_node.tenant_id` and `workspace_doc.tenant_id` reference `tenants`; one root per tenant; a 10,000 doc cap per tenant; depth <= 32. | `0165_workspace_doc_node.sql:41,76,152,243-244` |
| K10 | A second editor of repo docs exists: spec 075 repo-edit, `PUT /v1/docs/{path}` saves an overlay to the docs bucket and a worker pushes it to git. Spec 137 does not name it. | `csi-spl-api/src/go/spool-hub-api/internal/hub/repo_docs_edit.go:22-30`, `internal/repodocs/author.go` |
| K11 | The import refuses to renumber a section others cite; the export already writes the stamp line `> Generated from qto doc <id>; edit it there.` right under the title. | `csi-spl-orc/src/bash/run/spl-doctree-md.py:12-14,112-116` |
| K12 | The map holds 2 rows today (`runbook-dispatcher.md`, `runbook-orchestrator.md`), in a workspace tenant, not a repo one. | `csi-spl-doc/doc/md/qto-docs.tsv` (`wc -l` -> 2) |

## 2. The decisions

### 2.1 P-Q1 unnumbered headings: A, stored as `attrs.numbered = false`

- **Choice**: A, an item flag, kept in the existing `attrs` (K2), so no
  migration. An absent key means numbered: every existing item keeps its
  outline.
- **Why**: one flag covers both the 559 unnumbered files and the 110
  mismatched ones: a heading whose number is not the derived one (`A.`,
  `Appendix 1`, roman, skipped levels) is imported as unnumbered with its
  literal number kept in the title, so the export reproduces it byte for byte.
  B (a stored override string) re-creates the drift the derived outline was
  built to remove (K4). C renumbers sections others cite, which the import
  refuses on purpose (K11).
- **Risk**: in a mixed doc the derived numbers shift unless the derivation
  skips unnumbered siblings: `## Overview` then `## 1. Goals` must keep Goals
  at 1. That makes three places to change together: the outline derivation
  (K4), both exporters (K5), and the WUI view and grid sort on outline.
- **Fit**: `workspace_docs_read.go:112` is the one place the outline is
  made; `doctree_export.go:157` and `-doctree-export.ts:24` are the two that
  print it, and they are already declared a pair ("Change both together",
  `doctree_export.go:9-13`).

### 2.2 P-Q2 repo docs in the one file system: A, one reserved repo workspace

- **Choice**: A, one reserved workspace id for repo docs, with ONE extra
  permissive `FOR SELECT` policy per table (`tenant_id = '<repo id>'`). Writes
  stay under the existing `tenant_scope` and `operator_scope` policies, so a
  workspace session cannot write there (I2) without a new write policy.
- **Why**: the model is per tenant end to end: tenant-scoped RLS, composite
  FKs, one root, nested set and the per-tenant cap (K8, K9). A reserved
  tenant reuses all of it; repo docs get one root and one tree with no copies.
  B multiplies 1,247 docs by every workspace and must re-sync each copy. C
  keeps two stores and two editors, the split the owner asked to end.
- **Risk**: (1) the id needs a `tenants` row (FK, K9), and every place that
  lists tenants must skip it: sweeps, members, billing, workspace pickers.
  (2) Keep the new policy PERMISSIVE: a RESTRICTIVE one turns index scans into
  heap filters (rdb 0169 precedent). (3) All repo-doc writes lock the one repo
  root (`0165_workspace_doc_node.sql:177`), so the bulk import is serial; at
  1,247 docs that is fine, and the cap is 10,000.
- **Fit**: the spec's SQL in section 4.2.2 must use the real GUCs (K8). Most of
  T020 is already built; what is left is the tenant row and the SELECT policy.

### 2.3 P-Q3 table editor: A, pipe-table skeleton into the body

- **Choice**: A now. B (a grid modal) can come later as a helper over the
  same body text, never as a second storage form.
- **Why**: the body is already where tables live: the CLI appends them there
  (K6), the renderer draws them (K7), and both exporters copy the body as is.
  A is a toolbar button next to `Insert picture` and nothing else. C adds an
  item kind the model does not have (K1) and a JSONB-to-Markdown compiler that
  both exporters would have to agree on.
- **Risk**: hand-typed pipes break on `|` inside a cell; the skeleton and
  the round-trip test must include an escaped `\|`. The `strip()` in
  `spl-doctree-md.py:55` must not eat a table that ends a section.
- **Fit**: the toolbar slot is `WorkspaceDocView.vue:162-174`
  (`wsdoc__paratools`, today only `ws-doc-insert-pic`); the CLI twin exists
  (`doctree.go:51`).

### 2.4 P-Q4 blockquotes and citations: A, Markdown blockquote in the body

- **Choice**: A: `> passage` then `> — [Source](url)` in the body; the
  attribution style is CSS at render time only.
- **Why**: attrs hold exactly one code block and one image per item (K1); a
  structured quote in attrs allows one quote per item and needs its own
  placement rule in two exporters. In the body, any number of quotes,
  nested quotes (18 files) and `> [!NOTE]` callouts (15 files) round-trip
  with no new code in either exporter. The renderer already allows the tag (K7).
- **Risk**: finding the attribution line is a convention, not data: a
  quote's last paragraph that starts with `—` is styled as the source. A
  quote without one renders as a plain quote, which is the correct fallback.
- **Fit**: `markdown.mjs:43` has `blockquote`; the button goes into the same
  `wsdoc__paratools` slot as P-Q3.

### 2.5 P-Q5 retirement gate: A, hard, keyed on the map, per mapped file

- **Choice**: A, scoped: a path is gated ONLY once it is in `qto-docs.tsv`.
  A change to a mapped `.md` passes only if the file equals the export of its
  doc. The pre-push gate checks the stamp offline; CI runs the full
  comparison against the hub.
- **Why**: the owner said "retire the md files editing"; C does not retire
  anything. B makes CI a writer to master: bot commits race every lane's
  rebase, and a hand edit that slips through is silently overwritten.
  Gating per mapped file lets retirement follow the import (2 rows today,
  then 1,247) without freezing unmapped docs early.
- **Risk**: the pre-push box may not reach the hub; it then refuses a
  mapped-file diff it cannot verify instead of passing it. The 075 repo-edit
  worker (K10) pushes `.md` to git and will hit this gate: turn it off for
  mapped paths first.
- **Fit**: the stamp line is already in every export
  (`spl-doctree-md.py:114`) and the map already exists (K12), so the gate is
  a lookup plus one export call; no new format.

## 3. Corrections to tasks.md

1. **T020 is mostly built; rescope it and fix the spec SQL.** RLS, FORCE RLS
   and composite tenant FKs are live (K8). T020 becomes: the reserved repo
   `tenants` row, one permissive SELECT policy per table, and skipping that
   tenant in tenant lists. Fix spec section 4.2.2 to `app.tenant_id` /
   `app.rls_scope = 'operator'`.
2. **Missing task, before T040: retire the spec 075 repo-edit path** (K10:
   `PUT /v1/docs/{path}`, the overlay, the repodocs worker) for mapped paths,
   and decide the docs bucket's fate in T022. Without it two editors write
   the same files and the T040 gate refuses the worker's pushes.
3. **Wrong order: T012/T013 need the hub and both exporters first.** Add a
   task ahead of T012: `attrs.numbered` honoured by the outline derivation
   (`workspace_docs_read.go:112`), `doctree_export.go:157`,
   `-doctree-export.ts:24` and the WUI view. Move T032 (test the real
   `spool` binary, not the Python stub) into Phase 1 ahead of T012-T015: they
   all change export output, and the stub cannot catch a regression.
4. **T014 names a column that does not exist.** `workspace_doc` has no
   `attrs` (K3). Keep front matter in the hidden root item's
   `attrs.front_matter` (the preamble already lives in that item's body), so
   no migration is needed; or add the column as an explicit rdb task.
5. **T030 is too big for one lane.** Split it: (a) move the 2 mapped docs
   (K12) into the repo workspace and re-point the map; (b) `csi-spl-doc/doc/`;
   (c) `csi-spl-doc/specs/`; (d) the 99 files outside `csi-spl-doc/` after
   T017. Each part ends with a green T031 on its own slice. Also T002's
   gate names `reviews/`, while the panel writes `panel/<seat>.md`: align it.

## 4. Version log

| version | date | author | change |
|---|---|---|---|
| 1.0 | 2026-10-14 | s137-claude (c-957) | Choices P-Q1..P-Q5 and five tasks.md corrections. |

<!-- version: 1.0 · updated: 2026-10-14 · last-edit: 2026-10-14T00:00:00Z -->
