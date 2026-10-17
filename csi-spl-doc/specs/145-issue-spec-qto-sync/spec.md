# 145: Issues, GitSpecs and Qto: Bidirectional Synchronization, First-Class Task Attributes, and Unified Relational Documentation Architecture

Status: **Consensus Draft v0.1 (Spec Only)**. Issue: SPL-2367.
Date: 2026-10-17 · Lane: `a-478-c002-spec-145-issue-spec-qto-sync`.
Proposed Epic: `Spec 145 - Issue, GitSpec and Qto Sync` (to be created by dispatcher `c-002`).
Discussion Topic: `197811a0-f15b-40ef-b6cf-19da0ddc1182` (owner HUM-10, prd t1, msgs 015b6af5, ef77b762, 5863d0d6, e0cf0be3).
Authority: this file for architecture, schema, protocols, sync rules, and data model; `tasks.md` for the concrete, dependency-ordered implementation tasks with gates and red controls.
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

### 0.3 Core architectural axioms derived from the owner's words

1. **Axiom 1: An Issue IS a Task of a GitSpec.**  
   An issue is not an untethered, ephemeral ticket. Every work issue in the system is the live, execution-tracked instance of a specific task item defined within a GitSpec (e.g. `csi-spl-doc/specs/145-issue-spec-qto-sync/tasks.md#T001`).
2. **Axiom 2: An Epic IS a Feature Specification.**  
   An epic corresponds 1:1 to a GitSpec feature directory (e.g. `csi-spl-doc/specs/145-issue-spec-qto-sync/`), anchoring the overall specification (`spec.md`), child tasks (`tasks.md`), contracts, and research.
3. **Axiom 3: First-Class Structural Integrity (No Free-Text Hacks).**  
   The linkage between an issue and its GitSpec task must never be buried in free-text Markdown descriptions (such as `- spec: ...` in restart cards). It must exist as first-class, indexed, schema-enforced attributes in the database, API wire models, and WUI.
4. **Axiom 4: Omnidirectional Round-Trip Synchronization without Loss.**  
   State, status, assignees, titles, descriptions, and test criteria must flow seamlessly across all four directions:
   - Direction 1: Issue -> GitSpec
   - Direction 2: Epic -> GitSpec
   - Direction 3: GitSpec -> Issues
   - Direction 4: GitSpec <-> Qto (and Issue <-> Qto)
5. **Axiom 5: Qto as Primary Storage & Relational Index; Git as Authoritative Versioned Distribution.**  
   Answering the owner's pivotal question: Qto serves as the high-speed, relational, interactive store and global index for rich-text authoring and real-time state tracking. Git serves as the immutable, offline, version-controlled distribution ledger and checkout mirror. Both are kept in continuous, automated, bidirectional synchronization.

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
    printf '## Source\n%s\n\n## Restart\n' "$([[ -n "$2" ]] && echo "/t/$2" || echo none)"
    printf -- '- key: %s\n- spec: %s\n- scope: %s\n- must not touch: %s\n' "$1" "${spec:-none}" "$scope" "${avoid:-see the brief}"
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

A new migration `csi-spl-rdb/src/sql/postgres/spool-hub/0205_issue_spec_attributes.sql` adds first-class columns and validation constraints to the `issues` table:

```sql
-- 0205_issue_spec_attributes.sql: First-class GitSpec task linkage on issues (SPL-2367)
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

-- 4. Constraint: Level 2 work issues must have spec_path once enforced
-- (Deferred trigger or gate-controlled constraint to allow staged backfill)
```

#### Field semantics & schema types

