# 145: Issues, GitSpecs and Qto: Bidirectional Synchronization, First-Class Task Attributes, and Unified Relational Documentation Architecture

Status: **Consensus Specification v0.3.1 (Send-Back Corrections Folded)**. Issue: SPL-2367.
Date: 2026-10-17 · Lane: `a-478-c002-spec-145-issue-spec-qto-sync`.
Proposed Epic: `Spec 145 - Issue, GitSpec and Qto Sync` (to be created by dispatcher `c-002`).
Discussion Topic: `197811a0-f15b-40ef-b6cf-19da0ddc1182` (owner HUM-10, prd t1, msgs 015b6af5, ef77b762, 5863d0d6, e0cf0be3; final poll decisions msg 3ec25b38-b3b4-4e1c-80bf-6453e4afeb09).
Authority: this file for architecture, schema, protocols, sync rules, and data model; `tasks.md` for the concrete, dependency-ordered implementation tasks with gates, red controls, and parallel work groups.
Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [002 box-agent messaging](../002-box-agent-messaging/spec.md) (local spool, CLI + MCP contracts)
- [003 message bus](../003-spool-message-bus/spec.md) (the hub, store, viewer API, RLS)
- [005 WUI](../005-spool-wui/spec.md) (Nuxt 3 web interface, theme variables, layout)
- [039 spool issues](../039-spool-issues/spec.md) (issues store, Linear-like UI, `issues-v1` contract)
- [113 workspace docs Qto](../113-workspace-docs-qto/spec.md) (outline and grid over one tree: `workspace_doc`, `workspace_doc_item`, `workspace_doc_rev_log`, rdb `0157`)
- [114 workspace doc privacy and sharing](../114-workspace-doc-privacy-sharing/spec.md) (private by default, tenant isolation, share grants)
- [120 Qto doc tree](../120-qto-doc-tree/spec.md) (workspace file explorer, nested set `workspace_doc_node`, 10,000 doc cap)
- [135 work process](../135-work-process/spec.md) (issue workflow, lane integration rules)
- [137 Qto doc editor & unified fs](../137-qto-only-doc-editor/spec.md) (Qto as primary doc editor, unified spool-hub fs, CommonMark/GFM gap inventory)
- [142 binaries management](../142-binaries-management/spec.md) (empirical ground-truth inventory and house style)
- [143 reporting section](../143-reporting-section/spec.md) (forward-only SQL migrations, schema extensions)
- [144 dedicated agents](../144-dedicated-agents/spec.md) (scope isolation and house style)

---

## 0. The owner's directives (verbatim, binding)

Recorded 2026-10-17 in prd workspace `t1`:

### 0.1 Bidirectional export/import and Qto as primary store & index
Owner HUM-10, topic `7a98c2d1-0f72-4b2e-a579-373673f4439c`, message `015b6af5-55a2-4150-990c-b9afcb79d27c`, verbatim:

> "we need to have automated export/import from our issue into GitSpec, from a whole epic to GitSpec, from GitSpec to our issue format, and some kind of QTO equivalence as well. Actually, isn't it the case that the whole GitSpec could also be imported to the QTO, and that the QTO could be the primary storage and primary index for the MD documentation?"

In the same topic (messages `ef77b762` and `5863d0d6`):
> "no issue without an epic and a git spec."

### 0.2 First-class issue attribute linking to GitSpec task
Owner HUM-10, topic `197811a0-f15b-40ef-b6cf-19da0ddc1182`, message `e0cf0be3`, 12:24Z 2026-10-17, verbatim:

> "Actually, for each issue, there should be an issue attribute which links to the gitspec file, which is the gitspec which contains the task. In my understanding, an issue is already defined as a task to be done in the gitspec."

### 0.3 Core architectural axioms derived from the owner's decisions

1. **Axiom 1: An Issue IS a Task of a GitSpec (Strict Isomorphism).**  
   An issue is not an untethered, ephemeral ticket. Every work issue in the system is the live, execution-tracked instance of a specific task item defined within a GitSpec (e.g. `csi-spl-doc/specs/145-issue-spec-qto-sync/tasks.md#T001`). Enforced strictly at filing: must point to a real spec file and an existing task ID (Owner Decision 2: Option A).
2. **Axiom 2: An Epic IS a Feature Specification.**  
   An epic corresponds 1:1 to a GitSpec feature directory (e.g. `csi-spl-doc/specs/145-issue-spec-qto-sync/`), anchoring the overall specification (`spec.md`), child tasks (`tasks.md`), contracts, and research.
3. **Axiom 3: First-Class Structural Integrity (No Free-Text Hacks).**  
   The linkage between an issue and its GitSpec task must never be buried in free-text Markdown descriptions (such as `- spec: ...` in restart cards). It must exist as first-class, indexed, schema-enforced attributes in the database, API wire models, and WUI.
