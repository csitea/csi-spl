# Spec 112: Goals, strategy and roadmap

Version **v0.2** (2026-10-08). Drafted by a-597.
Authority for behaviour and its rules; `tasks.md` for what is built.

## 1. Owner ask and decisions (verbatim, HUM-10, t1 topic 4e373f5d)

| msg | text |
|---|---|
| d9f09d6e | "we should be able to track the development on the \"grande\" scale ..." |
| cf2e196f | "meaning support for bigger features - set goals which sound impossible and are time constraint - create strategy docks and set the dates and publish in the calendar" |
| 6fa21e9f | "and than have reflection on the time was up - what did we get achieve and why" |
| 8db02912 | "the roadmap should be interlinked with the calendar" |
| 16d97409 | "it would be nice to also see our major achievemnts wha twe already hadd based on the relase logs with linlks to them with some milestones in the past in the calendar" |
| 757d45d9 | "like I do not even recall when I did started this project" |
| 078bf1a6 | "so some kinf of backfill based on the git history etc. and the discussions in the db as well .." |

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

## 4. Dates in the Calendar & Interlinking
Goals and their milestones are published as events in the app's Calendar section (spec 089/097/106).
- **Two-way Links:** Every goal deadline and milestone on the roadmap is a calendar event that links back to its roadmap row and strategy doc; opening a goal's calendar event shows the goal on the roadmap.
- **Source of Truth:** The roadmap definitions in the repository (`csi-spl-doc/goals/`) are the single source of truth for goal deadlines. The calendar in the DB is synced from this definition on each deploy.
- **Reminders:** Events will contain reminders leading up to the deadline.

## 5. Roadmap View
The roadmap is a comprehensive view of the development on the "grande" scale.
- **Layout:** One row per spec with its state and the percentage of tasks ticked.
- **Filter:** Add a roadmap filter for "this week / this month" derived from the calendar dates.
- **Generation:** Generated from the repository on each deploy.
- **Baseline measurement:** As of this spec's drafting, the roadmap has 88 specs with `tasks.md` files: 16 done, 58 in progress, 14 with no ticks. (Measured via the script iterating over `- [x]` vs `- [ ]`).

## 6. Tracking
- **Progress:** The progress of each goal is calculated as the share of its linked specs that are done.
- **Visibility:** This progress is visible on the roadmap view and on the individual goal page in the WUI.

## 7. Retrospective
When a goal's deadline passes, a retrospective is triggered via the calendar.
- **Content:** A reflection doc per goal detailing what was achieved versus the done-line, what was not, and WHY. It includes evidence (specs done/open, lanes, reds and blockers, time lost).
- **Authoring:** Written by an agent (mistral first for document drafting, then agy for language review).
- **Location:** Saved as `csi-spl-doc/goals/<id>-<slug>/retrospective.md` next to the strategy doc.
- **Publishing:** It is posted to the owner via spool message. It can also be published as a blog post (spec 111) if marked as public-safe.

## 8. Past Achievements Backfill
The roadmap and calendar are backfilled with historical milestones to visualize what has already been achieved.

### 8.1. Backfill from Git
- **The First Event:** The backfill starts precisely with `2026-09-17 spool-hub started` (first commit b588b50c2).
- **Major Milestones:** Derived from `v*` tags, `refs/notes/release-notes` (and `/releases/<sha>` pages), and specs ticked done.
- **'Major' Rule:** An event is included if it represents a spec marked done, a first-of-its-kind technical milestone, or a minor version release (e.g., x.y.0). Not every patch tag is included.
- **Display:** Displayed as PAST milestone events in the Calendar and on the roadmap timeline, each linking directly to its release note.
- **Execution:** Runs once on initial deployment, then incrementally adds new events on each deploy.

### 8.2. Backfill from DB Discussions
- **Source:** The hub DB discussions, including topics with owner decisions ('go', 'yes', answered questions), drills, and launches.
- **Execution:** Run read-only as the per-env SA under RLS.
- **Privacy & Scope:** DB-derived milestones are visible only inside their own workspace and are never shared cross-workspace or published to the public blog.
- **Content:** Only records decisions and outcomes, with no personal message text beyond a short owner quote. Each milestone links directly to the topic permalink.
- **Process Split:** 
  1. An extraction action (code) proposes milestone candidates.
  2. An agent picks and words the major ones (doc kind, e.g., mistral + agy).
  3. The owner reviews and prunes the list.
- **Frequency:** One-time backfill, then incremental updates.

## 9. Rules and Constraints
- **Distribution Hygiene:** All docs and UI must be org-neutral with no personal names (CSP and repository rules apply).
- **i18n:** Subject to the language rule (agy reviews the languages before shipping).
- **Theming:** The roadmap and goal views must support dark and light theme.
- **Performance:** Any new UI components added to the WUI must fit within the initial-chunk budget (155 KB).

## 10. Owner Questions & Recommendations
- **Should the strategy docs be public by default, or internal only?**
  *Recommendation:* Internal only by default. They can be selectively marked public (e.g., via a frontmatter flag `public: true`) when safe.
- **Who approves the goal's deadline before it's published to the calendar?**
  *Recommendation:* The owner explicitly approves the deadline via a spool message decision before the calendar event is officially synced.