| Column | Type | Nullable | Default | Description & Format |
|---|---|---|---|---|
| `spec_path` | `text` | `NOT NULL` | `''` | Relative repo path of the specification or task document: `csi-spl-doc/specs/<NNN>-<slug>/<file>.md`. |
| `spec_task_id` | `text` | `NOT NULL` | `''` | Stable task row identifier within the spec's `tasks.md` (e.g. `T001`, `B4`, `T012.s1`). Empty string for Level 1 Epics that anchor the whole spec. |
| `spec_ref` *(Virtual / API)* | `string` | — | — | Computed URI fragment representation: `<spec_path>#<spec_task_id>` (e.g. `csi-spl-doc/specs/145-issue-spec-qto-sync/tasks.md#T001`). If `spec_task_id` is empty, equals `spec_path`. |

### 2.2 Hub API & wire protocol update (`csi-spl-api`)

The Go Hub API (`csi-spl-api/src/go/spool-hub-api/internal/hub/`) and wire contracts (`csi-spl-doc/specs/039-spool-issues/contracts/issues-v1.md`) are updated:

1. **`issueJSON` struct (`internal/hub/issues.go`)**:
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
2. **CLI endpoints (`spool issue`)**:
   - `spool issue create --title "<title>" --spec-path "<path>" [--spec-task "<id>"]`
   - `spool issue update --ref "<ref>" --spec-path "<path>" [--spec-task "<id>"]`
   - `spool issue list --spec-path "<path>"`: filters issues belonging to a specific spec.
3. **Live WebSocket frames**:
   - Any update to `spec_path` or `spec_task_id` broadcasts a standard `issue` frame across the workspace, updating all open browser views in real time.

### 2.3 Lane issue filing integration (`do_spl_lane_issue`)

The lane placement script (`csi-spl-orc/src/bash/run/spl-lane-issue.func.sh`) is updated:
1. `spl_lane_issue_place`:
   - Inspects `brief.md` for explicit metadata lines:
     `Spec: csi-spl-doc/specs/NNN-slug/` or `Spec: csi-spl-doc/specs/NNN-slug/tasks.md#T001`.
   - Parses the spec path and task identifier into variables `SLI_SPEC_PATH` and `SLI_SPEC_TASK_ID`.
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
4. If no spec is named in the card, links to the parent Epic's `spec_path`.
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
   - For authorized users, provides a dropdown/typeahead picker to link or change the GitSpec file and select a task row from `tasks.md`.

### 2.6 Enforcement gate (c-368 guard integration)

The `c-368` guard (`c-368-c002-issue-epic-spec-required`) and the pre-push check `do_check_pre_push` are equipped with a strict database check:
- **Rule 1 (Epic requirement)**: Every level-2 issue (`kind = 'issue'`) must have `parent_number IS NOT NULL` referencing an active Epic (`kind = 'epic'`).
- **Rule 2 (Spec requirement)**: Every level-2 issue must have a non-empty `spec_path` that resolves to a valid `tasks.md` file in the repository.
- **Rule 3 (Epic spec requirement)**: Every level-1 Epic must have a non-empty `spec_path` resolving to a valid `spec.md` file.
- **Rule 4 (Task ID validity)**: If `spec_path` points to a `tasks.md`, `spec_task_id` must match a real task ID in that file's table.

---

## 3. The four directions of bidirectional synchronization

The core engine provides automated, lossless synchronization across all four architectural directions.

```
       +-------------------------------------------------------+
       |                     Qto Editor                        |
       |  (workspace_doc, workspace_doc_item, workspace_doc_node)|
       +---------------------------+---------------------------+
                                   ^
            Direction 4 (Spec <-> Qto)| Direction 4 (Issue <-> Qto)
                                   v
+-----------------------------+         +-----------------------------+
|          GitSpec            | <-----> |           Issues            |
|   (spec.md, tasks.md)       |  Dir 1  | (issues, issue_discussions) |
|   on origin/master          |  Dir 2  | in PostgreSQL Hub Store     |
|                             |  Dir 3  |                             |
+-----------------------------+         +-----------------------------+
```

### 3.1 Direction 1: Issue -> GitSpec