4. **Axiom 4: Unified Synchronization Pipeline without Loss.**  
   State, status, assignees, titles, descriptions, and test criteria flow seamlessly from the primary Qto store and issues table to generated read-only Git exports.
5. **Axiom 5: Qto as Sole Primary Storage & Primary Index; Git Files as Read-Only Exports (Owner Decision 1: Option B).**  
   Qto is the sole primary storage and primary index for all specifications, task grids, and documentation. Markdown files in Git (`spec.md`, `tasks.md`) are strictly read-only generated export artifacts. Agents and humans author and update specs exclusively through Qto doctree actions and the WUI.
6. **Axiom 6: Instant Export Commit Cadence with Isolated Doc Paths (Owner Decision 3: Option B).**  
   Every Qto edit triggers an immediate automated commit and push to master. Fleet rebase churn is kept low through dedicated doc export paths (`csi-spl-doc/specs/`) that implementation lanes never touch during code builds.
7. **Axiom 7: Shared Area Specs for Quick Fixes (Owner Decision 4: Option A).**  
   Small bug fixes, operational tasks, and ad-hoc changes that do not warrant a bespoke multi-page feature spec are filed under shared, categorized Area Specs (e.g. `000-quick-fixes`, `000-operations`), preserving 100% adherence to strict validation without process overhead.

---

## 1. Today's reality measured on code (the fragmentation gap)

Every assertion in this section was verified directly against the live code on origin/master at commit `799074586` on 2026-10-17.

### 1.1 The issue schema & filing gap

- **Schema inspection (`csi-spl-rdb/src/sql/postgres/spool-hub/0047_issues.sql`, `0053_issue_kinds.sql`)**:  
  The `issues` table defines columns: `tenant_id`, `number`, `title`, `description`, `status`, `priority`, `level`, `assignee`, `labels`, `deadline`, `parent_number`, `kind` (`epic | feature | issue`), `task_id`, `created_by`, `created_at`, `updated_by`, `updated_at`, `completed_at`, `canceled_at`.  
  **Finding:** There are **zero columns** for storing a GitSpec file path, a task identifier, or a specification reference.
- **Filing inspection (`csi-spl-orc/src/bash/run/spl-lane-issue.func.sh:398-408`)**:  
  ```bash
  spl_lane_issue_card() {
    local spec="" avoid="" scope="the topic"
    if [[ -r "$3" ]]; then
      scope="the brief of lane $id"
      spec="$(grep -m1 -oE 'csi-spl-doc/specs/[0-9]{3}-[a-z0-9-]+(/spec\.md)?' "$3")"
      avoid="$(grep -m1 -iE 'not touch' "$3" | sed -E 's/^[-* ]+//' | cut -c1-200)"
    fi
    printf '## Source
%s

## Restart
' "$([[ -n "$2" ]] && echo "/t/$2" || echo none)"
    printf -- '- key: %s
- spec: %s
- scope: %s
- must not touch: %s
' "$1" "${spec:-none}" "$scope" "${avoid:-see the brief}"
    ...
  }
  ```
  **Finding:** The spec link is formatted as a fragile string in Markdown text (`- spec: none` or `- spec: csi-spl-doc/specs/NNN-slug/spec.md`). It cannot be queried via SQL, has no foreign-key or regex constraint, cannot be indexed, cannot store a task ID (e.g. `T012`), and is easily corrupted or deleted by manual description edits.
- **API wire inspection (`csi-spl-api/src/go/spool-hub-api/internal/hub/issues.go:43-72`)**:  
  The Go struct `issueJSON` serializes fields to the WUI and CLI.  
  **Finding:** `issueJSON` contains no `spec_path`, `spec_task_id`, or `spec_ref` fields.

### 1.2 The one-way import & reconcile reality

- **Spec import (`csi-spl-orc/src/bash/run/spl-spec-import-issues.func.sh` & `spec-import-issues.py`)**:  
  `do_spl_spec_import_issues` parses `csi-spl-doc/specs/NNN-*/tasks.md` and generates issues whose titles match `[NNN <id>] <title>`.  
  **Finding:** It is strictly **one-way (file -> database)**. It relies on string prefix pattern matching in the title rather than an explicit database key. If a human edits the issue title in the WUI, synchronization breaks.
- **Spec reconcile (`csi-spl-orc/src/bash/run/spl-spec-tasks-reconcile.func.sh`)**:  
  Scans `origin/master` for `[x]` checkboxes in `tasks.md` and marks corresponding issues `done`.  
  **Finding:** It is strictly **one-way and close-only**. If an issue status moves to `wip`, `blocked`, `onhold`, or `diss` in the hub, or if an issue is reassigned, `tasks.md` is **never updated**. There is zero export path from Issues back to `tasks.md`.
- **Epic backfill (`csi-spl-orc/src/bash/run/spl-issue-epic-backfill.func.sh`, commit `9eb152fa9`)**:  
  Recently created because hundreds of legacy issues existed as orphans without epics. It attempts to infer epics by regex-scraping spec directory names from the description card.

