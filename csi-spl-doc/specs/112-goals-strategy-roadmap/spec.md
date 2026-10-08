# Spec 112: Goals, strategy and roadmap

Version **v0.1** (2026-10-08). Drafted by a-597 as v0.1.
Authority for behaviour and its rules; `tasks.md` for what is built.

## 1. Owner ask and decisions (verbatim, HUM-10, t1 topic 4e373f5d)

| msg | text |
|---|---|
| d9f09d6e | "we should be able to track the development on the \"grande\" scale ..." |
| cf2e196f | "meaning support for bigger features - set goals which sound impossible and are time constraint - create strategy docks and set the dates and publish in the calendar" |
| 6fa21e9f | "and than have reflection on the time was up - what did we get achieve and why" |

## 2. Goals
Goals are "grande" scale objectives that are ambitious (they should "sound impossible").
Every goal has:
- A unique ID and short slug (e.g. `G01-first-million`).
- An owner.
- A hard deadline (date).
- Measurable done-lines (what exactly constitutes success).
- A list of specs and lanes that serve this goal.

## 3. Strategy Docs
Each goal is backed by a strategy document.
- **Location:** Stored in the repository alongside specs, under `csi-spl-doc/goals/<id>-<slug>/strategy.md`.
- **Template:** The strategy doc must list the owner, deadline, done-lines, and the linked specs.
- **Authoring:** Document writing is delegated to mistral (per spec 110 D5).
- **Language Review:** Any user-facing or multilingual text in the strategy doc must be reviewed by agy (per the repo CLAUDE.md language rule a391ab7a4).

## 4. Dates in the Calendar
Goals and their milestones are published as events in the app's Calendar section (spec 089) and phone calendar (spec 106).
- Events will contain reminders leading up to the deadline.
- Calendar events are read from the goals in the repository and synced to the database on each deploy, similar to how specs are tracked.

## 5. Roadmap View
The roadmap is a comprehensive view of the development on the "grande" scale.
- **Layout:** One row per spec with its state and the percentage of tasks ticked.
- **Generation:** Generated from the repository on each deploy.
- **Baseline measurement:** As of this spec's drafting, the roadmap has 88 specs with `tasks.md` files: 16 done, 58 in progress, 14 with no ticks.
  Command used to measure:
  ```bash
  total=$(ls csi-spl-doc/specs/*/tasks.md 2>/dev/null | wc -l); done_specs=0; in_progress=0; no_ticks=0; for f in csi-spl-doc/specs/*/tasks.md; do x=$(grep -c '^\s*- \[x\]' "$f"); open=$(grep -c '^\s*- \[[ ~]\]' "$f"); if [ "$open" -eq 0 ] && [ "$x" -gt 0 ]; then ((done_specs++)); elif [ "$x" -eq 0 ] && [ "$open" -gt 0 ]; then ((no_ticks++)); elif [ "$x" -gt 0 ] && [ "$open" -gt 0 ]; then ((in_progress++)); elif [ "$x" -eq 0 ] && [ "$open" -eq 0 ]; then ((no_ticks++)); fi; done; echo "Total: $total, Done: $done_specs, In Progress: $in_progress, No Ticks: $no_ticks"
  ```
  *(Note: exact numbers slightly vary from the dispatcher's original n=1 proposal due to ongoing merges on master)*

## 6. Tracking
- **Progress:** The progress of each goal is calculated as the share of its linked specs that are done.
- **Visibility:** This progress is visible on the roadmap view and on the individual goal page in the WUI.

## 7. Retrospective
When a goal's deadline passes, a retrospective is triggered via the calendar.
- **Content:** A reflection doc per goal detailing what was achieved versus the done-line, what was not, and WHY. It includes evidence (specs done/open, lanes, reds and blockers, time lost).
- **Authoring:** Written by an agent (mistral first for document drafting, then agy for language review).
- **Location:** Saved as `csi-spl-doc/goals/<id>-<slug>/retrospective.md` next to the strategy doc.
- **Publishing:** It is posted to the owner via spool message. It can also be published as a blog post (spec 111) if marked as public-safe.

## 8. Rules and Constraints
- **Distribution Hygiene:** All docs and UI must be org-neutral with no personal names (CSP and repository rules apply).
- **i18n:** Subject to the language rule (agy reviews the languages before shipping).
- **Theming:** The roadmap and goal views must support dark and light theme.
- **Performance:** Any new UI components added to the WUI must fit within the initial-chunk budget (155 KB).

## 9. Owner Questions
- Should the strategy docs be public by default, or internal only?
- Who approves the goal's deadline before it's published to the calendar?