**Trigger**: An issue changes in the Hub (status updated, assignee changed, title/scope edited, test criteria modified, or issue closed).  
**Tool**: `do_spl_issue_export_spec` (`csi-spl-orc/src/bash/run/spl-issue-export-spec.func.sh`).  
**Mechanism**:
1. Looks up the issue's `spec_path` and `spec_task_id`.
2. Locates the target `tasks.md` file in the workspace or repository clone.
3. Parses the Markdown task table while strictly preserving:
   - Markdown comments, front matter, section preamble, and non-table prose.
   - Column layout and pipe alignment.
4. Updates the target row matching `spec_task_id`:
   - Status mapping:
     - `done` -> `[x]` checkbox, Status column `Implemented`.
     - `wip` -> `[~]` or Status column `In Progress`.
     - `todo` / `eval` -> `[ ]` checkbox, Status column `Planned`.
     - `diss` -> `(dropped: SPL-NNN discarded)` or Status column `Discarded`.
     - `blocked` / `onhold` -> Status column `Blocked` / `On Hold`.
   - Updates Lane column with assignee if assigned.
5. Commits the updated `tasks.md` cleanly to git or queues a batch export commit.

### 3.2 Direction 2: Epic -> GitSpec

**Trigger**: An Epic is created or updated in the Hub (via WUI or `spool issue create --kind epic`).  
**Tool**: `do_spl_epic_export_spec` (`csi-spl-orc/src/bash/run/spl-epic-export-spec.func.sh`).  
**Mechanism**:
1. Determines target spec directory:
   - If `spec_path` is already set, uses that directory.
   - If empty, derives next free 3-digit number `NNN` and creates `csi-spl-doc/specs/NNN-<slug>/`.
2. Generates / updates `spec.md`:
   - Title: `# NNN: <Epic Title>`
   - Status: Draft / Planned (mapping Epic status).
   - Description & Background: Populated from Epic description and linked source discussion topics (`issue_discussions`).
3. Generates / updates `tasks.md`:
   - Queries all child issues of the Epic (`parent_number = epic.number`).
   - Generates the standard phased tasks table with rows `T001`, `T002`, ... mapping each child issue's title, status, assignee, and description.
4. Sets the Epic's `spec_path` to `csi-spl-doc/specs/NNN-<slug>/spec.md` and child issues' `spec_path` to `csi-spl-doc/specs/NNN-<slug>/tasks.md`.

### 3.3 Direction 3: GitSpec -> Issues

**Trigger**: A GitSpec author creates or updates `spec.md` and `tasks.md` in git (or a spec panel signs off a new spec).  
**Tool**: `do_spl_spec_import_issues` (`csi-spl-orc/src/bash/run/spl-spec-import-issues.func.sh` upgraded to v2).  
**Mechanism**:
1. Reads `csi-spl-doc/specs/NNN-<slug>/`:
   - Parses `spec.md` for title, status, and background.
   - Locates or creates the parent Epic titled `Spec NNN - <Title>`:
     - Sets `kind = 'epic'`, `level = 1`, `spec_path = 'csi-spl-doc/specs/NNN-<slug>/spec.md'`.
2. Parses `tasks.md` task table rows:
   - For each row (e.g. `T001`, `B1`, `T012`):
     - Checks if an issue already exists with `(tenant_id, spec_path, spec_task_id)`.
     - **If exists**: Updates title, description, status, and priority to match `tasks.md`.
     - **If new**: Creates a new Level 2 issue (`kind = 'issue'`, `level = 2`):
       - `title`: `[NNN <id>] <Task Summary>`
       - `parent_number`: Epic number
       - `spec_path`: `csi-spl-doc/specs/NNN-<slug>/tasks.md`
       - `spec_task_id`: `<id>`
       - `status`: Mapped from table checkbox/status (`[x]` -> `done`, `[~]` -> `wip`, `[ ]` -> `todo`/`eval`).
       - `discussions`: Inherits Epic's source discussion topic or tenant default.
3. Idempotent: running repeatedly produces zero spurious changes or duplicate issues.