### 1.3 The Qto & Markdown documentation reality

- **Repository Markdown scale (measured 2026-10-17)**:  
  - Total Markdown files in repo: **1,257** (`git ls-files '*.md' | wc -l`).  
  - Total specs under `csi-spl-doc/specs/`: **141** directories (`001` through `144`).  
  - Specs with `spec.md`: **138**.  
  - Specs with `tasks.md`: **99**.  
- **Qto import limitations (measured in Spec 137 §1.3)**:  
  `do_spl_doctree_import_md` (`csi-spl-orc/src/bash/run/spl-doctree-import-md.func.sh`) currently fails on **69.7% of repository Markdown files** (869 files fail). Failure causes: unnumbered headings, setext headings, tables, outline skips.  
  **Finding:** Qto today treats imported Markdown as a flat sequence of heading nodes (`workspace_doc_item`) and folder/doc hierarchy (`workspace_doc_node`). It has **zero awareness of GitSpec task tables, zero awareness of issue attributes, and zero link to the issue tracker**.

### 1.4 The c-368 guard requirement

- Running on satellite box (`c-368-c002-issue-epic-spec-required`): enforcing the owner's mandate that no issue may be filed without an epic and a git spec.  
  **Finding:** Because the database has no `spec_path` column, `c-368` is forced to grep description text for `csi-spl-doc/specs/`. Without a first-class schema attribute, this gate remains brittle and prone to false positives/negatives.

---

## 2. First-class GitSpec issue attribute in the Hub schema, API, and WUI

To satisfy Owner Directives §0.2 and §0.3, the spec path and task ID become first-class citizen attributes of every issue in the spool-hub architecture.

### 2.1 Database schema migration (forward-only SQL in `csi-spl-rdb`)

