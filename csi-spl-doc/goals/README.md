# Goals, Strategy, and Roadmap

> Generated from qto doc `a8cc35c0-dc42-4ea4-9806-8f21a4cbbe4b`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

This directory holds goal and strategy documents for the csi-spl project.

<a id="ws-doc-4d81a20c-ef70-4e6a-9684-dff09125aa24"></a>
## How to Create a Goal

1. **Copy the template**:
   ```bash
   mkdir -p "goals/<id>-<slug>"
   cp goals/template-goal.yaml "goals/<id>-<slug>/goal.yaml"
   cp goals/template-strategy.md "goals/<id>-<slug>/strategy.md"
   ```

2. **Fill in `goal.yaml`**:
   - `id`: Format `G<XX>-<slug>` (e.g., `G01-first-million`).
   - `workspace`: The workspace slug (e.g., `csi-spl`). Events land in this workspace only.
   - `owner_role`: The RBAC role responsible for this goal (e.g., `biz_owner or admin`).
   - `deadline`: ISO date (e.g., `2026-12-31`).
   - `milestones`: Key events with dates and titles.
   - `done_lines`: Measurable outcomes for success.
   - `specs`: Spec IDs that serve this goal (e.g., `089`).
   - `approval.msg_id`: Spool message ID from a `biz_owner` or `admin` of this goal's workspace (D2).

3. **Fill in `strategy.md`**:
   - Describe the strategy to achieve the goal.
   - After the deadline, replace the "Retrospective" section with outcomes.

4. **Submit for review**:
   - Push to a branch and request a review from the approver role.
   - After approval, merge to `master`.

<a id="ws-doc-a9a1cf01-3e54-4db1-9e1c-3a525ee80316"></a>
## Rules

- **Public by default (D1)**: All documents are public unless `public: false` is set in `goal.yaml`. `public:` is the repo-doc flag, never the calendar audience (audience = workspace switch, RDB-2).
- **Owner as a role (D2)**: Never use a person's name. A goal's events land in its `workspace` only, and a `biz_owner` or `admin` of that workspace approves it.
- **Retrospective**: After the deadline, document outcomes in `strategy.md`.
- **Language review**: agy reviews all documents last (LANE_MIX_KIND=i18n).

<a id="ws-doc-3522e1bf-0b63-47b6-8012-a068f074dbb9"></a>
## Backfill

- **Git**: Major milestones are backfilled from git history (e.g., `v1.0.0` tags, specs turned done).
- **DB**: Owner decisions are backfilled from spool topics (audience: `internal`).

<a id="ws-doc-f2db76d3-0359-48d4-87b6-8317acdb7c30"></a>
## Templates

- [`template-goal.yaml`](./template-goal.yaml): Goal metadata.
- [`template-strategy.md`](./template-strategy.md): Strategy and retrospective.