### 3.4 Direction 4: GitSpec <-> Qto (and Issue <-> Qto)

**Trigger**: An author edits documentation in Qto, or a GitSpec is synced to Qto.  
**Tool**: `do_spl_qto_spec_sync` (`csi-spl-orc/src/bash/run/spl-qto-spec-sync.func.sh`).  
**Mechanism**:
1. **Importing GitSpec into Qto**:
   - Creates a `workspace_doc` for the specification titled `Spec NNN - <Title>`.
   - Creates hierarchical `workspace_doc_item` nodes for sections of `spec.md` (`## 0. Overview`, `## 1. Architecture`, etc.).
   - Converts `tasks.md` into an interactive **Qto Table / Grid Item** (utilizing Qto's dual outline/grid engine from Spec 113):
     - Columns: `Task ID`, `Status`, `Area`, `Lane`, `Summary`, `Gate & Red Control`, `Issue Key`.
     - Each row in the Qto grid stores attributes in `workspace_doc_item.attrs`:
       `{"spec_task_id": "T001", "issue_key": "SPL-2367", "status": "wip"}`.
2. **Interactive Editing in Qto**:
   - Humans and agents edit tasks in the Qto grid (adding rows, changing statuses, editing gates).
   - Real-time Qto change events (`workspace_doc_rev_log`) trigger background hub synchronization:
     - Updates the linked `issues` table row in PostgreSQL immediately.
     - Queues an export to update the git checkout `tasks.md`.
3. **Exporting Qto to GitSpec Markdown**:
   - `do_spl_doctree_export_md` is enhanced to serialize Qto Table/Grid items into formatted GFM pipe tables with pristine CommonMark compatibility.

---

## 4. Primary storage and index architecture: answering the owner's question

Owner HUM-10 asked:
> *"Actually, isn't it the case that the whole GitSpec could also be imported to the QTO, and that the QTO could be the primary storage and primary index for the MD documentation?"*

This section provides the rigorous architectural analysis and the concrete solution.

### 4.1 Comparative evaluation: Qto vs Git

| Dimension | Qto (PostgreSQL + RLS + WebSocket Hub) | Git (Filesystem + Remote Trunk) |
|---|---|---|
| **Storage Engine** | PostgreSQL relational tables (`workspace_doc`, `workspace_doc_item`, `workspace_doc_node`) | Git object store (`.git/objects`, blobs, trees, commits) |
| **Indexing & Search** | Full-text indexing, Omnibox top-bar search (`/search`), relational joins with issues and discussions | Grep / ripgrep on filesystem, external indexers (`graft`), git log search |
| **Concurrency & Editing** | Multi-seat real-time collaborative editing, field-level locking, instant save, zero merge conflicts during drafting | Branch/checkout isolation, pull-requests, merge conflicts requiring manual rebase |
| **Access Control (RLS)** | Strict workspace isolation, RBAC permissions, private document scopes (`workspace_doc_acl`) | All-or-nothing repository clone access |
| **Offline Execution** | Requires network connectivity to Spool Hub API | Fully offline; agents can read and write locally in worktrees |
| **Traceability & Auditing** | `workspace_doc_rev_log` timestamped operations, `issue_events` | Cryptographic commit hashes (`commit_sha`), git blame, signed tags |
| **CI / CD Gating** | Webhook / event-driven checks | Native GitHub Actions triggers, pre-push hooks, release deployment tags |

### 4.2 The verdict: The Dual-Anchor Synchronized Model

Can Qto be the primary storage and primary index? **Yes, for interactive workspace authoring, indexing, and live status tracking.**  
However, retiring Git files entirely would break:
1. Offline agent execution in isolated worktrees (agents reading `spec.md` without network).
2. Atomic coupling of code changes with their specification changes in the same commit.
3. Pre-push gates and CI deployment workflows that trigger on git pathspecs.

Therefore, the architecture establishes the **Dual-Anchor Synchronized Model**:

```
[ Author / WUI / Human ]           [ Agent / Worktree / CI ]
         |                                     |
         v                                     v
+------------------------+           +------------------------+
|   PRIMARY INTERACTIVE  |           |   PRIMARY VERSIONED    |
|     STORAGE & INDEX    |           |  DISTRIBUTION & GATE   |
|         (Qto)          |           |         (Git)          |
|  - Real-time editing   |           |  - Offline worktrees   |
|  - Omnibox search      |           |  - Atomic code commits |
|  - Relational queries  |           |  - CI/CD deploy gates  |
|  - Grid & Outline view |           |  - Git blame & tags    |
+-----------+------------+           +------------+-----------+
            ^                                     ^
            |       Continuous Bidirectional      |
            +============ Synchronization ========+
```

1. **Qto is the Primary Authoring Store and Primary Relational Index:**
   - All documentation search, navigation, cross-referencing, and interactive editing happen in Qto.
   - The Omnibox and WUI query Qto database tables directly with sub-millisecond response times.
   - Task lists are managed in Qto's dual outline/grid interface with direct relational links to issues.
2. **Git is the Primary Versioned Distribution and Code-Coupling Ledger:**
   - Every commit to trunk (`master`) that touches `csi-spl-doc/specs/` automatically reconciles into Qto.
   - Every edit made in Qto automatically generates a signed git commit or export bundle.
   - Agents working in worktrees (`/opt/csi/csi-spl-wt/<agent>`) continue to read local files (`spec.md`, `tasks.md`), guaranteed to match Qto.

---

## 5. Round-trip fidelity, surviving identifiers, and conflict resolution

To prevent split-brain states and data corruption across the four synchronization directions, the system adheres to strict identifier persistence and conflict resolution algorithms.

### 5.1 Immutable surviving identifiers

Every entity across the three layers maintains an immutable, persistent identifier:

| Entity | Primary Key / Identifier | Scope & Stability | Cross-System Reference |
|---|---|---|---|
| **Issue** | Key (`SPL-2367`) & `(tenant_id, number)` | Permanent, immutable once minted by Hub | Stored in `tasks.md` row; stored in Qto item `attrs.issue_key`. |
| **Epic** | Key (`SPL-2350`) & `(tenant_id, number)` | Permanent, immutable | Stored in `spec.md` header; stored in Qto doc `attrs.epic_key`. |
| **GitSpec Feature** | Directory Path `csi-spl-doc/specs/NNN-<slug>/` | Stable across git branches and checkouts | Stored in `issues.spec_path`; stored in Qto doc `attrs.spec_path`. |
| **GitSpec Task** | String ID (`T001`, `B4`, `T012.s1`) | Stable within `tasks.md` | Stored in `issues.spec_task_id`; stored in Qto item `attrs.spec_task_id`. |
| **Qto Document** | UUID `workspace_doc.id` | Permanent per tenant | Stored in `csi-spl-doc/doc/md/qto-docs.tsv` and `spec_sync_map`. |
| **Qto Task Item** | UUID `workspace_doc_item.id` | Permanent per doc revision | Stored in `spec_sync_map.item_id`. |

### 5.2 The cross-system synchronization ledger (`spec_sync_map`)

To track revisions, hashes, and parity without polluting git files with UUIDs, a lightweight ledger table is added in `0205_issue_spec_attributes.sql`:

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

### 5.3 Conflict resolution rules

When concurrent edits occur in both Git and Qto/Issues:

1. **Rule 1: Landing on Master Trumps Drafts (Landed Code Wins).**  
   If a git commit lands on `origin/master` citing an issue or closing a task, the git commit sha and its task status (`done`) take absolute precedence over any uncommitted WUI edits. The issue moves to `done` and Qto is updated.
2. **Rule 2: Three-Way Merge on Content.**  
   When text in `spec.md` or descriptions in `tasks.md` are modified in both Git and Qto, the engine performs a standard 3-way merge using the `last_git_sha` recorded in `spec_sync_map` as the common ancestor.
   - Non-overlapping section edits merge automatically.
   - Overlapping edits trigger a conflict record (`sync_status = 'conflict'`) and post a warning to the dispatch topic.
3. **Rule 3: Structural Grid Protection.**  
   Adding or removing a task row in `tasks.md` or Qto is reconciled additively:
   - A new row in `tasks.md` creates a new issue and Qto item.
   - A new item in Qto appends a new row to `tasks.md` with the next sequential task ID (e.g. `T015`).
   - Row deletion in git or Qto is converted to `status = 'diss'` (discarded) rather than hard deletion, preserving audit history.

---

## 6. Acceptance criteria and concrete red controls

Every capability in this specification is guarded by strict acceptance criteria and corresponding red controls (planted failure tests).

| ID | Capability & Acceptance Criterion | Verification Command / Gate | Red Control (Planted Defect & Expected Failure) |
|---|---|---|---|
| **AC-1** | **Issue Spec Schema Migration**: `issues` table accepts `spec_path` and `spec_task_id` with regex validation. | `psql -c "INSERT INTO issues (..., spec_path, spec_task_id) VALUES (..., 'csi-spl-doc/specs/145-issue-spec-qto-sync/tasks.md', 'T001')"` succeeds. | Planted insert with `spec_path = 'invalid/path/file.txt'` must fail with check constraint violation. |
| **AC-2** | **Hub API Wire Parity**: `POST /v1/issues` and `PATCH /v1/issues/{ref}` accept and return `spec_path`, `spec_task_id`, and `spec_ref`. | Go unit test `internal/hub/issues_spec_test.go` verifies serialization, creation, and updating. | Removing `SpecPath` from `issueJSON` causes API contract tests to fail. |
| **AC-3** | **Lane Issue Filing Integration**: `do_spl_lane_issue` extracts spec path and task ID from brief and sets issue attributes. | `AGENT_ID=a-478 BRIEF=... DRY_RUN=1 ./run -a do_spl_lane_issue` outputs plan with `--spec-path` and `--spec-task`. | Omitting spec attributes from `spool issue create` invocation causes filing test assertion failure. |
| **AC-4** | **c-368 Guard Enforcement**: A level-2 issue without an Epic parent AND a valid GitSpec path is refused. | `c-368` guard script verifies compliance across all live issues. | Creating an issue with `spec_path = ''` must cause `c-368` gate to exit with status 1. |
| **AC-5** | **Historical Backfill Accuracy**: `do_spl_issue_spec_backfill` populates empty spec attributes from description cards. | Run `do_spl_issue_spec_backfill DRY_RUN=1` against test dataset; verifies 100% of parsable cards resolve. | Planted corrupt card with missing spec path correctly logs warning and marks unresolved without crashing. |
| **AC-6** | **Direction 1 (Issue -> Spec Export)**: Changing issue status in Hub updates `tasks.md` table without corrupting formatting. | `do_spl_issue_export_spec ISSUE=SPL-2367 STATUS=done` updates target row in `tasks.md`. | Mutating non-target rows or modifying table column count fails diff sanity check. |
| **AC-7** | **Direction 3 (Spec -> Issue Import)**: Importing `tasks.md` creates missing issues and reconciles existing ones idempotently. | `do_spl_spec_import_issues SPEC_DIR=...` creates missing tasks; second run reports 0 changes. | Running with mismatched task IDs fails validation without creating duplicate issues. |
| **AC-8** | **Direction 4 (GitSpec <-> Qto Round Trip)**: Importing `tasks.md` to Qto and exporting back produces byte-identical table markdown. | `do_spl_qto_spec_sync` import followed by export; `diff -u original.md exported.md` is empty. | Dropping task grid attributes during Qto serialization produces non-empty diff and fails test. |

---

## 7. Owner decision forms (for topic 197811a0)

The dispatcher (`c-002`) will present the following structured decision forms to Owner HUM-10 in discussion topic `197811a0-f15b-40ef-b6cf-19da0ddc1182`.

### Form 1: Primary storage and index architecture

```
Question: How should the relationship between Qto and Git documentation be structured?

Option A (Recommended): Dual-Anchor Synchronized Architecture
- Qto is the primary interactive store and relational index for real-time editing, Omnibox search, and live status.
- Git is the authoritative versioned distribution store for offline agent worktrees, commit-level PR reviews, and CI deploy gates.
- Continuous automated bidirectional sync keeps both stores in lockstep.

Option B: Pure Qto-Primary with Read-Only Git Exports
- Documentation is edited ONLY in Qto.
- Git files are 100% read-only generated exports (like compiled binaries).
- Disadvantage: Agents in offline worktrees cannot edit specs alongside their code commits.

Option C: Git-Primary with Read-Only Qto View
- Git remains the sole source of truth; Qto is only a viewer and indexer.
- Disadvantage: Gives up real-time multi-agent editing and grid-based interactive task management in the WUI.

Recommendation: Option A. Gives the best of both worlds: live WUI/Qto editing with search while preserving worktree autonomy and commit atomicity.
```

### Form 2: GitSpec attribute strictness and validation

```
Question: How strictly should the first-class spec attribute be validated at issue creation?

Option A (Recommended): Strict Path & Task Validation
- Every work issue must provide both a valid spec file path (`csi-spl-doc/specs/NNN-slug/tasks.md`) AND a verified task ID (`T001`).
- The Hub API validates that the file exists and contains that task ID.
- Level-1 Epics link to `spec.md`; Level-2 Issues link to `tasks.md#<task_id>`.

Option B: Loose Spec-Directory Only
- Issues only link to the spec directory (`csi-spl-doc/specs/NNN-slug/`), leaving task IDs free-form or optional.
- Disadvantage: Loses 1:1 task-to-issue isomorphism and breaks automated grid row reconciliation.

Recommendation: Option A. Aligns directly with your directive: "an issue is already defined as a task to be done in the gitspec."
```

### Form 3: Automated Git commit cadence for Qto edits

```
Question: When human or agent users edit specs or tasks in Qto, when should git commits be created?

Option A (Recommended): Debounced Batch Commits (Hourly or per Work Session)
- Edits in Qto update the PostgreSQL database immediately.
- A background worker batches edits and creates a clean git commit every 15-30 minutes, or upon explicit "Publish / Sync to Git" button click.
- Avoids flooding git master history with micro-commits for every keystroke.

Option B: Instant Commit on Every Change
- Every single status change or paragraph edit immediately triggers an automated commit and push to master.
- Disadvantage: May create dozens of trivial commits per hour and increase rebase churn across the fleet.

Recommendation: Option A. Keeps git trunk history clean and meaningful while keeping Qto instantly responsive.
```

### Form 4: Handling legacy and ad-hoc issues without specs

```
Question: How should legacy issues or quick ad-hoc bugs that do not yet have a formal spec be treated under the c-368 guard?

Option A (Recommended): Automated "Catch-All" Area Specs
- Issues that do not warrant a full 10-page spec are filed under categorized "Area Specs" (e.g. `csi-spl-doc/specs/000-operations/`, `csi-spl-doc/specs/000-quick-fixes/`).
- Ensures 100% schema compliance without requiring heavy spec panels for one-line fixes.

Option B: Exemption Label (`no-spec`)
- Allow a special bypass label `no-spec` that permits issues without a spec attribute.
- Disadvantage: Creates a loophole where agents and humans avoid writing specs, reverting to untracked work.

Recommendation: Option A. Maintains architectural purity ("no issue without an epic and a git spec") while keeping the workflow agile for small fixes.
```

---

<!-- version: 0.1.0 · updated: 2026-10-17 -->