A new migration `csi-spl-rdb/src/sql/postgres/spool-hub/<prefix>_issue_spec_attributes.sql` (taking the next free rdb prefix on origin/master at the lane's push, re-checked on the final rebase) adds first-class columns and validation constraints to the `issues` table:

```sql
-- <prefix>_issue_spec_attributes.sql: First-class GitSpec task linkage on issues (SPL-2367)
SET LOCAL lock_timeout = '5s';

-- 1. Add spec_path: relative path to the spec or task file
ALTER TABLE issues ADD COLUMN IF NOT EXISTS spec_path text NOT NULL DEFAULT ''
    CHECK (length(spec_path) <= 255 AND (
        spec_path = '' OR 
        spec_path ~ '^csi-spl-doc/specs/[0-9]{3}-[a-z0-9_-]+/(spec\.md|tasks\.md|[a-z0-9_.-]+\.md)$'
    ));

-- 2. Add spec_task_id: task row identifier within tasks.md (e.g. T001, B4, S12)
ALTER TABLE issues ADD COLUMN IF NOT EXISTS spec_task_id text NOT NULL DEFAULT ''
    CHECK (length(spec_task_id) <= 32 AND (
        spec_task_id = '' OR 
        spec_task_id ~ '^[A-Za-z0-9_.-]+$'
    ));

-- 3. Composite index for ultra-fast reverse lookup from GitSpec task to Issue
CREATE INDEX IF NOT EXISTS issues_spec_task_idx 
    ON issues (tenant_id, spec_path, spec_task_id) 
    WHERE spec_path <> '';
```

#### Field semantics & schema types

| Column | Type | Nullable | Default | Description & Format |
|---|---|---|---|---|
| `spec_path` | `text` | `NOT NULL` | `''` | Relative repo path of the specification or task document: `csi-spl-doc/specs/<NNN>-<slug>/<file>.md`. |
| `spec_task_id` | `text` | `NOT NULL` | `''` | Stable task row identifier within the spec's `tasks.md` (e.g. `T001`, `B4`, `T012.s1`). Empty string for Level 1 Epics that anchor the whole spec. |
| `spec_ref` *(Virtual / API)* | `string` | — | — | Computed URI fragment representation: `<spec_path>#<spec_task_id>` (e.g. `csi-spl-doc/specs/145-issue-spec-qto-sync/tasks.md#T001`). If `spec_task_id` is empty, equals `spec_path`. |

### 2.2 Hub API wire protocol & strict validation (Owner Decision 2: Option A)

The Go Hub API (`csi-spl-api/src/go/spool-hub-api/internal/hub/`) and wire contracts (`csi-spl-doc/specs/039-spool-issues/contracts/issues-v1.md`) enforce **Strict Validation at Issue Creation & Mutation**:

1. **Strict Filing Validation Rules:**
   - **File Existence**: `spec_path` must point to an actual specification file existing in repository master or Qto document tree.
   - **Task ID Existence**: For Level-2 issues (`kind = 'issue'`), `spec_task_id` must match an existing task row identifier in that spec's task grid / `tasks.md`.
   - **Rejection**: If either condition is not met, `POST /v1/issues` or `PATCH /v1/issues/{ref}` returns HTTP 400 Bad Request (`{"error": "bad_issue", "reason": "spec_task_not_found"}`).
2. **`issueJSON` struct (`internal/hub/issues.go`)**:
   ```go
   type issueJSON struct {
       Key         string   `json:"key"`
       Number      int      `json:"number"`
       Title       string   `json:"title"`
       Description string   `json:"description"`
       Status      string   `json:"status"`
       Priority    int      `json:"priority"`
       Level       int      `json:"level"`
       Assignee    string   `json:"assignee"`
       Labels      []string `json:"labels"`
       Deadline    string   `json:"deadline"`
       Parent      string   `json:"parent"`
       Kind        string   `json:"kind"`
       Epic        string   `json:"epic"`
       SpecPath    string   `json:"spec_path"`    // First-class GitSpec file path
       SpecTaskID  string   `json:"spec_task_id"` // First-class task ID in tasks.md
       SpecRef     string   `json:"spec_ref"`     // Computed <spec_path>#<spec_task_id>
       TaskID      string   `json:"task_id"`
       Channel     string   `json:"channel"`
       CreatedBy   string   `json:"created_by"`
       CreatedAt   string   `json:"created_at"`
       UpdatedBy   string   `json:"updated_by"`
       UpdatedAt   string   `json:"updated_at"`
       CompletedAt string   `json:"completed_at"`
       CanceledAt  string   `json:"canceled_at"`
       Unopened    *bool    `json:"unopened,omitempty"`
       Discussions []issueDiscussionJSON `json:"discussions,omitempty"`
   }
   ```
3. **CLI endpoints (`spool issue`)**:
   - `spool issue create --title "<title>" --spec-path "<path>" --spec-task "<id>"`
   - `spool issue update --ref "<ref>" --spec-path "<path>" --spec-task "<id>"`
   - `spool issue list --spec-path "<path>"`: filters issues belonging to a specific spec.

### 2.3 Lane issue filing integration (`do_spl_lane_issue`)

The lane placement script (`csi-spl-orc/src/bash/run/spl-lane-issue.func.sh`) is updated:
1. `spl_lane_issue_place`:
   - Inspects `brief.md` for explicit metadata lines:
     `Spec: csi-spl-doc/specs/NNN-slug/tasks.md#T001` or `Spec: csi-spl-doc/specs/NNN-slug/spec.md`.
   - Parses the spec path and task identifier into `SLI_SPEC_PATH` and `SLI_SPEC_TASK_ID`.
   - Passes `--spec-path "$SLI_SPEC_PATH"` and `--spec-task "$SLI_SPEC_TASK_ID"` directly to `spool issue create` / `update`.
2. The legacy restart card generation (`spl_lane_issue_card`) is simplified:
   - `- spec: none` is **completely eliminated**.
   - The card references the first-class attribute: `- spec: [derived from issue.spec_ref]`.

### 2.4 Historical backfill action (`do_spl_issue_spec_backfill`)

A dedicated orchestrator action, `do_spl_issue_spec_backfill` (`csi-spl-orc/src/bash/run/spl-issue-spec-backfill.func.sh` and helper Python engine `issue-spec-backfill.py`), performs an idempotent backfill:
1. Queries all issues where `spec_path = ''`.
2. Scans the issue's description card for `- spec: (csi-spl-doc/specs/[^ 

	]+)`.
3. If a spec path is found:
   - Validates existence on `origin/master`.
   - Checks the issue title for task prefixes like `[NNN T001]` or `[NNN B4]` or task descriptions matching rows in `tasks.md`.
   - Updates `spec_path` and `spec_task_id` via `spool issue update`.
4. If no spec is named in the card, links to the parent Epic's `spec_path`, or to the Shared Area Spec (`000-quick-fixes`).
5. Supports `DRY_RUN=1` (reports plan without mutating database) and `DRY_RUN=0` (applies in rate-limited batches with undo journal).

### 2.5 WUI representation & user interaction (`csi-spl-wui`)

1. **Badge component (`csi-spl-wui/src/components/IssueSpecBadge.vue`)**:
   - Renders a compact, styled badge displaying `spec: 145/T001` or `spec: 145`.
   - Clicking the badge opens a preview modal or deep-links directly to `/docs/specs/145-issue-spec-qto-sync/#T001` in the Docs section, or to `/qto/<doc_id>#<item_id>` in the Qto workspace editor.
2. **Issue sheet table view (`csi-spl-wui/src/pages/issues.vue`)**:
   - Adds a configurable `spec` column to the table header and rows, managed via `issue-columns-pref.mjs`.
   - Displays the task ID and spec slug with hover tooltip showing the task title and gate.
