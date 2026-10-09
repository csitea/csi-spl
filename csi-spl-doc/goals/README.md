# Goals, Strategy, and Roadmap

This directory holds goal and strategy documents for the csi-spl project.

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

## Rules

- **Public by default (D1)**: All documents are public unless `public: false` is set in `goal.yaml`. `public:` is the repo-doc flag, never the calendar audience (audience = workspace switch, RDB-2).
- **Owner as a role (D2)**: Never use a person's name. A goal's events land in its `workspace` only, and a `biz_owner` or `admin` of that workspace approves it.
- **Retrospective**: After the deadline, document outcomes in `strategy.md`.
- **Language review**: agy reviews all documents last (LANE_MIX_KIND=i18n).

## Backfill

- **Git**: Major milestones are backfilled from git history (e.g., `v1.0.0` tags, specs turned done).
- **DB**: Owner decisions are backfilled from spool topics (audience: `internal`).

## Templates

- [`template-goal.yaml`](./template-goal.yaml): Goal metadata.
- [`template-strategy.md`](./template-strategy.md): Strategy and retrospective.