3. **Issue detail dialog (`IssueDetailFrame.vue` & `issues.vue`)**:
   - Displays a dedicated "GitSpec Task" field alongside Status, Priority, Assignee, and Discussions.
   - For authorized users, provides a dropdown/typeahead picker to link or change the GitSpec file and select a verified task row from `tasks.md`.

### 2.6 Enforcement gate (c-368 guard integration)

The `c-368` guard (`c-368-c002-issue-epic-spec-required`) and the pre-push check `do_check_pre_push` are equipped with strict database checks:
- **Rule 1 (Epic requirement)**: Every level-2 issue (`kind = 'issue'`) must have `parent_number IS NOT NULL` referencing an active Epic (`kind = 'epic'`).
- **Rule 2 (Spec requirement)**: Every level-2 issue must have a non-empty `spec_path` that resolves to a valid `tasks.md` file in the repository / Qto doc tree.
- **Rule 3 (Epic spec requirement)**: Every level-1 Epic must have a non-empty `spec_path` resolving to a valid `spec.md` file.
- **Rule 4 (Task ID validity)**: If `spec_path` points to a `tasks.md`, `spec_task_id` must match a real task ID in that file's table (Owner Decision 2: Option A).

---

## 3. Four-direction architecture under Qto-Primary storage

Under Owner Decision 1 (Option B) and Decision 3 (Option B), Qto is the sole primary source of truth. All authoring, task updates, and status transitions occur in Qto and the Hub database. Git `.md` files are strictly generated read-only export artifacts, updated immediately upon every change with zero fleet rebase churn.

```
       +-------------------------------------------------------+
       |               PRIMARY STORE & INDEX: QTO              |
       |  (workspace_doc, workspace_doc_item, workspace_doc_node)|
       +---------------------------+---------------------------+
               |                   |                   |
               | (Live DB Join)    | (Instant Commit)  | (Instant Commit)
               v                   v                   v
+-----------------------------+    |    +-----------------------------+
|           Issues            |    +--> |     READ-ONLY GIT EXPORTS   |
| (issues, issue_discussions) |         |     (spec.md, tasks.md)     |
|   in PostgreSQL Hub Store   |         |      on origin/master       |
+-----------------------------+         +-----------------------------+
```

### 3.1 Direction 1: Qto & Issues -> Instant Commit GitSpec Export (Owner Decision 3: Option B)

**Trigger**: An issue changes in the Hub (status updated, assignee changed, title/scope edited, test criteria modified, or issue closed), or a task grid row is edited in Qto.  
**Tool**: `do_spl_qto_instant_commit_export` (`csi-spl-orc/src/bash/run/spl-qto-instant-commit-export.func.sh`, upgrading `do_spl_doctree_export_md`).  
**Mechanism**:
1. Reads the authoritative Qto document (`workspace_doc`) and its task grid items (`workspace_doc_item`).
2. Joins the live `issues` table records via `spec_sync_map` to obtain real-time status and assignee metadata.
3. Formats the export file with the mandatory generated header:
   `> Generated from qto doc <doc_id>; edit it there. This file is its export: cd csi-spl-orc && ./run -a do_spl_doctree_export_md rewrites it.`
4. Serializes the task grid into a clean CommonMark GFM pipe table in `tasks.md`.
5. Emits the export and commits immediately to `origin/master` as one atomic commit per change. Direct hand edits to `tasks.md` in git checkouts are prohibited and refused by pre-push hygiene.

#### Minimizing fleet rebase churn under instant commit
Because commits occur on every single Qto change, fleet rebase churn is controlled and eliminated through four architectural safeguards:
1. **Dedicated Doc Paths**: All exported documentation files live strictly under `csi-spl-doc/specs/`. Lane briefs and worktree policies enforce that implementation lanes touch only code trees (`src/`, `rdb/`, `iac/`) and *never* write to `csi-spl-doc/`.
2. **Git Tree-Level Non-Overlapping Merges**: When agent lanes run `git rebase origin/master`, git performs a trivial tree merge. Because code files and docs files reside in disjoint directory trees, rebasing across doc export commits produces exactly **zero merge conflicts**.
3. **Dedicated Push Bot with Fast-Path**: The automated export runner (`spl-qto-export-bot`) commits directly using the repository committer identity and pushes using atomic lease-free git pushes.
4. **Clean Worktree Fetching**: Because agents never stage local modifications in `csi-spl-doc/specs/`, `git pull --rebase` or `git fetch` in agent lanes always succeeds cleanly without dirty-tree aborts.

### 3.2 Direction 2: Epic -> Qto Spec -> GitSpec Export

**Trigger**: An Epic is created in the Hub or WUI (`spool issue create --kind epic`).  
**Tool**: `do_spl_epic_qto_create` (`csi-spl-orc/src/bash/run/spl-epic-qto-create.func.sh`).  
**Mechanism**:
1. Creates a new `workspace_doc` in Qto titled `Spec NNN - <Epic Title>`.
2. Generates the standard outline structure in `workspace_doc_item` nodes (Overview, Requirements, Architecture).
3. Creates a child Task Grid item linked to the Epic's child issues.
4. Registers the mapping in `spec_sync_map` and `csi-spl-doc/doc/md/qto-docs.tsv`.
5. Exports the generated read-only `spec.md` and `tasks.md` files under `csi-spl-doc/specs/NNN-<slug>/` and commits them.

### 3.3 Direction 3: Legacy GitSpec -> Qto One-Time Migration

**Trigger**: Migration of pre-existing Markdown specifications into the primary Qto store.  
**Tool**: `do_spl_spec_import_qto` (`csi-spl-orc/src/bash/run/spl-spec-import-qto.func.sh`).  
**Mechanism**:
1. Scans existing `csi-spl-doc/specs/NNN-*/` directories.
2. Imports `spec.md` sections into Qto `workspace_doc_item` hierarchy.
3. Converts `tasks.md` tables into Qto Task Grid items with structured attributes (`attrs.spec_task_id`, `attrs.issue_key`).
4. Creates corresponding Level 1 Epic and Level 2 Issue records in PostgreSQL if not already present.
5. Rewrites the git files in place with the standard read-only generation stamp, transferring authority entirely to Qto.

### 3.4 Direction 4: Qto Action Tooling for Agents

**Trigger**: An agent working in a lane needs to update a task status, add a subtask, or modify a specification.  
**Tool**: `do_spl_qto_task_update` (`csi-spl-orc/src/bash/run/spl-qto-task-update.func.sh`).  
**Mechanism**:
1. Because local `.md` files are read-only exports, agents do NOT edit `spec.md` or `tasks.md` via text editors or shell commands in their worktrees.
2. Agents invoke named Qto CLI actions:
   `QTO_DOC=<id> TASK_ID=T001 STATUS=done ./run -a do_spl_qto_task_update`
3. The action mutates the Qto item and linked Hub issue in PostgreSQL under the agent's identity.
4. The instant-commit export engine immediately pushes the updated `tasks.md` export.

---

## 4. Primary storage and index architecture: the Qto-Only decision

Owner HUM-10 resolved the architectural choice in prd workspace `t1`, topic `197811a0`, message `3ec25b38-b3b4-4e1c-80bf-6453e4afeb09` (2026-10-17): **Option B (Qto only: the Git files become read-only exports)**.

### 4.1 Architectural implications of Decision B

1. **Qto is the Sole Primary Store and Primary Index:**
   - PostgreSQL (`workspace_doc`, `workspace_doc_item`, `workspace_doc_node`) is the single authoritative source of truth for all specification text, diagrams, task lists, and metadata.
   - The Omnibox search and WUI query Qto tables directly with sub-millisecond full-text indexing.
   - Live multi-user collaboration in the WUI operates directly on Qto without intermediate git staging.
2. **Git Files are Strictly Read-Only Generated Exports:**
   - All `.md` files under `csi-spl-doc/specs/` are generated export artifacts (analogous to build outputs).
   - Each file carries the immutable generation banner:
     `> Generated from qto doc <uuid>; edit it there. This file is its export: cd csi-spl-orc && ./run -a do_spl_doctree_export_md rewrites it.`
   - No human or agent edits these files by hand in git worktrees. Any manual edit made to a generated `.md` file is refused by the pre-push gate `do_check_dist_hygiene` and overwritten on next export.
3. **Agent Workflow Transition:**
   - Agents read local `.md` files in their worktrees for read-only context (e.g. reading task requirements or testing gates).
   - To update task statuses, gates, or specification prose, agents call named orchestrator actions (`do_spl_qto_task_update`, `do_spl_desk_doctree`) that write directly to the Qto Hub database.
   - Automated instant-commit hooks rewrite and commit the exported `.md` files.

---

## 5. Round-trip fidelity, surviving identifiers, and conflict resolution

### 5.1 Immutable surviving identifiers

Every entity across the layers maintains an immutable, persistent identifier:

| Entity | Primary Key / Identifier | Scope & Stability | Cross-System Reference |
|---|---|---|---|
| **Issue** | Key (`SPL-2367`) & `(tenant_id, number)` | Permanent, immutable once minted by Hub | Stored in `tasks.md` row; stored in Qto item `attrs.issue_key`. |
| **Epic** | Key (`SPL-2350`) & `(tenant_id, number)` | Permanent, immutable | Stored in `spec.md` header; stored in Qto doc `attrs.epic_key`. |
| **GitSpec Feature** | Directory Path `csi-spl-doc/specs/NNN-<slug>/` | Stable across git branches and checkouts | Stored in `issues.spec_path`; stored in Qto doc `attrs.spec_path`. |
| **GitSpec Task** | String ID (`T001`, `B4`, `T012.s1`) | Stable within `tasks.md` | Stored in `issues.spec_task_id`; stored in Qto item `attrs.spec_task_id`. |
| **Qto Document** | UUID `workspace_doc.id` | Permanent per tenant | Stored in `csi-spl-doc/doc/md/qto-docs.tsv` and `spec_sync_map`. |
| **Qto Task Item** | UUID `workspace_doc_item.id` | Permanent per doc revision | Stored in `spec_sync_map.item_id`. |

### 5.2 The cross-system synchronization ledger (`spec_sync_map`)

To track revisions, hashes, and parity without polluting git files with UUIDs, a lightweight ledger table is added in the migration (ordered with or combined in the `spec-schema` lane, taking the next free rdb prefix on origin/master at push time):

```sql
CREATE TABLE IF NOT EXISTS spec_sync_map (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    spec_path     text        NOT NULL,
    spec_task_id  text        NOT NULL DEFAULT '',
    issue_number  integer     NULL,
    qto_doc_id    uuid        NULL,
    qto_item_id   uuid        NULL,
    last_git_sha  text        NOT NULL DEFAULT '',
    last_sync_at  timestamptz NOT NULL DEFAULT now(),
    sync_status   text        NOT NULL DEFAULT 'in_sync' 
                  CHECK (sync_status IN ('in_sync', 'pending_export', 'pending_import', 'conflict')),
    PRIMARY KEY (tenant_id, spec_path, spec_task_id),
    FOREIGN KEY (tenant_id, issue_number) REFERENCES issues (tenant_id, number) ON DELETE SET NULL,
    FOREIGN KEY (tenant_id, qto_doc_id) REFERENCES workspace_doc (tenant_id, id) ON DELETE SET NULL
);
```

### 5.3 Conflict elimination under Qto-Primary architecture

Under Owner Decision 1 (Option B), bidirectional file merge conflicts are **entirely eliminated**:

1. **Zero Git Merge Conflicts for Documentation:**  
   Because git `.md` files are strictly read-only generated exports, concurrent branches and worktrees never attempt to merge conflicting Markdown edits on trunk. Trunk receives atomic, generated exports from Qto.
2. **Qto Revision Log Authority:**  
   All concurrent editing conflicts between multiple human users or agents are resolved within Qto using the revision ledger (`workspace_doc_rev_log`) and PostgreSQL row-level locks.
3. **Code Landing Status Progression:**  
   When code lands on master citing an issue key (e.g. `feat(..., SPL-2367)`), the automated closer (`do_spl_issue_close_landed`) updates the issue in PostgreSQL to `done`. The live database trigger automatically marks the corresponding Qto task grid item as `done` and triggers an instant re-export and commit.

### 5.4 Shared Area Specs for Quick Fixes and Operations (Owner Decision 4: Option A)

To satisfy the strict validation requirement (Axiom 1 & Owner Decision 2: Option A) without introducing unnecessary friction for ad-hoc bugs or routine operations, shared **Area Specs** are established:
- `csi-spl-doc/specs/000-quick-fixes/tasks.md` (Anchored by level-1 epic `Spec 000 - Quick fixes`, the title form `do_spl_issue_epic_backfill` and the `c-368` guard map by)
- `csi-spl-doc/specs/000-operations/tasks.md` (Anchored by level-1 epic `Spec 000 - Operations`)
- `csi-spl-doc/specs/000-infrastructure/tasks.md` (Anchored by level-1 epic `Spec 000 - Infrastructure`)

When a developer or agent files an issue for a minor bug fix:
1. An issue is filed with `spec_path = 'csi-spl-doc/specs/000-quick-fixes/tasks.md'` and a generated task ID (e.g. `QF-2384`).
2. The task is appended to the Qto task grid under the 000-quick-fixes document.
3. The `c-368` guard verifies the real spec file and task ID against the mapped level-1 area epic, passing cleanly.
4. No bypass label (`no-spec`) is needed, preserving 100% architectural consistency across all repository work.

---

## 6. Acceptance criteria and concrete red controls

Every capability in this specification is guarded by strict acceptance criteria and corresponding red controls (planted failure tests).

| ID | Capability & Acceptance Criterion | Verification Command / Gate | Red Control (Planted Defect & Expected Failure) |
|---|---|---|---|
| **AC-1** | **Issue Spec Schema Migration**: `issues` table accepts `spec_path` and `spec_task_id` with regex validation. | `psql -c "INSERT INTO issues (..., spec_path, spec_task_id) VALUES (..., 'csi-spl-doc/specs/145-issue-spec-qto-sync/tasks.md', 'T001')"` succeeds. | Planted insert with `spec_path = 'invalid/path/file.txt'` must fail with check constraint violation. |
| **AC-2** | **Hub API Wire & Strict Validation**: `POST /v1/issues` accepts spec attributes and strictly rejects non-existent spec files or missing task IDs. | Go test `internal/hub/issues_spec_test.go` verifies validation and serialization. | Filing an issue with non-existent task ID `T999` returns HTTP 400 `spec_task_not_found`. |
| **AC-3** | **Lane Issue Filing Integration**: `do_spl_lane_issue` extracts spec path and task ID from brief and sets issue attributes. | `AGENT_ID=a-478 BRIEF=... DRY_RUN=1 ./run -a do_spl_lane_issue` outputs plan with `--spec-path` and `--spec-task`. | Omitting spec attributes from `spool issue create` invocation causes filing test assertion failure. |
| **AC-4** | **c-368 Guard Strict Enforcement**: A level-2 issue without an Epic parent AND a valid GitSpec path + task ID is refused. | `c-368` guard script verifies compliance across all live issues. | Creating an issue with `spec_path = ''` or unverified task ID causes `c-368` gate to exit with status 1. |
| **AC-5** | **Historical Backfill Accuracy**: `do_spl_issue_spec_backfill` populates empty spec attributes from description cards. | Run `do_spl_issue_spec_backfill DRY_RUN=1` against test dataset; verifies 100% of parsable cards resolve. | Planted corrupt card with missing spec path correctly logs warning and marks unresolved without crashing. |
| **AC-6** | **Instant Commit per Qto Change with Isolated Doc Paths**: Every Qto edit produces an instant git commit to master without lane rebase churn. | `do_spl_qto_instant_commit_export` produces commit on master; lane rebasing code branch has zero conflicts. | Simulating code lane modification to `csi-spl-doc/` triggers hygiene failure. |
| **AC-7** | **Read-Only Git Export Generation & Immutability**: `do_spl_doctree_export_md` exports Qto specs into `.md` files with generation banner; hand edits in worktrees are rejected. | `./run -a do_spl_doctree_export_md` produces clean export carrying `> Generated from qto doc...`. | Pre-push gate `do_check_dist_hygiene` flags any manual edit to generated spec export file. |
| **AC-8** | **Shared Area Specs for Quick Fixes**: Issues filed for minor fixes successfully validate against `000-quick-fixes` area spec. | `spool issue create --spec-path csi-spl-doc/specs/000-quick-fixes/tasks.md --spec-task QF-1` passes strict gate. | Attempting to file quick-fix with arbitrary unregistered task ID fails AC-2 validation. |

---

## 7. Owner decision records (verbatim, topic 197811a0)

The four structured decision forms were resolved by Owner HUM-10 in discussion topic `197811a0-f15b-40ef-b6cf-19da0ddc1182`, recorded in message `3ec25b38-b3b4-4e1c-80bf-6453e4afeb09` (2026-10-17).

### Form 1: Primary storage and index architecture
- **Owner Selection**: **Option B — Qto only: the Git files become read-only exports (agents cannot edit specs next to their code)**.
- **Architectural Directive**: Qto is the sole primary authoring store and search index. Markdown files in Git checkouts are generated read-only export artifacts. Agents author specs and update tasks through Qto doctree actions.

### Form 2: GitSpec attribute strictness and validation
- **Owner Selection**: **Option A — Strict: a real spec file and a task id that exists in it, checked when the issue is filed**.
- **Architectural Directive**: The Hub API and lane filing tools strictly validate that the spec file exists in repository / Qto and that the task ID exists in that spec's task grid at the time of issue creation. Phantom or untethered issues are refused.

### Form 3: Automated Git commit cadence for Qto edits
- **Owner Selection**: **Option B — At once, one commit per change**.
- **Architectural Directive**: The export engine commits to `origin/master` immediately upon every Qto edit. Fleet rebase churn is kept low by isolating all exports to dedicated paths (`csi-spl-doc/specs/`) that implementation lanes never touch during code builds, guaranteeing conflict-free git tree rebases.

### Form 4: Handling legacy and ad-hoc issues without specs
- **Owner Selection**: **Option A — Shared area spec for quick fixes**.
- **Architectural Directive**: Maintain absolute architectural purity ("no issue without an epic and a git spec") without exemption bypasses (`no-spec`). Quick fixes, operational patches, and infrastructure adjustments are filed against categorized Area Specs (`000-quick-fixes`, `000-operations`).
- **The one exception (SPL-4443)**: an issue the owner orders directly for work in a workspace with no repo, which can never have a csi-spl spec, is filed with `ISSUE_OWNER_GO=<the owner's message uuid>` (`do_spl_issue_create`): it needs no git spec but keeps its epic, it is refused in `t1` (csi-spl's own workspace, where Form 4 holds unchanged), the message must be a HUM-<n>'s in a linked discussion of that workspace, and the description's first line is `Owner order: <uuid>`.

---

<!-- version: 0.3.1 · updated: 2026-10-17 · owner-decisions-folded: 3ec25b38 · send-back-folded: 4a154c24 -->
