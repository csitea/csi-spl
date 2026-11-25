# Spec 112: Goals, strategy and roadmap

Version **v1.3** (2026-11-25): v1.2 plus the milestones-as-records, epic dates + roll-up, and `/roadmap` timeline amendment in section 13 (SPL-6452, epic SPL-2396, owner HUM-10 t1 topic `7653cb85`).
v1.2 (2026-10-09): v1.1 plus the owner's answers to OQ1-OQ3 (12.8), msg 730f6f90.
v1.1 (2026-10-09): v1.0 plus the per-workspace amendment in section 12.
v1.0 (2026-10-08) drafted by a-597 (v0.1, v0.2 `8c9766cd1`);
folded to v1.0 by c-604. Seats s112-2 and s112-3 agreed with changes, and every
change folded or not is listed in 11.1. Seat s112-4 (mistral) comes later as an
addendum. Authority for behaviour and its rules; [tasks.md](tasks.md) for what
is built.

## 0. Owner asks and decisions (verbatim, HUM-10, t1 topic 4e373f5d)

| msg | text |
|---|---|
| d9f09d6e | "we should be able to track the development on the \"grande\" scale ..." |
| cf2e196f | "meaning support for bigger features - set goals which sound impossible and are time constraint - create strategy docks and set the dates and publish in the calendar" |
| 6fa21e9f | "and than have reflection on the time was up - what did we get achieve and why" |
| 8db02912 | "the roadmap should be interlinked with the calendar" |
| 16d97409 | "it would be nice to also see our major achievemnts wha twe already hadd based on the relase logs with linlks to them with some milestones in the past in the calendar" |
| 757d45d9 | "like I do not even recall when I did started this project" |
| 078bf1a6 | "so some kinf of backfill based on the git history etc. and the discussions in the db as well .." |
| **5a9aab48** | **DECIDED**: "1. public 2. the cloud instance admin - in this case me , for other cloud intances and DNS their owners ..." (to the section 10 questions) |
| **4fc63469** | **DECIDED**: "mm every workspace should be possible to have its own roadmap" (v1.1, section 12) |
| **26477898** | **DECIDED**: "both biz_owner and admin can do th eapproaval of he goals , not only the one or the another" (v1.1, section 12) |
| **730f6f90** | **DECIDED** (OQ1): "Proceed according to your suggestions." A workspace with no git repo keeps its goals as goal documents inside the app (v1.2, 12.8) |
| **730f6f90** | **DECIDED** (OQ2): "Proceed according to your suggestions." The spool's own roadmap is just another workspace roadmap, no special case (v1.2, 12.8) |
| **730f6f90** | **DECIDED** (OQ3): "Proceed according to your suggestions." Workspace roadmaps are internal by default, with a per-workspace switch to make one public (v1.2, 12.5, 12.8) |

**D1 (msg 5a9aab48, Q1 = public).** Strategy docs are public by default. This
overrides v0.2's "internal" recommendation, and it matches a fact: the repo is
public (`gh repo view csitea/csi-spl --json visibility` -> `PUBLIC`, seat
s112-2), so a file under `csi-spl-doc/goals/` is public the moment it is pushed.

- Every strategy and retrospective doc passes the spec 111 public-safe gate
  (111 section 4.4: `do_check_dist_hygiene`, "matrix" only, no workspace data,
  no personal data) before it is pushed.
- Text derived from the DB (8.2) is never in a public doc. It stays in the DB
  (the workspace's calendar events) or in the spool.
- agy's language review is the last step of every doc (repo CLAUDE.md language
  rule, a391ab7a4).
- One doc may still be internal. It then never enters the repo: it lives as a
  workspace repodocs page or a spool post, and the roadmap links to it only for
  members of that workspace.

**D2 (msg 5a9aab48, Q2 = the cloud instance admin approves deadlines).** On
this instance that is the owner; on another self-hosted instance (and its DNS
domain) it is that instance's own admin.

- It is a role per instance, never a name: cnf `env.roadmap.approver_role`
  names an rbac role id (`internal/rbac/rbac.go` `RoleIDs`, e.g. `admin`) in
  the workspace `env.roadmap.tenant_id`. No default; the sync fails fast
  without it. No person's name or id is in code, cnf or tests (hygiene rule 5).
- An approval is a message id in `goal.yaml` (`approval.msg_id`). The hub sync
  (4.2) publishes a goal deadline only when that message exists in the roadmap
  workspace and its author holds the approver role there. Otherwise the goal
  is reported as `unapproved` and no event is written for it.

> **Amended by v1.1, section 12.3 (approver roles) and 12.2 (no single `tenant_id`).**

## 1. What v1.0 settles

| topic | v1.0 rule | from |
|---|---|---|
| store of goals | the repo (`csi-spl-doc/goals/<id>-<slug>/goal.yaml`); no goals table | s112-3 #1/#4, D1 |
| calendar | a read-only projection of the repo, keyed by `calendar_events.source_key` | s112-2 #2c, s112-3 #1/#2 |
| done-% rule | ONE action, `do_spl_spec_progress`; `[~]` counts as open | s112-2 #1 (section 5.1) |
| roadmap data | `roadmap.json`, built at WUI generate time from that action | s112-2 #7, s112-3 #4 |
| writes | only through the hub sync route, deploy identity only | s112-2 #6 |
| DB backfill | own tenant-scoped read-only action, never `do_spl_db_query` | s112-2 #5 |
| audience | set on every synced event; DB-derived = `internal` | s112-2 #4 |

## 2. Goals

Goals are "grande" scale objectives that are ambitious (they should "sound
impossible") and time-bound. One goal = one dir
`csi-spl-doc/goals/<id>-<slug>/` holding:

- `goal.yaml`, the single source of truth for every goal date:
  - `id`: `^G[0-9]{2}-[a-z0-9-]{1,48}$` (e.g. `G01-first-million`).
  - `owner_role`: an rbac role id, never a person (hygiene rule 5).
  - `deadline`: an ISO date.
  - `milestones`: `[{key, date, title}]`, `key` in `[a-z0-9-]{1,32}`.
  - `done_lines`: the measurable lines that say what success is.
  - `specs`: the three-digit spec ids that serve the goal; `lanes` optional.
  - `approval`: `{msg_id}`, set once the approver role (D2) said yes.
- `strategy.md` (section 3) and, after the deadline, `retrospective.md`
  (section 7).

A goal with no `approval.msg_id` is a draft. A draft shows on the roadmap
marked "draft", and never reaches the calendar.

## 3. Strategy docs

- **Location:** `csi-spl-doc/goals/<id>-<slug>/strategy.md`, next to
  `goal.yaml`. Template: `csi-spl-doc/goals/template-strategy.md`.
- **Template:** owner role, deadline, done-lines, linked specs, and the
  strategy itself. The dates are not copied into the doc: it links to
  `goal.yaml`, so there is one copy of each date.
- **Public by default (D1):** the doc passes the 111 public-safe gate before
  the push. No owner quote, no workspace data, no DB-derived evidence.
- **Authoring:** mistral drafts (spec 110 D5); agy reviews the language last
  (repo CLAUDE.md language rule, a391ab7a4).

## 4. Dates in the calendar and interlinking

### 4.1. One source of truth, links both ways, edits one way

- The repo holds every goal date. The calendar holds a projection of it.
- "Two-way" means links in both directions, never edits in both directions.
  A synced event (`source_key` set, see 4.2) is read-only in the WUI: no edit
  and no drag, and a "change it in the repo" link instead. The hub answers a
  PATCH or DELETE on it with **409**. Otherwise the next deploy would silently
  revert a date someone moved in the calendar.
- Events go to ONE workspace, the operator's, named in cnf
  `env.roadmap.tenant_id` (no literal, no default), never to every workspace.

> **Amended by v1.1, section 12.2 (one roadmap per workspace).**

### 4.2. Data model and sync

- **Migration (the next free number at build time;
  `ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1` -> `0155_mistral_kind.sql`
  today).** Forward-only and additive:
  - `calendar_events.source_key text NULL` with a partial unique index
    `UNIQUE (tenant_id, source_key) WHERE source_key IS NOT NULL`.
  - widen the `kind` CHECK (0125 line 24, 7 kinds today) and the store's
    `calendarKinds` (`internal/store/calendar.go` line 53) with `goal` and
    `milestone`.
  - RLS is unchanged: `calendar_events` already has its 0125 policies.
- **Keys:** `goal:G01:deadline`, `goal:G01:m:<key>`, `release:v1.3.0`,
  `spec:089:done`, `db:<topic_id>`. Every sync and backfill re-run is an
  upsert by key, never a duplicate. A `goal:` or `spec:` key no longer in the
  repo is soft-deleted (`deleted_at`).
- **Past releases** keep kind `release` plus the existing `release_version`
  column, so the event dialog's release link works unchanged. The existing
  `topic_id` column carries a DB milestone's topic permalink.
- **Route:** `PUT /v1/calendar/sync`, an idempotent bulk upsert by
  `source_key`. `creator_type = 'system'`, `creator_id = 'roadmap-sync'`.
  Only the deploy identity may call it; a human or agent seat gets 403. The
  deploy-time sync (wf 20) and the git backfill (8.1) both call it; neither
  writes SQL from a box.
- **Lookup:** the event list takes a `source_key` prefix filter
  (`?source_key=goal:G01:`), so the WUI never guesses an event id.

> **Amended by v1.1, section 12.4 (sync over several workspaces).**
> **Extended by v1.3, sections 13.3 and 13.6 (workspace milestones as first-class records and calendar read-only projection; no copy into `calendar_events`).**

### 4.3. Audience

Every synced or backfilled event sets `audience` explicitly; the 0125 default
is `public`. Goal, milestone, release and spec events are `public`. A
`db:` event is `internal` (the audience the hub drops for a guest,
`internal/store/calendar.go`). The store refuses a `db:%` key with any other
audience, and a store test covers it.

> **Amended by v1.1, section 12.5 (workspace roadmaps internal by default).**

### 4.4. Links

- Each synced event carries `props.roadmap_url` =
  `/roadmap?goal=G01#spec-089` plus the strategy-doc link (the `repoWebUrl`
  + help-path pattern; an empty cnf hides it).
- A roadmap row and the goal page link to `/calendar?d=<iso>&event=<id>`, the
  deep link that already opens an event (`calendar.vue` reads `d`,
  `CalendarMainView.vue` reads `event`).

### 4.5. Reminders

`remind_at` is one column per event, so no reminders table: the deadline
event reminds at -7 d, each milestone at -1 d.

## 5. Roadmap view

- **One row per spec dir**, every dir, never dropped. A dir with no
  `tasks.md` reads "no tasks.md".
- **Columns:** id, title, state, `[x]`/`[~]`/`[ ]` counts, pct, the goals it
  serves, the last commit date of its `tasks.md`.
- **Data:** `roadmap.json`, written at WUI generate time (5.2).
- **Filter:** this week / this month (5.3).

> **Amended by v1.1, section 12.6 (workspace filter).**
> **Extended by v1.3, section 13.4 (`/roadmap` timeline view with large milestone and epic cards, Quarter / Month / Week zoom, and create/edit in place).**

### 5.1. The done-% rule: ONE rule, one action

The two seats disagreed: s112-2 counts `[~]` as open, s112-3 counts it as
0.5. **v1.0 takes s112-2's rule:** `[~]` is open. Why:

- `../README.md` item 3 defines `[~]` as "Partial / in progress": it says
  nothing about how much. A 0.5 weight invents a precision nobody measured.
- Integer counts are reproduced by one `grep -c` per box kind, so anyone can
  audit a row in a minute.
- The goal's progress (6) is built on states, and both seats already agree
  that a spec with a `[~]` is not done. Counting it as open in the pct too
  keeps the pct and the state from contradicting each other.

The rule lives in ONE action, `do_spl_spec_progress` (csi-spl-orc). The
roadmap page, the goal page, `roadmap.json` and the hub sync all read its
output; nothing re-implements it.

- For each `csi-spl-doc/specs/[0-9][0-9][0-9]-*/`, count in `tasks.md` the
  lines `^\s*- \[[xX]\]` (x), `^\s*- \[~\]` (p) and `^\s*- \[ \]` (o).
- **States:**
  - `no-tasks`: no `tasks.md`.
  - `no-boxes`: a `tasks.md` with x + p + o = 0 (it uses another format, e.g.
    a task table).
  - `planned`: x = 0, p = 0, o > 0.
  - `done`: x > 0, p + o = 0.
  - `in-progress`: everything else.
- **pct** = floor(100 x / (x + p + o)); empty when x + p + o = 0.
- **Output:** TSV `spec state x p o pct` plus a one-line total that names the
  sha. `--sha <ref>` reads `git archive`, never the worktree. `--json` writes
  the shape `roadmap.json` uses.

### 5.2. Baseline (measured, not prose)

On `fecc09693`, n = 1, with this rule and spec 112 left out: **111 spec dirs,
89 `tasks.md`: 16 done, 59 in progress, 14 no-boxes, 0 planned, 22 no-tasks.**
The 14 rows that v0.2 and c-002 called "no ticks" are all no-boxes: each has
no checkbox line at all (026, 027, 029, 030, 032, 034, 040, 044, 093, 099,
100, 101, 102, 109). With spec 112 in (all `[ ]`), it adds 1 planned row.
v0.2's 16/58/14 was on `8c9766cd1`; c-002's
20/54/14 ignores `[~]` (specs 004, 014, 017 and 024 hold only `[x]` and
`[~]`). From v1.0 on, the baseline is whatever `do_spl_spec_progress` prints.

### 5.3. This week / this month

A spec row matches a window when (a) a goal it serves has a deadline or a
milestone inside the window, or (b) its `tasks.md` changed inside the window.
Windows are ISO weeks and calendar months in the viewer's time zone (the
spec 089 preference). The filter lives in the URL
(`/roadmap?when=week|month&goal=G01`), so a link reproduces it.

## 6. Tracking and the goal page

- **Goal progress** = the share of its linked specs in state `done` (5.1).
- **Mean pct** of its linked specs is shown next to it, because share-done
  reads 0 % for weeks while the work moves.
- **Goal page** (`/goals/<id>`): deadline countdown, approval state, the
  done-lines, the linked specs with their pct, links to the calendar events
  (4.4) and to `strategy.md`.

## 7. Retrospective

When a goal's deadline passes, its calendar event triggers a retrospective.

- **Content:** what was achieved against each done-line, what was not, and
  WHY, with evidence: specs done/open (from `do_spl_spec_progress --sha` at
  the deadline), lanes, reds and blockers, time lost.
- **Authoring:** mistral drafts; agy reviews the language last.
- **Two parts (D1):** the public part is
  `csi-spl-doc/goals/<id>-<slug>/retrospective.md` and passes the 111
  public-safe gate. Any owner quote or DB-derived evidence goes to the
  owner as a spool post, never to the repo.
- **Publishing:** posted to the owner via spool; it may be a blog post
  (spec 111) because the repo copy is already public-safe.

## 8. Past achievements backfill

The roadmap and the calendar are backfilled with past milestones so the
project's history is visible.

### 8.1. Backfill from git

- **The first event:** `2026-09-17 spool-hub started` (first commit
  `b588b50c2`, owner msg 757d45d9).
- **Sources:** `v*` tags, `refs/notes/release-notes` (and the
  `/releases/<sha>` pages), and specs whose state turned `done`.
- **"Major" rule:** a minor release (`x.y.0`), a spec turning done, or a
  first-of-its-kind milestone listed by hand in
  `csi-spl-doc/goals/milestones.yaml`. Not every patch tag.
- **Display:** past events in the calendar (kind `release` or `milestone`,
  audience `public`) and on the roadmap timeline, each linking to its release
  note.
- **Execution:** `do_spl_goals_backfill_git` builds the event list and calls
  the hub sync route (4.2). The first run backfills; every later run (each
  deploy) adds only new keys.

> **Amended by v1.1, section 12.7 (backfill per workspace).**

### 8.2. Backfill from DB discussions

- **Source:** hub topics with owner decisions ("go", "yes", answered
  questions), drills and launches.
- **Never `do_spl_db_query`:** that action sets
  `app.rls_scope = 'operator'` (`spl-db-query.func.sh` line 39), and the
  operator scope reads every workspace.
- **Own action `do_spl_goals_backfill_db`:**
  `: "${WORKSPACE:?WORKSPACE must be set (no default)}"`, then
  `BEGIN TRANSACTION READ ONLY` and `SET LOCAL app.tenant_id = '<WORKSPACE>'`
  with no rls_scope, as the per-env SA.
- **Output:** candidates in a 0600 file under `$HOME`, never in the repo.
  One candidate = `topic_id, msg_id, ts, kind, quote`; `quote` is at most 140
  chars of an owner message, and nothing else of any message text.
- **Process:** (1) the action proposes candidates; (2) an agent picks and
  words the major ones (mistral, agy last); (3) the approver role (D2) prunes
  the list; (4) the kept ones go through the sync route as `db:<topic_id>`
  keys, audience `internal` (4.3), visible only in that workspace.
- **Never public:** not in the repo, not on the blog, not on the spec 091
  public-dataset allow-list (11.1, s112-2 #3).
- **Frequency:** once, then incremental.

> **Amended by v1.1, section 12.7 (backfill per workspace).**

## 9. Rules and constraints

- **Distribution hygiene:** org-neutral, no personal names; roles, never
  people (D2).
- **i18n:** the chrome only. New strings (`roadmap.*`, `goal.*`) go into all
  19 locale files (`ls csi-spl-wui/i18n/locales | wc -l` -> 19); agy reviews
  them last (`LANE_MIX_KIND=i18n`). Goal titles, done-lines and spec titles
  are repo content, shown as authored and untranslated.
- **Theming:** dark and light.
- **Phone:** at <= 820 px roadmap rows become cards (the spec 106 breakpoint).
- **Performance:** zero bytes added to the initial chunk. `roadmap.vue` and
  `goals/[id].vue` are route chunks; heavy parts load through
  `defineAsyncComponent` (as `calendar.vue` does); no new client plugin and
  nothing imported from `app.vue`, a layout or a plugin. `roadmap.json` is
  fetched on mount, never `import`ed. The initial chunk stays within its
  budget in `specs/027-spool-performance/contracts/perf-budgets.json`, and a
  roadmap route budget of 25 KB gzip is added there.

## 10. Owner questions (answered)

**ANSWERED by the owner, msg 5a9aab48: "1. public 2. the cloud instance admin
- in this case me , for other cloud intances and DNS their owners ..."**, as
recorded in D1 and D2 (section 0). Q1 overrides the v0.2 recommendation.

- **Q1. Are strategy docs public by default, or internal only?**
  - **(a) Public by default, through the 111 public-safe gate; one doc may be
    internal (kept out of the repo). <- DECIDED (D1)**
  - (b) Internal by default, public by a frontmatter flag (v0.2
    recommendation; impossible as written, the repo is public).
- **Q2. Who approves a goal's deadline before it reaches the calendar?**
  - **(a) The cloud instance admin, a role per instance read from cnf/rbac:
    the owner here, each instance's own admin elsewhere. <- DECIDED (D2)**
  - (b) The owner by name, via a spool decision (v0.2 recommendation).

> **Amended by v1.1, section 12.3 (Q2 per workspace: biz_owner or admin).**

## 11. Review (one row per seat)

| seat | agent | verdict | changes asked | folded in |
|---|---|---|---|---|
| s112-2 | claude c-585 (data model + hub API + RLS) | **agree with changes** | Measured on `origin/master` `20e499b25` (the roadmap baseline also on `8c9766cd1`, the v0.2 commit), n = 1 per count. **1. Pin the roadmap baseline with ONE named action, `do_spl_spec_progress` (csi-spl-orc), and fix 5's number.** Definition: for each `csi-spl-doc/specs/[0-9][0-9][0-9]-*/` at one sha, count in `tasks.md` the lines `^\s*- \[[xX]\]` (x), `^\s*- \[~\]` (p) and `^\s*- \[ \]` (o). State: **no tasks** = no `tasks.md`; **no ticks** = x+p+o = 0; **done** = x > 0 and p+o = 0; **in progress** = everything else. Percent = floor(100·x/(x+p+o)). The output is TSV `spec state x p o pct` plus a one-line total that names the sha; `--sha <ref>` reads `git archive`, never the worktree. `[~]` counts as open because `../README.md` item 3 defines it as "Partial / in progress". The two counts: c-002 (`[x]` vs `[ ]`, `[~]` ignored) = **20 / 54 / 14**; this spec = **16 / 58 / 14**. Both are reproduced exactly on `8c9766cd1` with spec 112 itself left out (with it, 20/55/14 and 16/59/14 over 89 `tasks.md`). The 4-spec gap is `[~]`: 004, 014, 017 and 024 have only `[x]` and `[~]` and no `[ ]` (x/~ = 22/1, 13/1, 28/3, 9/1), so they are "done" under c-002's rule and "in progress" under this one. Also: 111 spec dirs and 89 `tasks.md` (`ls -d specs/[0-9][0-9][0-9]-* \| wc -l` -> 111), so 5 says "one row per spec" and 22 rows show **no tasks**, not missing. Test: a fixture tree with one spec per state, plus a `[~]`-only-open spec that must read in progress. **2. The data model: two new tables plus calendar columns, migration = the next free number** (`ls csi-spl-rdb/src/sql/postgres/spool-hub \| tail -1` -> `0155_mistral_kind.sql`; claim it at build time). Forward-only and additive, with RLS exactly in the 0125 shape (ENABLE + FORCE, `tenant_scope` with the `NULLIF` guard of 0021, `operator_scope`). (a) `goals(tenant_id FK tenants, goal_id text CHECK ~ '^G[0-9]{2}-[a-z0-9-]{1,48}$', title 1..200, owner_id 1..64, deadline date, done_lines jsonb array ≤ 16 KB, state CHECK IN ('draft','approved','met','missed','retired'), approved_msg_id text NULL, strategy_path text, source_sha text, synced_at timestamptz, PK (tenant_id, goal_id), CHECK (state = 'draft' OR approved_msg_id IS NOT NULL))`. That CHECK is 10 Q2 in the schema: no undecided deadline reaches the calendar. (b) `goal_links(tenant_id, goal_id, kind CHECK IN ('spec','lane','calendar_event','strategy','retrospective','release_note','topic'), target text 1..256, PK (tenant_id, goal_id, kind, target), FK (tenant_id, goal_id) -> goals ON DELETE CASCADE)`. (c) A milestone is NOT a third table but a `calendar_events` row: widen its `kind` CHECK with `'goal_deadline','milestone'` (`grep -n "kind IN" 0125_calendar.sql` -> the 7-value list has neither); add `source_key text NULL` with `UNIQUE (tenant_id, source_key) WHERE source_key IS NOT NULL` (`git:v1.2.0`, `spec:089`, `db:<topic_id>`, `goal:G01-…`), so every sync and backfill re-run is an upsert, never a duplicate. Register `goal_id` as a `props` key in the hub registry (0139: props keys live there). The existing `topic_id` and `release_version` columns carry the topic permalink and the release-note link, so no new link column is needed. **3. Workspace isolation is proven by the existing gates, made to cover the new tables.** `TestCrossTenantEveryTable` (`internal/store/crosstenant_test.go` line 369) fails for every tenant table that `seedTenantAll` does not seed, so the migration task seeds `goals` and `goal_links` there. `TestRLSPoliciesFailClosed` (`rls_failclosed_test.go` line 242) covers the policies. Both run on Postgres (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`). Add one assertion to `TestPublicExportGrantsEqualAllowList`: `goals`, `goal_links` and `calendar_events` never appear on the spec 091 allow-list (`grep -c calendar csi-spl-orc/cnf/public-dataset/allow-list.v1.yaml` -> 1, which is only `tenants.calendar_region`). The public blog (111) reads only repo files (`grep -c calendar csi-spl-doc/specs/111-blog/spec.md` -> 0), so these two fences are the whole DB path to the public. **4. Every synced or backfilled event sets `audience` explicitly; DB-derived ones are `internal`.** The 0125 column default is `'public'`, and `internal` is the audience the hub drops for a guest (`store/calendar.go` line 23). A DB-derived milestone left on the default would show to a workspace guest. The store refuses `source_key LIKE 'db:%'` with any audience but `internal`, and a store test covers it. **5. 8.2's "read-only as the per-env SA under RLS" must not reuse `do_spl_db_query`: that action takes the OPERATOR scope** (`grep -n rls_scope csi-spl-orc/src/bash/run/spl-db-query.func.sh` -> line 39, `SET LOCAL app.rls_scope = 'operator'`), and the operator scope reads every workspace. New action `do_spl_goals_backfill_db`: `: "${WORKSPACE:?WORKSPACE must be set (no default)}"`; `BEGIN TRANSACTION READ ONLY`; `SET LOCAL app.tenant_id = '<WORKSPACE>'` with no rls_scope. It writes the candidates to a 0600 file under `$HOME`, never in the repo. One candidate = `topic_id, msg_id, ts, kind, quote` with quote ≤ 140 chars from an owner message only, and nothing else of the message text. Test (`goals-backfill-db.tst.sh` on Postgres): two workspaces seeded; run in A; the output holds none of B's topic ids. CONTROL: B's rows are there, counted as the operator. **6. Writes go through the hub, never through SQL from a box.** Hub routes (new package `internal/goals`, store methods in `internal/store/goals{,_memory,_postgres}.go` with a memory/Postgres parity test): `GET /v1/goals`, `GET /v1/goals/{id}` (links + progress = done specs / linked specs, from change 1's states), `PUT /v1/goals/sync` (an idempotent bulk upsert by `source_key`, `creator_type = 'system'`, `creator_id = 'roadmap-sync'`, deploy identity only, 403 for a human or agent seat). Workspace: one cnf key `env.roadmap.tenant_id`, no literal and no default. The git backfill (8.1) and the deploy-time sync (4) both call that route; neither inserts rows itself. **7. The spec rows need no table.** The repo is public and identical for every workspace, so `do_spl_spec_progress --json` writes `roadmap.json` at WUI build time, like `build.json`. The DB holds only what is workspace-specific: goals, links and milestones. **8. 3, 7 and 10 Q1 meet a fact: the repo is PUBLIC** (`gh repo view csitea/csi-spl --json visibility` -> `PUBLIC`). A `strategy.md` or `retrospective.md` under `csi-spl-doc/goals/` is public the moment it is pushed, and a frontmatter `public: false` cannot change that. So: (a) Q1's "internal by default" holds only for text kept in the DB (a `goals.notes` field, or a repodocs page), not in the repo; (b) a retrospective that quotes owner text or DB-derived evidence (8.2) goes to the DB or the spool, never to the repo; (c) the repo copy passes the 111 4.4 public-safe check before the push. **9. Fix tasks.md paths and add the missing tasks.** `internal/calendar/roadmap_sync.go` names a package that does not exist (`ls csi-spl-api/src/go/spool-hub-api/internal \| grep -c '^calendar$'` -> 0); the calendar lives in `internal/store/calendar*.go` and `internal/hub/calendar*.go`. `csi-spl-wui/src/routes/roadmap/` does not exist either (`ls -d csi-spl-wui/src/routes` -> No such file); Nuxt uses `csi-spl-wui/src/pages/roadmap.vue`. `LinkedEntityId` matches nothing (`grep -rn LinkedEntityId csi-spl-api csi-spl-rdb \| wc -l` -> 0); use `source_key` + `props.goal_id` (change 2). New tasks: **RDB** migration (change 2, apply BEFORE the hub that reads it); **STORE** memory + Postgres + parity, with the gate seeding of change 3; **ORC** `do_spl_spec_progress` (change 1); the 4 and 5 store tests. | — |
| s112-3 | claude c-586 (WUI + calendar, specs 089/097/106) | **agree with changes** | Read on tree `20e499b25` (spec v0.2 from `8c9766cd1`). **1. One source of truth, links both ways, edits one way.** The repo (`csi-spl-doc/goals/<id>-<slug>/goal.yaml`: id, owner, deadline, milestones `[{key, date, title}]`, done-lines, specs) holds every goal date. The calendar holds a projection of it. "Two-way" means links in both directions, never edits in both: a synced event is read-only in the WUI (no edit or drag, and a "change it in the repo" link instead), and the hub refuses a PATCH or DELETE on it with 409. Otherwise the next deploy silently reverts a date the owner moved in the calendar. **2. Idempotent sync key, plus two new kinds.** Today no column can key a sync: the only unique key is `(tenant_id, event_id)` (`grep -n UNIQUE csi-spl-rdb/src/sql/postgres/spool-hub/0139_calendar_full_edit.sql` -> line 42). Add a migration with a partial unique index on `(tenant_id, (props->>'source_key'))`. Keys look like `goal:G01:deadline`, `goal:G01:m:<key>`, `release:v1.3.0`, `spec:089:done`. The sync upserts by key and soft-deletes (`deleted_at`) any key no longer in the repo. Add the kinds `goal` and `milestone` to the CHECK (`grep -n "kind IN" .../0125_calendar.sql` -> line 24, 7 kinds today, none for goals) and to `calendarKinds` (`internal/store/calendar.go` line 53). Past release milestones (8.1) keep kind `release` plus `release_version` (that CHECK already accepts `v1.3.0`, line 34), so the dialog's existing release link works unchanged. Events go to ONE tenant, the operator's, named in cnf `env.roadmap.tenant_id`, never to every tenant. **3. Fix the paths tasks.md names; two of them do not exist.** There is no `internal/calendar/` package (`ls csi-spl-api/src/go/spool-hub-api/internal \| grep -c '^calendar$'` -> 0): the calendar lives in `internal/store/calendar*.go` and the hub handlers. `LinkedEntityId` does not exist either (`grep -rn LinkedEntity csi-spl-api/src/go \| wc -l` -> 0), so use `props.source_key` and `props.roadmap_url`. The WUI is Nuxt pages, not `src/routes/` (`ls csi-spl-wui/src/routes` -> no such dir). The WUI task owns `csi-spl-wui/src/pages/roadmap.vue`, `src/pages/goals/[id].vue` and their `src/components/Roadmap*.vue`. **4. Build the roadmap from the repo at generate time, not through a goals API.** A node step `csi-spl-wui/src/node/roadmap/sync-roadmap.mjs` (a sibling of `src/node/help`, `src/node/i18n`) runs before `nuxt generate`. It writes `public/roadmap.json`, with one row per spec dir: id, title, state, counts of `[x]`/`[~]`/`[ ]`, pct, the goals it serves and the last commit date of its `tasks.md`. It also writes one row per goal from `goal.yaml`. The WUI fetches the file and the hub sync (wf 20) reads the SAME file, so one parser serves both. The "API: Data model and hub API for Goals" task shrinks to that sync, with no goals table: the repo is the store. **5. Define % ticked and the state, and count every spec.** pct = (`[x]` + 0.5 x `[~]`) / all boxes. Done = every box `[x]`. Planned = no `[x]` and no `[~]`. Anything else is in progress. The v0.2 rule counts only `[x]` vs `[ ]`, yet 16 of the 89 `tasks.md` use `[~]` (the README vocabulary). Re-measured on `20e499b25` with a `grep -cE '^\s*- \[(x\| \|~)\]'` loop over `csi-spl-doc/specs/*/tasks.md`, n = 89 files: 16 done, 58 in progress, 15 with no `[x]` (v0.2 says 88 / 14, because specs landed since). There are 111 spec dirs (`ls -d csi-spl-doc/specs/*/ \| wc -l`), so 22 have no `tasks.md`. They get a row reading "no tasks.md" and are never dropped. The baseline in 5 should come from the script output, not from prose. **6. Pin the this-week / this-month filter.** A spec row matches a window when (a) a goal it serves has a deadline or milestone event inside the window, or (b) its `tasks.md` changed inside the window. Windows are ISO weeks and calendar months in the viewer's time zone (the preference spec 089 already uses). The filter lives in the URL (`/roadmap?when=week\|month&goal=G01`), so a link reproduces it. **7. Concrete links both ways, reusing the deep link that exists.** Each synced event carries `props.roadmap_url` = `/roadmap?goal=G01#spec-089` plus the strategy-doc link (the `repoWebUrl` + help-path pattern; empty cnf hides it). A roadmap row and the goal page link to `/calendar?d=<iso>&event=<id>`, which already opens an event (`calendar.vue` line 55 reads `d`, `CalendarMainView.vue` lines 402-403 read `event`). To get the id, the hub's event list takes a `source_key` prefix filter (`goal:G01:`), so the WUI never guesses it. **8. Lazy loading: zero bytes added to the initial chunk.** `roadmap.vue` and `goals/[id].vue` are route chunks only. Their heavy parts load through `defineAsyncComponent`, as `calendar.vue` lines 45-47 do. There is no new client plugin, and nothing is imported from `app.vue`, a layout or a plugin. `roadmap.json` is fetched on mount, never `import`ed, because an imported JSON is inlined into the chunk. Gate before push: `perf-budget.py bundle` keeps `ci_initial_gzip_kb` at or under 155 on the lane's own generate output. Add a route budget for the roadmap chunk (25 KB gzip) to `specs/027-spool-performance/contracts/perf-budgets.json`. The WUI tasks depend on c-579's fix landing, because trunk reads 155.1 today. **9. i18n: translate the chrome only, and agy reviews it last.** The new UI strings (`roadmap.*`, `goal.*`) go into all 19 locale files (`ls csi-spl-wui/i18n/locales \| wc -l` -> 19), and agy reviews them as the final step (`LANE_MIX_KIND=i18n`). Goal titles, done-lines and spec titles are repo content and are shown as authored, untranslated. Otherwise each goal edit costs 19 translations and an agy pass. **10. Narrow the reminders and test the views on phone, both themes and the mock.** `remind_at` is one column per event (`internal/store/calendar.go` `RemindAt`). So the "reminders leading up" in 4 are: the deadline event at -7 d, each milestone at -1 d, and no new reminders table. At <= 820 px the roadmap rows become cards, the spec 106 breakpoint. The WUI task's Test adds e2e on the mock bundle (the CI e2e is mock-only), with a fixture `roadmap.json`, at both widths and in both themes, and a control that a synced event shows no edit button. **Goal page (6):** shows the deadline countdown, the done-lines and the linked specs with their pct. It shows share-done (6) AND mean pct, because share-done reads 0 % for weeks while the work moves. | |

### 11.1. Fold record (v1.0, c-604)

The seat rows above are kept as written. This table records, per change asked,
where v1.0 folds it, or why not.

| seat | change | v1.0 |
|---|---|---|
| s112-2 | 1 `do_spl_spec_progress`, `[~]` = open | folded: 5.1, 5.2 (re-measured on `fecc09693`; the 14 "no ticks" are no-boxes files, so that state is named `no-boxes`); ORC-1 |
| s112-2 | 2a/2b `goals` + `goal_links` tables | **not folded:** the repo is the one store of goals (s112-3 #1/#4; D1 makes the repo copy public anyway), so a table would be a second copy to drift; approval is checked by the sync (D2) instead of a CHECK |
| s112-2 | 2c milestones as `calendar_events` rows, `source_key` + partial unique, new kinds | folded: 4.2, as a real column (not a `props` key) so the 4.3 store check and the index are plain SQL; kinds named `goal`/`milestone` per s112-3; RDB-1 |
| s112-2 | 3 cross-tenant + fail-closed gates, allow-list assertion | folded in part: no new table to seed; the `TestPublicExportGrantsEqualAllowList` assertion (`calendar_events` never on the 091 allow-list) is STORE-1 |
| s112-2 | 4 explicit `audience`, `db:` = `internal`, store refuses | folded: 4.3; STORE-1 |
| s112-2 | 5 own tenant-scoped DB backfill action | folded: 8.2; ORC-3 |
| s112-2 | 6 writes through the hub, deploy identity only | folded: 4.2 `PUT /v1/calendar/sync`; `GET /v1/goals{,/id}` **not folded**: `roadmap.json` (s112-2 #7) already serves the read, so a goals API would be a second parser |
| s112-2 | 7 spec rows need no table, `roadmap.json` at build | folded: 5, 5.1; WUI-1 |
| s112-2 | 8 the repo is public | folded: D1, 3, 7 |
| s112-2 | 9 fix tasks.md paths, add RDB/STORE/ORC tasks | folded: tasks.md v1.0 |
| s112-3 | 1 repo = one truth, synced events read-only, 409 | folded: 4.1; HUB-1, WUI-2 |
| s112-3 | 2 sync key + kinds `goal`/`milestone`, soft-delete, one workspace | folded: 4.2 (column, not `props->>`, see s112-2 2c) |
| s112-3 | 3 fix the paths | folded: tasks.md v1.0 |
| s112-3 | 4 `roadmap.json` at generate time, no goals table | folded: 5; the node step calls `do_spl_spec_progress --json` for the counts instead of a second parser (5.1) |
| s112-3 | 5 pct with `[~]` = 0.5 | **not folded:** one rule is needed and v1.0 takes s112-2's (`[~]` = open), reasons in 5.1; the "count every spec, never drop one" part is folded (5) |
| s112-3 | 6 week/month filter in the URL | folded: 5.3 |
| s112-3 | 7 links both ways, `/calendar?d=&event=`, `source_key` prefix filter | folded: 4.4, 4.2 |
| s112-3 | 8 zero initial-chunk bytes, 25 KB route budget | folded: 9 |
| s112-3 | 9 i18n chrome only, 19 locales, agy last | folded: 9; I18N-1 |
| s112-3 | 10 reminders -7 d / -1 d, phone cards, e2e on mock both themes; goal page share-done + mean pct | folded: 4.5, 9, 6; WUI-1, WUI-2 |

| s112-4 | mistral | **agree with changes** | **1.** Strategy-doc template: Add `public: false` (default) frontmatter field to enforce internal-only visibility until explicitly marked safe for public release. **2.** Strategy-doc template: Include a `reviewers` array in frontmatter to track agy's language review status (e.g., `reviewers: [agy]`). **3.** Retrospective: Define a mandatory structure: `## Achieved`, `## Missed`, `## Why` (with subsections `Evidence`, `Blockers`, `Time Lost`). **4.** Retrospective: Require a `data_sources` frontmatter field listing evidence sources (e.g., `specs: [089, 106]`, `lanes: [c-585, c-586]`, `topics: [4e373f5d]`). **5.** Major milestones rule: Clarify "first-of-its-kind technical milestone" with examples (e.g., "first RLS implementation", "first calendar sync"). **6.** Major milestones rule: Explicitly exclude patch releases (e.g., `v1.2.1`) unless they introduce a breaking change or a spec marked done. **7.** Git backfill: Add a `backfill_start_sha` frontmatter field to `csi-spl-doc/goals/backfill-config.yaml` to pin the starting commit (e.g., `b588b50c2`). **8.** DB backfill: Limit owner quotes to 140 chars and require a `source_msg_id` field to link back to the original spool message. |

#### 11.1.1. Addendum fold: seat s112-4 (m-587)

The s112-4 row above is kept as written. Its 8 changes are folded into v1.0
as below; change 1 is folded against D1 (owner, msg 5a9aab48), so the default
is the opposite of what the row asked.

1. **`public` frontmatter field, default `true`** (D1), in
   `template-strategy.md` and `template-goal.yaml`; `public: false` is the
   per-doc override for an internal-only doc (kept out of the repo, D1).
2. **`reviewers` array** in the strategy-doc frontmatter, recording agy's
   language review (e.g. `reviewers: [agy]`).
3. **Retrospective structure:** `## Achieved`, `## Missed`, `## Why`, the
   last with the subsections `Evidence`, `Blockers` and `Time Lost`.
4. **`data_sources` frontmatter field** in the retrospective, listing the
   evidence (e.g. `specs: [089, 106]`, `lanes: [c-585, c-586]`,
   `topics: [4e373f5d]`).
5. **First-of-its-kind milestone examples** for the 8.1 rule: "first RLS
   implementation", "first calendar sync".
6. **Patch releases excluded** (e.g. `v1.2.1`) unless they introduce a
   breaking change or turn a spec done.
7. **`backfill_start_sha`** pins the git backfill's starting commit (e.g.
   `b588b50c2`).
8. **DB backfill owner quotes <= 140 chars**, each with a `source_msg_id`
   linking back to the spool message.

## 12. v1.1 amendment: per-workspace roadmaps (2026-10-09)

v1.1 adds this section to v1.0 and changes nothing else. Every v1.0 section
stays. Where one conflicts with v1.1, it carries an "Amended by v1.1, section
12.N" line, and section 12.N wins. The amendment was drafted by m-689
(`01aafa3a5`, whose text replaced v1.0 by mistake); c-644 restored v1.0 from
`01aafa3a5^` and folded the amendment in here.

### 12.1. Owner decisions (verbatim, HUM-10, t1 topic 4e373f5d)

| msg | text |
|---|---|
| **4fc63469** | **DECIDED**: "mm every workspace should be possible to have its own roadmap" |
| **26477898** | **DECIDED**: "both biz_owner and admin can do th eapproaval of he goals , not only the one or the another" |

### 12.2. One roadmap per workspace

- Every workspace can have its own roadmap: its own goals, milestones and
  goal calendar events, in that workspace only.
- **`env.roadmap.tenant_id` is deprecated.** It no longer names the one
  workspace that receives events (4.1). The workspace of a goal comes from the
  goal itself (12.4). A workspace with no repo keeps its goals as goal
  documents inside the app (OQ1 DECIDED, msg 730f6f90, 12.8).

### 12.3. Who approves a goal (per workspace)

- A goal is approved by a member who holds **`biz_owner` or `admin`** in the
  goal's own workspace (`internal/rbac/rbac.go` `RoleIDs`). Either role is
  enough; the owner said "not only the one or the another".
- This replaces the single cnf role of D2 for workspace goals:
  `env.roadmap.approver_role` is deprecated together with
  `env.roadmap.tenant_id`. The rest of D2 holds: an approval is a message id
  (`approval.msg_id`), the sync checks that its author holds one of the two
  roles in that workspace, and an unapproved goal writes no event.
- Roles, never names (hygiene rule 5).

### 12.4. Hub sync over several workspaces

- `PUT /v1/calendar/sync` (4.2) takes events for more than one workspace in
  one deploy. Each event names its workspace; the upsert key stays
  `(tenant_id, source_key)`, so the same `goal:G01:deadline` in two workspaces
  is two events and never collides.
- Unchanged: deploy identity only (403 for a seat), idempotent upsert,
  soft-delete of a key no longer in the source, the 409 on a synced event.

### 12.5. Visibility of a workspace roadmap

- Recommended by m-689, decided by the owner as OQ3 (12.8): a workspace
  roadmap is **internal by default** (members of that workspace only), with a
  per-roadmap override to **public**.
- Not changed: D1 for the strategy docs in the public repo, and 4.3's rule
  that a `db:` event is always `internal`.

### 12.6. Workspace filter in the WUI

- The roadmap page (5) gets a workspace filter. It lists only the workspaces
  the viewer may see (member, or a public roadmap) and lives in the URL next to
  `when` and `goal` (5.3), so a link reproduces it.

### 12.7. Backfill per workspace

- `do_spl_goals_backfill_git` (8.1) and `do_spl_goals_backfill_db` (8.2) take
  the target workspace and fail fast without it
  (`: "${WORKSPACE:?WORKSPACE must be set (no default)}"`); neither has a
  default workspace.
- 8.2's isolation rules are unchanged: read-only, tenant-scoped, never
  `do_spl_db_query`, candidates under `$HOME`, `db:` events `internal`.

### 12.8. Owner questions (answered in v1.2)

Asked in m-689's report (msgs be337c39, d56cb583); the recommendation is
m-689's. The owner answered all three in HUM-10, t1 4e373f5d, msg 730f6f90:
"Proceed according to your suggestions."

- **OQ1. Where do a workspace's goals live if the workspace has no repo?**
  Recommended: in-app goal docs (e.g. workspace repodocs or a dedicated goals
  section).
  **DECIDED** (msg 730f6f90, "Proceed according to your suggestions."): a workspace with no git repo keeps its
  goals as goal documents inside the app.
- **OQ2. What happens to the spool roadmap (this instance's own roadmap)?**
  Recommended: it becomes just another workspace roadmap, with no special
  status.
  **DECIDED** (msg 730f6f90, "Proceed according to your suggestions."): the spool's own roadmap is just another
  workspace roadmap, with no special case.
- **OQ3. Are workspace roadmaps public or internal by default?**
  Recommended: internal by default, with an override for public (12.5).
  **DECIDED** (msg 730f6f90, "Proceed according to your suggestions."): workspace roadmaps are internal by
  default, with a per-workspace switch to make one public.

### 12.9. Tasks

`tasks.md` is not changed by v1.1. OQ1-OQ3 are answered (msg 730f6f90); the
build tasks for 12.2-12.7 come from a later lane.

## 13. v1.3 amendment: milestones as records, epic dates and roll-up, and the /roadmap timeline (2026-11-25)

v1.3 adds this section to v1.2 and changes no existing rule of sections 1-12
except where noted below. All file:line citations in this section were measured
on `origin/master` `d7d502c0c` / `2924c633f` (and the prd database on
`2026-11-25T02:24Z`). Issue: **SPL-6452**. Epic: **SPL-2396**. Discussion:
`topic:7653cb85-3382-459f-b6e1-feda580bf9c5` (`t1`).

### 13.1. Owner words and decision (verbatim, HUM-10, t1 topic 7653cb85, 2026-11-24)

| msg | text |
|---|---|
| `eedec517` | "we need to be able to handle better milestones and epics" |
| `d16e58d6` | "like now we are going fast in the forest , but we need to have the capability to go up on the mountain and see the big picture , figuratively speeking ..." |
| `c5983964` | "an dwe do not have yet the technical means for that" |
| `da603f20` | "that is we can hande issues programatically and via the ui , but milestones , epics , timetables , not" |
| `adb74684` | "we do have calendar though ..." |
| `fc03882b` | "so we do have quite a lot of tools on hand to be able to create the nesseary ui and tooling for thise milestones and epics handling" |
| **`820187c1`** | **DECIDED** (form `305cba14`): **A — Milestones as records + epic dates/roll-up + a timeline on /roadmap, editable in UI and CLI** |
| `ec8e44c2` | "it should have a bit differnet inteface as the big things will not be as much as all ofhte other - the issues , the topics etc." |

### 13.2. What exists today (measured on origin/master d7d502c0c / 2924c633f and prd)

| piece | what exists today | evidence (`file:line`) |
|---|---|---|
| Issues schema | `issues` base table holds `parent_number`, `deadline` (`timestamptz NULL`); later migrations added `kind` (`epic \| feature \| issue`), `priority` (`1..5`), `status` (`eval\|todo\|wip\|diss\|blocked\|onhold\|qas\|done`), `level` (`1 \| 2 \| 3`), `deleted_at`, `archived_at`, `spec_path`, `spec_task_id`. No `start_date`, no `end_date`, no `milestone_id`. | `csi-spl-rdb/src/sql/postgres/spool-hub/0047_issues.sql:44-75`, `0053_issue_kinds.sql:16-17`, `0055_issue_prio_status.sql`, `0056_issue_level_tree.sql:26`, `0061_issue_blocked_onhold.sql`, `0071_issue_soft_delete.sql`, `0085_issue_archive.sql`, `0207_issue_spec_attributes.sql:24-31`; highest migration on disk is `0323_fleet_ask_queue_order.sql`. |
| Epics in prd (`t1` and estate) | Live non-deleted level-1 rows in `t1` (`2026-11-25T02:24Z`): 117 `epic` (40 `wip`, 59 `done`, 9 `diss`, 7 `eval`, 2 `todo`) and 2 `feature` (`done`). Across all prd workspaces, 2 level-1 epic rows currently carry a non-null `deadline` (1 in `t1`, 1 in another workspace). | Read-only queries on prd `issues` (`2026-11-25T02:24Z`). |
| Epic roll-up | `epicSummaries(all)` computes `total`, `done`, `canceled`, `counts` over direct children (`e := by[i.Parent]`) only, emitted solely inside `GET /v1/view/issues`'s `epics` array; `GET /v1/view/issues/{ref}` and `issueJSON` carry no roll-up, no dates, and no next-due field. `ListIssues` / `ListIssueSheet` omit `archived_at IS NOT NULL`, while `ClosesEpic` archives a closed epic and its descendants together (and `ArchiveIssue` can also archive a single issue under an open epic). | `csi-spl-api/src/go/spool-hub-api/internal/hub/issues.go:42-76`, `:808`, `:822-876`, `:919-948`; `internal/store/issues.go:177-188,425`; `internal/store/issues_postgres.go:383-416`. |
| Epics in WUI | `IssueEpicsPanel.vue` is a narrow side list inside the Issues tab showing title, `done/(total-canceled)` and a 3 px bar (`epicProgress`, using `Math.round`). No timeline, no dates, no overview screen. | `csi-spl-wui/src/components/IssueEpicsPanel.vue:1-97`; `csi-spl-wui/src/utils/issues-view.mjs:303-306`. |
| Goals in WUI & hub | `/roadmap` renders `RoadmapGoals.vue` (`RoadmapGoalTable.vue`, `RoadmapWorkspaceFilter.vue`) above `RoadmapSpecTable.vue`, plus `/goals/[id].vue`. Goals come from `goal.yaml` (`do_spl_goals_sync`) or in-app goal docs (`PUT /v1/workspace/doctree/{doc}/goal`), read via `GET /v1/calendar/events?source_key=goal:`. No UI create/edit for goals or milestones, and `/roadmap` has no left-rail tab yet (`auth.RailTabs` + `rail-order.ts`). | `csi-spl-wui/src/pages/roadmap.vue:16-107`, `pages/goals/[id].vue:11-133`, `components/RoadmapGoals.vue:8-48`, `utils/roadmap-goals-api.mjs:32-44`, `utils/rail-order.ts:16,60-117`; `internal/auth/handler.go:1022-1033`; `internal/hub/roadmap_goal_docs.go:166-243`. |
| Milestones today | No `milestones` table, no hub route, no CLI verb, no WUI CRUD. Only `csi-spl-doc/goals/milestones.yaml` (1 live line: `2026-09-17 spool-hub started`) read by `do_spl_goals_backfill_git`, plus inline `goal.yaml` `milestones[]` synced as read-only `calendar_events` rows (`source_key = goal:<Gnn>:m:<key>`). | `csi-spl-doc/goals/milestones.yaml:1-10`; `csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh:70,88`; `internal/hub/roadmap_goal_docs.go:155-162`. |
| Calendar & read-only projection | `GET /v1/calendar/events` and `GET /v1/calendar/marks` already synthesize read-only `source: "issue"` items from `issues.deadline` (`deadlinesIn`, assignee/creator-only per SPL-5963) without copying them into `calendar_events`. Spec 089 defines `audience: "internal"` as signed-in members/agents only (never guest or demo). Calendar WUI renders `calDeadline` and `calSynced` read-only (`CalendarEventPopover.vue`, `CalendarPhonePeek.vue`). Google Calendar sync (spec 149) reads `calendar_events` only. | `internal/hub/calendar.go:63-66`, `:193-200`, `:631-664`, `:727-762`, `:822-855`; `csi-spl-doc/specs/089-calendar-section/spec.md:138,215,260`; `csi-spl-wui/src/utils/calendar-event-form.mjs:156-187`; `components/CalendarEventPopover.vue:47-62,80-84`; `components/CalendarPhonePeek.vue:148,176`; `csi-spl-rdb/src/sql/postgres/spool-hub/0217_google_calendar.sql:1-25`. |
| RBAC & CLI for issues | Browser issue reads use `viewHandler` (`topics.read`); writes use `issueWriter` (`notes.send` + `topics.manage` + `billing.AllowsWrite`); delete/archive uses `mayDeleteIssue` (creator or `tenant.settings`). Agents use `spool issue <op> --as <AGENT>` -> `action.Issue` -> one-shot `role=cli` WebSocket frame `wire.TIssue` -> `onIssue` (`senderRefusal` + billing; creator for delete). | `internal/hub/view.go:126-153`; `internal/hub/issues.go:880-901`, `:951-972`, `:1023-1028`; `internal/hub/issues_agent.go:29-99`, `:166-192`; `cmd/spool/issue.go:17-58`; `internal/action/issue.go:26-53`; `internal/hubclient/issue.go:23-42`; `internal/wire/wire.go:45,426-431`; `internal/mcp/mcp.go:183`. |
| Performance & i18n gates | `ci_initial_gzip_kb` ceiling `155.0 KB` (measured `151.9 KB` after SPL-6342); `ci_roadmap_route_gzip_kb` ceiling `25.0 KB` (measured `3.0 KB`, markers `"roadmap-page"` and `"roadmap-spec-table"`). `initial_names()` reads first-paint chunks from `200.html`. WUI has 19 locale files (`en.json` + 18). | `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json:4,10,27,43`; `csi-spl-orc/src/bash/scripts/perf-budget.py:86,178`; `csi-spl-wui/i18n/locales/*.json` (19 files). |

### 13.3. Data model: milestones as records, epic dates, computed roll-up and hierarchy

#### 13.3.1. Forward-only migration (`RDB-3`)

Claim the next migration number at build time with
`cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next`
(`csi-spl-orc/src/bash/run/rdb-migration-next.func.sh:27`; highest on disk on
`2924c633f` is `0323_fleet_ask_queue_order.sql`). The file
`csi-spl-rdb/src/sql/postgres/spool-hub/<next>_milestones_and_epic_dates.sql`
is forward-only, additive, and deploys to `dev` and `prd` **before** any hub
image that reads or writes its objects. Because `issues` carries deferred
triggers from rdb 0194, the migration opens with
`SET CONSTRAINTS ALL IMMEDIATE; SET LOCAL lock_timeout = '5s';`
(`0207_issue_spec_attributes.sql:21-22`).

1. **Table `milestones`** (workspace-scoped, no `channel_id` column):
   - `milestone_id uuid PRIMARY KEY DEFAULT gen_random_uuid()`
   - `tenant_id text NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE`
   - `title text NOT NULL CHECK (length(title) BETWEEN 1 AND 200)`
   - `description text NOT NULL DEFAULT '' CHECK (length(description) <= 4000)`
   - `target_date date NOT NULL` (calendar day `YYYY-MM-DD`, matching goal dates in `roadmap_goal_docs.go:90-96`)
   - `status text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'active', 'reached', 'canceled'))` — **no stored `missed` state** (N4): overdue/missed is derived on read (`status IN ('planned', 'active') AND target_date < current_date` in UTC, returned as `overdue: true`) so it can never go stale.
   - `goal_id text NOT NULL DEFAULT '' CHECK (goal_id = '' OR goal_id ~ '^G[0-9]{2}$')` (optional link to a goal of the same workspace, matching `GOAL_ID` in `roadmap-goals.mjs:23`)
   - `reached_at timestamptz NULL` (stamped when `status` enters `reached`, cleared when it leaves)
   - `created_by text NOT NULL CHECK (length(created_by) BETWEEN 1 AND 64)`
   - `created_at timestamptz NOT NULL DEFAULT now()`
   - `updated_by text NOT NULL CHECK (length(updated_by) BETWEEN 1 AND 64)`
   - `updated_at timestamptz NOT NULL DEFAULT now()`
   - `deleted_at timestamptz NULL`, `deleted_by text NULL` (soft delete, matching `issues` rdb 0071 and `calendar_events` rdb 0139)
   - `UNIQUE (tenant_id, milestone_id)` (supports the same-tenant composite FK from `issues`)
   - Indexes:
     - `milestones_tenant_date ON milestones (tenant_id, target_date) WHERE deleted_at IS NULL`
     - `milestones_tenant_goal ON milestones (tenant_id, goal_id) WHERE goal_id <> '' AND deleted_at IS NULL`
   - **RLS (fail-closed, 0021/0125 shape):** `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY`, `tenant_scope` (`tenant_id = NULLIF(current_setting('app.tenant_id', true), '')`) and `operator_scope` (`current_setting('app.rls_scope', true) = 'operator'`).
   - **Gates:** seed `milestones` in `seedTenantAll` (`internal/store/crosstenant_test.go:30`) so `TestCrossTenantEveryTable` (`:925`) and `TestRLSPoliciesFailClosed` (`rls_failclosed_test.go:252`) cover it. Assert in `TestPublicExportGrantsEqualAllowList` (`public_export_grants_test.go:185`) that `milestones` is absent from `csi-spl-orc/cnf/public-dataset/allow-list.v1.yaml`.

2. **Additions to `issues`** (all nullable, additive; single end date per epic — W2):
   - `start_date date NULL`
   - `end_date date NULL`
   - `milestone_id uuid NULL`
   - **One-time backfill of existing epic `deadline` rows** (2 rows measured across prd on `2026-11-25T02:24Z`):
     `UPDATE issues SET end_date = (deadline AT TIME ZONE 'UTC')::date, deadline = NULL WHERE kind IN ('epic', 'feature') AND deadline IS NOT NULL;`
   - Constraints:
     - `CONSTRAINT issues_date_range_check CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date)`
     - `CONSTRAINT issues_epic_dates_check CHECK ((start_date IS NULL AND end_date IS NULL) OR kind IN ('epic', 'feature'))`
     - `CONSTRAINT issues_epic_no_deadline_check CHECK (deadline IS NULL OR kind = 'issue')` — **epics and features have ONE due/end date (`end_date`), never a second `deadline`**, eliminating duplicate calendar markers and `next_due` ambiguity; level-2/3 issues keep timed `deadline` (`0047_issues.sql:61`).
     - `CONSTRAINT issues_milestone_epic_check CHECK (milestone_id IS NULL OR kind IN ('epic', 'feature'))`
     - `CONSTRAINT issues_milestone_fkey FOREIGN KEY (tenant_id, milestone_id) REFERENCES milestones (tenant_id, milestone_id) ON DELETE SET NULL (milestone_id)` (PostgreSQL 16 column-list `SET NULL`, preventing cross-tenant linkage at the DB level; default choice, see Q1).
   - Partial indexes:
     - `issues_epic_dates_idx ON issues (tenant_id, start_date, end_date) WHERE kind IN ('epic', 'feature') AND deleted_at IS NULL AND (start_date IS NOT NULL OR end_date IS NOT NULL)`
     - `issues_milestone_idx ON issues (tenant_id, milestone_id) WHERE milestone_id IS NOT NULL AND deleted_at IS NULL`

#### 13.3.2. Computed roll-up (never stored twice; one rule everywhere — W1)

No progress counter is stored on `issues` or `milestones`. Every read
(`GET /v1/view/issues`, `GET /v1/view/issues/{ref}`, `GET /v1/milestones`,
`GET /v1/milestones/{id}`, and `GET /v1/roadmap/timeline`) uses **one shared
roll-up rule** so `IssueEpicsPanel.vue` and `/roadmap` always show the exact
same numbers and percentage:

- **Epic roll-up** (for any `kind IN ('epic', 'feature')`):
  - **Scope of children:** direct level-2 issues (`parent_number = epic.number`, `deleted_at IS NULL`) — default choice (see Q3), matching `IssueEpicsPanel.vue:31` and `epicSummaries` (`internal/hub/issues.go:850-863`).
  - **Archived children rule (W1b):**
    - For a **live (non-archived) epic** (`epic.archived_at IS NULL`): count **only live non-archived children** (`deleted_at IS NULL AND archived_at IS NULL`). A single issue archived on its own (`ArchiveIssue`, `internal/store/issues.go:425`) drops out of both `IssueEpicsPanel.vue` and `/roadmap` identically.
    - For a **closed / archived epic** (`epic.archived_at IS NOT NULL`, e.g. closed and archived together with its descendants by `ClosesEpic`, `internal/store/issues.go:177-188`): include its non-deleted archived direct children (`deleted_at IS NULL`) so finishing an epic preserves its completed counts on its parent milestone and on `/roadmap` when closed epics are shown.
    - `GET /v1/view/issues/{ref}`'s `rollup` field (`HUB-5`) calls this exact same function (for a live epic read, live non-archived direct children).
  - **Rounding rule (W1a):** **round half up** — in Go `(done*100 + active/2) / active` (`active = total - canceled`), identical to `Math.round((done * 100) / active)` in `epicProgress` (`csi-spl-wui/src/utils/issues-view.mjs:303-306`), or `0` when `active = 0`. Example: `2 / 3` reads `67%` in both `IssueEpicsPanel.vue` and `/roadmap`.
  - **Fields:** `total`, `done` (`status = 'done'`), `canceled` (`status = 'diss'`), `open` (`total - done - canceled`), `active_total` (`total - canceled`), `pct`, and **`next_due`**: `{kind: "issue" | "epic_end", key, title, date}` = the earliest non-closed (`status NOT IN ('done', 'diss')`) live child's `deadline` (UTC date), else the epic's own `end_date`, else `null`.
- **Milestone roll-up** (computed over its linked non-deleted epics, including closed/archived linked epics per the rule above):
  - `epics_total`, `epics_done` (linked epics with `status = 'done'`), `epics_open` (linked epics not in `done`/`diss`),
  - `issues_total`, `issues_done`, `issues_canceled` (summed across linked epics using each epic's roll-up above),
  - `pct` = round half up of `100 * issues_done / (issues_total - issues_canceled)` when `issues_total - issues_canceled > 0`, else round half up of `100 * epics_done / epics_total` when `epics_total > 0`, else `0`,
  - `overdue` (derived boolean, N4): `status IN ('planned', 'active') AND target_date < current_date` (UTC),
  - `next_due`: earliest upcoming `end_date` (or child `deadline`) among its open linked epics, else `{kind: "milestone", key: milestone_id, title, date: target_date}`.

#### 13.3.3. Hierarchy and coexistence with existing goal/milestone files

```text
Goal (goal.yaml in git OR spec 113 in-app goal doc; id G<nn>)
  └── Milestone (milestones table; optional goal_id = G<nn>, workspace-scoped)
        └── Epic / Feature (issues table; kind IN ('epic','feature'), level = 1,
                            start_date, end_date, optional milestone_id)
              └── Issue (issues table; kind = 'issue', level = 2, parent_number = epic.number)
                    └── Subtask (issues table; kind = 'issue', level = 3, parent_number = issue.number)
```

- Every link stays optional above `Issue`: a milestone may stand without a goal (`goal_id = ''`), an epic may stand without a milestone (`milestone_id IS NULL`), and an issue may stand without an epic (W16, `internal/store/issues.go:103-106`).
- **Dangling `goal_id` (N6):** because goals live in git (`goal.yaml`) or workspace doctree docs and can be renamed or removed independently, `milestones.goal_id` is syntax-checked (`^G[0-9]{2}$`) without a DB foreign key. If no matching goal event exists at read time, the hub returns `goal_id` unchanged without error and the WUI renders a plain muted badge (`G01`) with no broken link.
- **Coexistence with `goal.yaml` milestones and `milestones.yaml` (W6):** existing `goal.yaml` / in-app goal inline `milestones: [{key, date, title}]` (section 2, `roadmap_goal_docs.go:74,155-162`) keep syncing to `calendar_events` as read-only `goal:<Gnn>:m:<key>` rows. `csi-spl-doc/goals/milestones.yaml` (`spl-goals-backfill-git.func.sh:70`) remains historical git-backfill input only. Editable workspace milestones live exclusively in the `milestones` table; section 13.4.2 and section 13.6 define how both milestone kinds appear distinctly on `/roadmap` and in Calendar.

### 13.4. Interface on `/roadmap` (per owner `ec8e44c2`)

Owner `ec8e44c2`: *"it should have a bit differnet inteface as the big things
will not be as much as all ofhte other - the issues , the topics etc."*

Issues (5,000+ rows) and Topics (high-frequency message streams) optimize for
row density and rapid triage. Milestones (typically 3-15 active per workspace)
and active epics (40 `wip` in `t1` on `2026-11-25T02:24Z`, only a subset active
on any horizon) are few and strategic. Their screen on `/roadmap` therefore
uses **spacious, high-signal cards on a visual timeline**, not another compact
data table.

#### 13.4.1. Page structure, URL state and navigation

- `/roadmap` keeps its existing workspace filter (`RoadmapWorkspaceFilter.vue`,
  `?ws=<slug>`) and adds a top mode switcher: **Timeline** (default for
  signed-in members) and **Goals & Specs** (the existing `RoadmapGoals.vue` +
  `RoadmapSpecTable.vue` built in WUI-1/WUI-3, URL `?tab=timeline|specs`, so
  existing links like `/roadmap?when=week&goal=G01#spec-089` open directly on
  the Goals & Specs view without regressing `tests/e2e/roadmap*.test.mjs`).
- **Complete URL query state on `/roadmap` (W5):**
  `?ws=<slug>&tab=timeline|specs&zoom=quarter|month|week&d=YYYY-MM-DD&goal=G01&milestone=<uuid>&epic=<KEY>`.
  - **Deep-link focus (`?milestone=<uuid>` or `?epic=<KEY>`):** opening
    `/roadmap` with either parameter (for instance from a Calendar popover,
    section 13.6) automatically selects `tab=timeline`, shifts the visible
    window `d` if needed to include that milestone's `target_date` or the
    epic's `end_date`/`start_date`, scrolls/centres that card into view (or
    expands the Unscheduled tray if the epic has no dates), applies a focus
    highlight (`aria-current="true"` / `data-focused="true"`), and opens its
    detail/edit popover. Closing the popover drops `milestone` / `epic` from
    the URL via `router.replace`.
- Left-rail navigation placement for `/roadmap` is open question **Q2**
  (`csi-spl-wui/src/utils/rail-order.ts:16,60-117` and
  `csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go:1022-1033`).

#### 13.4.2. Desktop timeline (`> 820 px`)

- **Controls bar:**
  - Zoom segmented control: **Quarter** / **Month** / **Week**, persisted in URL
    (`?zoom=quarter|month|week&d=YYYY-MM-DD`, default `month`, centered on
    today), plus **Today** / Previous / Next navigation buttons.
  - Filters: status (`Active` default: `planned`/`active`, overdue items
    highlighted, or `All`, or `Reached`), optional Goal filter (`?goal=G01`),
    and a toggle to show/hide closed epics.
  - Primary actions (shown to members holding write permission, hidden for
    `demo_user` / signed-out visitors): **`+ Milestone`** button and quick
    **Schedule epic** action.
- **Timeline canvas:**
  - Sticky top time axis showing:
    - **Quarter zoom:** 4 quarters (12 months) with month ticks.
    - **Month zoom:** 3 months with ISO week ticks.
    - **Week zoom:** 6 weeks with daily ticks.
  - A full-height accent vertical **"Today"** line across every band.
  - **Milestone header bands and pins (both kinds, W6):**
    - **Workspace milestones (DB `milestones` table):** each appears as a
      prominent interactive pin at its `target_date` AND heads a collapsible
      horizontal band holding its linked epics. Milestones linked to the same
      `goal_id` group visually under that goal's header chip (a dangling
      `goal_id` renders a plain muted chip with no link, N6); milestones with
      no goal sit in their own band; dated epics with no milestone sit in an
      **"Unassigned epics"** band.
    - **Synced goal milestones (`goal:<Gnn>:m:<key>`, from `goal.yaml` or
      in-app goal docs via `useRoadmapGoals`):** rendered as **read-only
      repo/goal pins** on the time axis under their Goal header chip
      (`data-test="roadmap-goal-milestone-pin"`, lock/repo badge, no Edit or
      Delete button). Clicking a pin opens a compact read-only popover with its
      date, title, and a link to `/goals/<Gnn>` (and the spec 4.1 "change it in
      the repo" link when present). This ensures `/roadmap` never silently
      drops goal milestones that Calendar shows.
  - **Large cards (not thin Gantt bars):**
    - **Milestone card** (`RoadmapMilestoneCard.vue`, ~280-320 px wide, generous
      padding, clear typography on the canonical `rem` scale):
      - Title, status pill (`planned`, `active`, `reached`, `canceled`, plus
        derived **Overdue** pill when `overdue === true`), optional Goal chip
        (`G01`, linked to `/goals/G01` only when that goal exists, else plain
        chip).
      - Target date + countdown (`12d left` / `Due today` / `3d overdue`).
      - Visual progress bar + counts (`3/5 epics · 24/38 issues · 63%`).
      - **Next thing due** line (e.g. `Next due: SPL-2396 · 2026-12-02`).
      - In-place actions: **Edit** (opens `RoadmapMilestoneDialog.vue`) and
        **+ Link epic**.
    - **Epic card** (`RoadmapEpicCard.vue`, positioned from `start_date` to
      `end_date` along the time axis, with a **minimum rendered width of
      220 px** so short spans remain full readable cards rather than unreadable
      slivers; an epic with only `end_date` anchors its right edge on `end_date`
      with a dashed left edge):
      - Epic key (`SPL-2396`) + kind dot (`epic` / `feature`) + 2-line title.
      - Date span (`Nov 25 – Dec 14`).
      - Progress bar + `done / (total - canceled)` + `%` (exact same rounded
        percentage as `IssueEpicsPanel.vue`).
      - **Next thing due** line (earliest open child deadline or epic end date).
      - Actions: click title opens `/issues?epic=SPL-2396`; **Edit dates** opens
        the compact inline editor (`RoadmapEpicDatesDialog.vue`).
  - **Unscheduled epics tray:** collapsible panel below the timeline listing
    open epics with neither `start_date` nor `end_date` (`count` badge), each
    with a one-click **Set dates** button that opens `RoadmapEpicDatesDialog.vue`
    and immediately places the epic onto the timeline.
- **Create and edit in place (zero page reloads):**
  - `RoadmapMilestoneDialog.vue`: create (`POST /v1/milestones`), edit
    (`PATCH /v1/milestones/{id}`), or soft-delete (`DELETE /v1/milestones/{id}`
    with confirmation noting linked epics stay intact and are only detached).
    Fields: title, target date (`<input type="date">`), status
    (`planned|active|reached|canceled`), optional goal picker, description,
    multi-select epic picker.
  - `RoadmapEpicDatesDialog.vue`: edit an epic's `start_date`, `end_date`, and
    `milestone_id` via `PATCH /v1/issues/{ref}`. Validates `end_date >= start_date`
    inline before submit.
  - Subscribes to live `milestone` and `issue` WebSocket frames so edits made by
    another member or via `spool` CLI reflect immediately.

#### 13.4.3. Phone layout (`<= 820 px`, spec 106 breakpoint)

A wide multi-month horizontal timeline is awkward at 390 px. At `<= 820 px`
(`pages/roadmap.vue:144`, `RoadmapGoalTable.vue:140`):

- The horizontal canvas becomes a **vertical chronological agenda of full-width
  large cards**, ordered by `target_date` / `end_date`, split by a sticky
  **"Today"** divider between overdue/past and upcoming items. Synced goal
  milestones appear in date order as compact read-only repo/goal rows linking
  to `/goals/<Gnn>`.
- Deep links (`?milestone=<uuid>`, `?epic=<KEY>`) scroll the matching card into
  view, highlight it, and open its sheet.
- The zoom control switches to touch-friendly range pills (**Week** / **Month**
  / **Quarter** / **All**), every interactive control meeting the 44 px minimum
  touch target (`var(--tap, 44px)`).
- Each **Milestone card** spans the full width (`minmax(0, 1fr)`), showing
  title, status/overdue pill, target date + countdown, progress bar (`epics` +
  `issues` + `%`), **next thing due**, an **Edit** button, and an expandable
  stack of its nested full-width **Epic cards** (each showing date range,
  progress bar, next thing due, tap to edit dates/milestone or jump to
  `/issues?epic=SPL-n`).
- Unscheduled epics collapse into an expandable card at the bottom with tap to
  schedule.
- **`+ Milestone`** and edit dialogs open as full-width bottom/full sheets
  (matching `CalendarPhoneSheet.vue`).

#### 13.4.4. Theming, i18n and performance budget

- **Theming:** uses existing dark/light CSS variables (`--color-border`,
  `--color-selected`, `--color-accent`, `--color-ok`, `--color-danger`,
  `--color-muted`); proven in both themes in e2e.
- **i18n:** every chrome string (`roadmap.timeline_*`, `milestone.*`,
  `calendar_event.milestone_*`, `calendar_event.epic_*`) uses `t(...)` in all
  19 locale files (`csi-spl-wui/i18n/locales/*.json`), keeping
  `i18n-parity.test.mjs`, `i18n-no-raw-text.test.mjs`, and
  `i18n-untranslated.test.mjs` green, with Google Cloud Translation check
  (`do_spl_lang_review_gct`, `CLAUDE.md` language rule). Milestone titles,
  descriptions, and epic titles are workspace content and stay untranslated.
- **Performance:** zero bytes added to the initial bundle (`ci_initial_gzip_kb`
  ceiling `155.0 KB`, `perf-budgets.json:4`). `RoadmapTimeline.vue`,
  `RoadmapMilestoneDialog.vue`, and `RoadmapEpicDatesDialog.vue` load via
  `defineAsyncComponent` from `pages/roadmap.vue` only (never imported from
  `app.vue`, a layout, or a plugin). Register `"roadmap-timeline"` alongside
  `"roadmap-page"` and `"roadmap-spec-table"` in
  `csi-spl-orc/src/bash/scripts/perf-budget.py:86`, keep the roadmap route
  within its `25.0 KB` gzip ceiling (`perf-budgets.json:10`), and verify
  `"roadmap-timeline"` never appears in any chunk listed by `initial_names()`
  (`perf-budget.py:178`).

### 13.5. Programmatic: hub routes, box wire, CLI and RBAC

#### 13.5.1. RBAC (same doors as issues)

| caller / operation | authorization | evidence / parity |
|---|---|---|
| Browser read (`GET /v1/milestones*`, `GET /v1/roadmap/timeline`) | `viewHandler` (`topics.read` in the session's active workspace) | `internal/hub/view.go:126-153`, `issues.go:881-882` |
| Browser create / patch (`POST /v1/milestones`, `PATCH /v1/milestones/{id}`, epic `PATCH /v1/issues/{ref}`) | `issueWriter`: `notes.send` + `topics.manage` + `billing.AllowsWrite` (`demo_user` gets 403) | `internal/hub/issues.go:951-972`; `internal/rbac/rbac.go:291,301-304` |
| Browser delete (`DELETE /v1/milestones/{id}`) | `issueWriter` + creator or `tenant.settings` (`biz_owner`, `admin`) — see Q6 | `internal/hub/issues.go:1023-1028` (`mayDeleteIssue`) |
| Agent read (`spool milestone list\|get`) | Box socket hello + `senderRefusal(x, f.As)` (announced agent of that box/tenant) | `internal/hub/issues_agent.go:29-38` |
| Agent write (`spool milestone create\|update`, epic dates via `spool issue update`) | Box socket hello + `senderRefusal(x, f.As)` + `issueWriteAllowed(ctx, x.tenant)` (billing) | `internal/hub/issues_agent.go:54-59,90-99` |
| Agent delete (`spool milestone delete`) | Same as write + `cur.CreatedBy == as` (creator only) — see Q6 | `internal/hub/issues_agent.go:166-192` (`agentDeleteIssue`) |

When spec 152 rows B5-B7 switch `issueWriter` from `topics.manage` to the
granular `issues.create` / `issues.edit` / `issues.status` /
`issues.remove_others` ids (`internal/rbac/rbac.go:92-116`), milestone handlers
reuse the same helper and move with it automatically.

#### 13.5.2. Hub HTTP routes (`HUB-5`)

`routeMilestones(mux)` lives in `internal/hub/milestones.go` and is called from
`internal/hub/server.go:542` alongside `s.routeWorkItems(mux)` — **never from
`calendar.go`**, keeping `HUB-5` and `HUB-6` strictly file-disjoint (W4). All
new routes carry CORS `OPTIONS` preflights matching `issuesPreflight`
(`issues.go:1242-1250`), decode request bodies with `DisallowUnknownFields()`,
and are documented in `csi-spl-api/src/go/spool-hub-api/internal/hub/openapi.json`.

| method | path | body / query | response & errors |
|---|---|---|---|
| `GET` | `/v1/milestones` | `?status=planned,active&goal=G01&from=YYYY-MM-DD&to=YYYY-MM-DD` | `200 {milestones: [...]}` sorted by `target_date ASC, title ASC`; each carries computed `overdue`, roll-up (`epics_total`, `epics_done`, `issues_total`, `issues_done`, `issues_canceled`, `pct`, `next_due`) and its linked `epics[]` summaries |
| `GET` | `/v1/milestones/{id}` | — | `200 {milestone, epics}`; `404 not_found` |
| `POST` | `/v1/milestones` | `{title, target_date, description?, status?, goal_id?, epics?: ["SPL-17", ...]}` | `201 {milestone}`; `400 bad_milestone` / `bad_epic`; `402` unpaid; fans out `milestone` `op: "create"` frame |
| `PATCH` | `/v1/milestones/{id}` | partial `{title?, target_date?, description?, status?, goal_id?, epics?}` (`""` clears `goal_id` / `description`; `epics: []` detaches all) | `200 {milestone}`; `400 bad_milestone`; `404 not_found`; fans out `milestone` `op: "update"` frame |
| `DELETE` | `/v1/milestones/{id}` | — | `200 {milestone}` (soft-deleted `deleted_at`; detaches linked epics' `milestone_id = NULL` in the same transaction); `403 forbidden`; `404 not_found`; fans out `milestone` `op: "delete"` frame |
| `GET` | `/v1/roadmap/timeline` | `?from=YYYY-MM-DD&to=YYYY-MM-DD&goal=G01&include_closed=1` | `200 {milestones, epics, unscheduled_epics}` — single-roundtrip read for `/roadmap` with computed `overdue`, roll-up and `next_due` on every milestone and epic |

**Extensions to existing issue routes (`internal/hub/issues.go`):**

- `issueRequest` (`issues.go:156-180`): add optional `start_date`, `end_date`
  (`YYYY-MM-DD`, `""` clears on `PATCH`), and `milestone_id` (UUID, `""` clears
  on `PATCH`). Hub enforces:
  - `start_date`, `end_date`, `milestone_id` refused on `kind = 'issue'` (`400 bad_issue`),
  - `deadline` refused on `kind IN ('epic', 'feature')` (`400 bad_issue`: "epics use start_date and end_date, not deadline", W2),
  - `end_date < start_date` refused (`400 bad_issue`),
  - missing/deleted/other-tenant `milestone_id` refused (`400 unknown_milestone`).
- `issueJSON` (`issues.go:42-76`): add `start_date`, `end_date`, `milestone_id`
  (`omitempty`), plus computed `rollup` (`{total, done, canceled, open, pct, next_due}`,
  computed with the one shared rule of 13.3.2 — live non-archived direct
  level-2 children, rounded half up) on `GET /v1/view/issues/{ref}` for level-1
  epics/features.
- `epicSummary` (`issues.go:822-832`): add `start_date`, `end_date`,
  `milestone_id`, `pct` (rounded half up, matching `epicProgress`), `next_due`
  (additive; existing fields unchanged).
- `GET /v1/view/issues` filter (`parseIssueFilter`, `issues.go:601`): add
  optional `?milestone=<uuid>` to filter epics (and their issues) by milestone.

#### 13.5.3. Box wire, `spool` CLI and MCP (`CLI-1`)

- **Box wire (`internal/wire/wire.go`):** add `TMilestone = "milestone"`
  alongside `TIssue` (`wire.go:45`), with `MilestoneOp`
  (`list|get|create|update|delete`), `MilestoneRef`, and `Milestone`
  (`json.RawMessage`), reusing `MsgID`, `As`, and `Query`. Dispatched in
  `internal/hub/ws.go:171,214` to `onMilestone`
  (`internal/hub/milestones_agent.go`). Because `spool milestone` dials a
  one-shot `role=cli` session (exact pattern of `hubclient.Issue`,
  `internal/hubclient/issue.go:23-42`), the hub never pushes unsolicited
  `milestone` frames to `role=box` sidecars, avoiding any stall on older
  `hub-run` binaries (`internal/hubclient/hubclient.go:661-665`).
- **CLI subcommand `spool milestone`** (`cmd/spool/milestone.go`,
  `internal/action/milestone.go`, `internal/hubclient/milestone.go`, listed in
  `cmd/spool/main.go` `usage` so `TestUsageNamesEveryVerb` at
  `cmd/spool/usage_test.go:16` stays green):
  - `spool milestone list --as <AGENT> [--status planned,active] [--goal G01] [--from YYYY-MM-DD] [--to YYYY-MM-DD]`
  - `spool milestone get --as <AGENT> --ref <uuid>`
  - `spool milestone create --as <AGENT> --title <T> --date <YYYY-MM-DD> [--status S] [--goal G01] [--description D] [--epics SPL-1,SPL-2]`
  - `spool milestone update --as <AGENT> --ref <uuid> [--title T] [--date YYYY-MM-DD] [--status S] [--goal G01|""] [--description D] [--epics SPL-1,...]`
  - `spool milestone delete --as <AGENT> --ref <uuid>`
- **CLI `spool issue` extensions** (`cmd/spool/issue.go:63-217`):
  - Add `--start-date <YYYY-MM-DD>`, `--end-date <YYYY-MM-DD>`, and
    `--milestone <uuid>` to `create` and `update` (`""` clears on `update`),
    and `--milestone <uuid>` to `list`.
- **MCP (`internal/mcp/mcp.go:183`):** register `spool_milestone` alongside
  `spool_issue` (calling `action.Milestone`); `spool_issue` already forwards raw
  JSON issue bodies so epic dates and `milestone_id` work through it once
  `issueRequest` accepts them.

### 13.6. Calendar: read the records, never copy them

Milestones and epic end dates are **never copied into `calendar_events`**.
Instead, the calendar read routes project them live from `milestones` and
`issues` — the exact pattern `deadlinesIn` already uses for `issues.deadline`
(`internal/hub/calendar.go:645-664,743-754,834-841`):

1. **Range read (`GET /v1/calendar/events?start=&end=`, `calendar.go:727-762`):**
   - Joins `milestonesIn(ctx, tenant, viewer, internalOK, rg)`: live non-deleted
     milestones with `status <> 'canceled'` whose `target_date` falls in
     `[rg.Start, rg.End)`. Synthesized `calendarEventJSON`:
     - `id: "milestone:" + m.ID`, `source: "milestone"`, `kind: "milestone"`,
       `all_day: true`, `starts_at: <target_date>T00:00:00Z`,
       `ends_at: <target_date + 1d>T00:00:00Z`, `audience: "internal"`,
       `status: m.Status`,
       `roadmap_url: "/roadmap?ws=" + tenant + "&milestone=" + m.ID`,
       `description`: milestone description (with computed progress summary
       carried in a structured `rollup` field).
   - Joins `epicEndsIn(ctx, tenant, viewer, internalOK, rg)`: live non-deleted,
     non-archived epics (`kind IN ('epic', 'feature')`,
     `!store.IssueClosed(i.Status)`) whose `end_date` falls in
     `[rg.Start, rg.End)` (end date only by default; see Q5). Because `RDB-3`
     backfills epic `deadline` into `end_date` and forbids `deadline` on
     epics/features (W2), `deadlinesIn` emits zero epic items and an epic
     appears at most once. Synthesized `calendarEventJSON`:
     - `id: "epic:" + i.Key()`, `source: "epic"`, `kind: "epic"`,
       `all_day: true`, `starts_at: <end_date>T00:00:00Z`,
       `ends_at: <end_date + 1d>T00:00:00Z`, `audience: "internal"`,
       `issue_key: i.Key()`, `status: i.Status`, `assignee: i.Assignee`,
       `roadmap_url: "/roadmap?ws=" + tenant + "&epic=" + i.Key()`.
   - **Visibility & guest guard (W3):** per spec 089
     (`csi-spl-doc/specs/089-calendar-section/spec.md:138,215,260`),
     `audience: "internal"` is readable **only by signed-in non-guest, non-demo
     workspace members** (`internalOK` is `false` for `demo_user`,
     `channel_guest` — any `rbac.Exclusive` role in `internal/rbac/rbac.go:172`
     — or an empty member session outside the door-off rig). Unlike personal
     issue deadlines (`deadlinesIn`, `calendar.go:648-663`, SPL-5963: assignee
     and creator only), every full workspace member sees workspace milestones
     and epic end dates; `channel_guest`, `demo_user`, and signed-out
     `/v1/public/calendar/events` (`calendar_web.go:70`) receive **none** (see
     Q4).
   - **Zero lag, zero drift:** changing a milestone's `target_date` or an epic's
     `end_date` updates the calendar on the very next read with no background
     sync and no stale `calendar_events` rows.
   - `?source_key=` lookups (`handleCalendarSourced`, `calendar.go:695`) remain
     `calendar_events`-only and unchanged.
2. **Year-strip marks (`GET /v1/calendar/marks`, `calendar.go:822-855`):**
   - Calls `milestonesIn` (`addMark(marks, day, "milestone")`) and `epicEndsIn`
     (`addMark(marks, day, "epic")`) under the same `internalOK` guard, so the
     36-month `CalendarYearStrip` shows milestone and epic markers for members
     and hides them for `channel_guest` and `demo_user`.
3. **Calendar WUI (`WUI-5`, distinguishing the two milestone kinds — W6):**
   - `csi-spl-wui/src/utils/calendar-event-form.mjs:156-178`: add
     `calMilestone(ev)` (`ev.source === 'milestone'`) and `calEpic(ev)`
     (`ev.source === 'epic'`). Both stay non-editable (`calEditable` returns
     `false` because `calStored` requires `source === 'event'`), so the grid
     forbids drag, resize, Edit, and Duplicate.
   - `CalendarMainView.vue`, `CalendarEventPopover.vue`, `CalendarPhone.vue`,
     `CalendarPhonePeek.vue`:
     - **Synced `goal.yaml` / in-app goal milestones** (`source: "event"`,
       `source_key: "goal:<Gnn>:m:<key>"`) keep their existing `calSynced`
       styling and popover ("change it in the repo" link,
       `CalendarEventPopover.vue:47-50`).
     - **Workspace DB milestones** (`source: "milestone"`) render with a
       distinct badge/marker (`data-source="milestone"`, `--cal-milestone`
       accent icon/chip); clicking opens a read-only popover labelled
       **"Workspace milestone"** showing target date, status/overdue pill,
       progress, and **"Open on Roadmap"** (`/roadmap?ws=<ws>&milestone=<id>`,
       deep-linked per W5).
     - **Epic end dates** (`source: "epic"`) render with `data-source="epic"`;
       clicking opens a read-only popover showing end date, status, assignee,
       progress, **"Open on Roadmap"** (`/roadmap?ws=<ws>&epic=<key>`), and
       **"Open issue"** (`/issues?issue=<key>`).
   - Spec 149 Google Calendar sync (`0217_google_calendar.sql`,
     `gcal_event_map`) reads `calendar_events` only, so projected milestones and
     epic end dates are not pushed to personal Google Calendars.

### 13.7. Build rows and order

Each row is one lane with **strictly disjoint file ownership across every
parallel pair** (W4) and an explicit red control (seen RED on a planted defect,
then GREEN, both outputs in the commit body; `developer-guide.md` 2.12.1).
`kind` names the `do_spl_lane_mix` kind
(`csi-spl-orc/src/bash/run/spl-lane-mix.func.sh:8-9`); `vendor` follows the
fleet split (`csi-spl-cnf/csi-spl/all.env.yaml:1567-1574` and
`spl-lane-mix.func.sh:52-72,110-117`: no mistral on coding or WUI per owner
2026-10-17 `msg 91bf8278`, and no mistral on review seats per owner 2026-11-24
`msgs 65a45673` & `591ca574`; docs-writing lanes remain eligible for mistral,
N5).

Order: `RDB-3` applies to `dev` and `prd` **before** `STORE-2` deploys. After
`STORE-2` lands, `HUB-5` and `HUB-6` run in parallel (disjoint files: `HUB-5`
wires `routeMilestones` in `server.go`, `HUB-6` owns `calendar.go`). After
`HUB-5` lands, `CLI-1` and `WUI-4` run in parallel. `WUI-5` starts after
**both** `HUB-6` and `WUI-4` (serialised on `csi-spl-wui/i18n/locales/*.json`);
`WUI-6` runs in parallel with `WUI-5` once `WUI-4` lands. `I18N-2` follows
`WUI-4` and `WUI-5`; `DOC-3` follows `HUB-5`, `CLI-1`, and `WUI-4`.

| row | layer | what | repo paths | depends on | tests + red control | kind | vendor |
|---|---|---|---|---|---|---|---|
| **RDB-3** | rdb | Forward-only migration: `milestones` table + RLS (statuses `planned\|active\|reached\|canceled`), `issues.start_date`, `issues.end_date`, `issues.milestone_id`, backfill of existing epic `deadline` into `end_date` + `issues_epic_no_deadline_check`, CHECKs, partial indexes; tenant gate seeding & non-export assertion | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_milestones_and_epic_dates.sql`, `csi-spl-api/src/go/spool-hub-api/internal/store/crosstenant_test.go` (`seedTenantAll`), `public_export_grants_test.go`, new `milestones_migrate_test.go` | none | `PRE_PUSH_TIER=full ./run -a do_check_pre_push`: migration applies twice on Postgres; `TestCrossTenantEveryTable`, `TestRLSPoliciesFailClosed`, `TestPublicExportGrantsEqualAllowList` green; backfill moves an epic's `deadline` to `end_date` and clears `deadline`; CHECKs refuse `end_date < start_date`, dates on level-2 issue, and `deadline` on epic/feature. **Red control:** remove `tenant_scope` policy -> `TestRLSPoliciesFailClosed` fails; plant `deadline` on an epic -> CHECK rejects. | `complex_coding` | `claude` |
| **STORE-2** | api | Store CRUD for `milestones`, epic `start_date`/`end_date`/`milestone_id` persistence, derived `overdue`, shared computed epic + milestone roll-up (round half up; live children for open epics, archived children included only for archived epics) and `next_due` | `csi-spl-api/src/go/spool-hub-api/internal/store/milestones.go`, `milestones_memory.go`, `milestones_postgres.go`, `milestones_test.go`, `issues.go`, `issues_postgres.go`, `issues_test.go` | `RDB-3` (applied dev+prd) | Memory + Postgres parity suite (`PRE_PUSH_TIER=full`): CRUD, soft delete detaches epics, cross-tenant `milestone_id` refused, derived `overdue` flips on `target_date < today`, `2/3` rounds to `67%`, open epic ignores individually-archived child while archived closed epic keeps archived children for milestone progress, `next_due` picks earliest open deadline. **Red control:** drop `deleted_at IS NULL` filter or switch to `floor` -> parity test fails. | `complex_coding` | `claude` |
| **HUB-5** | api | HTTP routes `/v1/milestones`, `/v1/milestones/{id}`, `/v1/roadmap/timeline` (`routeMilestones` wired in `server.go`), `OPTIONS` preflights, live `milestone` fanout, `issues.go` date/milestone/rollup extensions & epic `deadline` refusal, RBAC, OpenAPI | `csi-spl-api/src/go/spool-hub-api/internal/hub/milestones.go`, `milestones_test.go`, `issues.go`, `issues_test.go`, `server.go` (one-line `routeMilestones` wire), `openapi.json` | `STORE-2` | Go tests on memory + Postgres: CRUD, RBAC (`demo_user` 403, non-creator member 403 on DELETE, admin 200), unpaid tenant 402, epic dates rejected 400 on level-2 issue, `deadline` rejected 400 on epic/feature (W2), `end_date < start_date` 400, `GET /v1/view/issues/{ref}` `rollup` and `/v1/roadmap/timeline` match `epicSummary` (W1), live `milestone` frame emitted. **Red control:** drop `topics.manage` check -> `demo_user` write test fails; allow `deadline` on an epic -> W2 test fails. | `complex_coding` | `claude` |
| **HUB-6** | api | Calendar read-only projection of milestones (`source: "milestone"`) and open epic `end_date`s (`source: "epic"`) in `GET /v1/calendar/events` and `GET /v1/calendar/marks` (zero writes to `calendar_events`), gated against `channel_guest` and `demo_user` | `csi-spl-api/src/go/spool-hub-api/internal/hub/calendar.go` (`milestonesIn`, `epicEndsIn`), new `calendar_milestones_test.go` | `STORE-2` | Go tests on memory + Postgres: creating/moving a milestone or epic `end_date` appears immediately in `/v1/calendar/events` and `/v1/calendar/marks` with `0` rows written to `calendar_events`; epic appears once (never duplicated via `deadlinesIn`); visible to any full workspace member; **zero items returned to `channel_guest` (W3), `demo_user`, and signed-out `/v1/public/calendar/events`**; `PATCH`/`DELETE` on projected id refused. **Red control:** disable `milestonesIn`, insert into `calendar_events`, or drop the `channel_guest` guard -> test fails. | `simple_coding` | `claude` |
| **CLI-1** | cli | Box wire `wire.TMilestone`, `onMilestone` socket handler, `spool milestone` subcommands, `spool issue` `--start-date`/`--end-date`/`--milestone` flags, MCP `spool_milestone` | `csi-spl-api/src/go/spool-hub-api/internal/wire/wire.go`, `internal/hub/ws.go`, `internal/hub/milestones_agent.go`, `milestones_agent_test.go`, `internal/hubclient/milestone.go`, `internal/action/milestone.go`, `cmd/spool/milestone.go`, `cmd/spool/milestone_test.go`, `cmd/spool/main.go`, `cmd/spool/issue.go`, `cmd/spool/issue_test.go`, `internal/mcp/mcp.go` | `HUB-5` | Go CLI + socket tests: `TestUsageNamesEveryVerb` green; agent `create`/`list`/`get`/`update`/`delete` milestone and set/clear epic dates over `role=cli`; unannounced `--as` gets 403; non-creator agent delete gets 403; MCP `spool_milestone` returns JSON. **Red control:** remove `senderRefusal` -> unannounced agent test fails; omit verb from `usage` -> `TestUsageNamesEveryVerb` fails. | `simple_coding` | `claude` (or `agy`) |
| **WUI-4** | wui | `/roadmap` timeline UI: Quarter/Month/Week zoom, large Milestone & Epic cards (progress matching `IssueEpicsPanel`, dates, next due, dangling `goal_id` plain badge), read-only `goal.yaml` milestone pins (W6), `?milestone=` / `?epic=` deep-link focus (W5), in-place create/edit/delete dialogs, Unscheduled tray, phone `<= 820 px` vertical card agenda, live frame updates, lazy chunks | `csi-spl-wui/src/pages/roadmap.vue` (mount hook), new `components/RoadmapTimeline.vue`, `RoadmapMilestoneCard.vue`, `RoadmapEpicCard.vue`, `RoadmapMilestoneDialog.vue`, `RoadmapEpicDatesDialog.vue`, `composables/useRoadmapTimeline.ts`, `utils/roadmap-timeline.mjs`, `utils/roadmap-timeline-api.mjs`, `utils/roadmap-timeline-mock.mjs`, `csi-spl-wui/tests/unit/roadmap-timeline.test.mjs`, `csi-spl-orc/src/bash/scripts/perf-budget.py` (`"roadmap-timeline"`), `csi-spl-wui/i18n/locales/*.json` (en + drafts) | `HUB-5` | `pnpm run typecheck`, `roadmap-timeline.test.mjs` (zoom geometry, min-width clamp, roll-up parity, next-due, `?milestone=`/`?epic=` deep-link resolution, read-only goal milestone pins, dangling `goal_id`, phone sort), `perf-budget.py bundle` (`ci_initial_gzip_kb <= 155.0`, roadmap route `<= 25.0`, and `"roadmap-timeline"` absent from `initial_names()` chunks), existing `roadmap.test.mjs` and `roadmap-goals.test.mjs` green. **Red control:** import `RoadmapTimeline.vue` eagerly in `app.vue` -> `"roadmap-timeline"` appears in `initial_names()` and fails the chunk assertion (N3); invert `end_date < start_date` validation -> unit test fails. | `complex_coding` | `claude` |
| **WUI-5** | wui | Calendar WUI read-only rendering for `source: 'milestone'` (distinct from synced `goal:<Gnn>:m:*` milestones, W6) and `source: 'epic'` on desktop and phone (no edit/drag/duplicate, popover links to `/roadmap?ws=&milestone=` / `&epic=` and `/issues`) | `csi-spl-wui/src/utils/calendar-event-form.mjs`, `utils/calendar-mock.mjs`, `components/CalendarMainView.vue`, `CalendarEventPopover.vue`, `CalendarPhone.vue`, `CalendarPhonePeek.vue`, `csi-spl-wui/tests/e2e/calendar-milestones.test.mjs`, `csi-spl-wui/i18n/locales/*.json` (en + drafts) | `HUB-6`, `WUI-4` (serialised on locale files, W4) | Unit test for `calMilestone`/`calEpic`/`calEditable` + e2e `calendar-milestones.test.mjs` on generated mock bundle (1280 px & 390 px, dark & light): DB milestone (`data-source="milestone"`) styled distinctly from synced goal milestone (`data-synced="true"`), epic marker visible, click opens read-only popover with "Open on Roadmap" deep link, no Edit/Duplicate button. **Red control:** leave Edit button visible on a milestone popover or render DB milestone with `data-synced="true"` -> e2e fails. | `simple_coding` | `claude` |
| **WUI-6** | wui | E2E proof of `/roadmap` timeline on generated mock bundle (desktop + phone, dark + light, CRUD in place, zoom switching, `?milestone=`/`?epic=` deep links, read-only goal milestone pins) | `csi-spl-wui/tests/e2e/roadmap-timeline.test.mjs`, `csi-spl-wui/src/node/test/e2e-shard-weights.txt` | `WUI-4` (parallel with `WUI-5`) | `BASE_URL=<generated bundle> pnpm run test:e2e` on `roadmap-timeline.test.mjs`: desktop 1280 px (Quarter/Month/Week zoom, create/edit/delete milestone, schedule unscheduled epic, live progress & next-due, `?milestone=<id>` and `?epic=<KEY>` centre and open popover (W5), synced goal milestone pin is read-only (W6), dark+light) and phone 390 px (vertical agenda, Today divider, 44 px targets, deep-link sheet, create/edit sheet). **Red control:** ignore `?milestone=` or drop the `<= 820 px` agenda switch -> e2e fails. | `tests` | `claude` |
| **I18N-2** | i18n | Translate and verify all new `roadmap.timeline_*`, `milestone.*`, and calendar milestone/epic chrome keys across all 19 locales | `csi-spl-wui/i18n/locales/*.json` (all 19 files) | `WUI-4`, `WUI-5` | `i18n-parity.test.mjs`, `i18n-no-raw-text.test.mjs`, `i18n-untranslated.test.mjs` green; `do_spl_lang_review_gct` passes on all new non-en strings (`CLAUDE.md` language rule). **Red control:** leave one new key in English in a non-en locale -> `i18n-untranslated.test.mjs` fails. | `i18n` | `agy` |
| **DOC-3** | docs | Contract and user-doc updates: `issues-v1.md` (epic dates/milestone/rollup, epic `deadline` refusal), spec 089 calendar projection note (including `channel_guest` rule), `goals/README.md` (DB milestones vs `goal.yaml` milestones vs `milestones.yaml`), CLI & `/roadmap` user help | `csi-spl-doc/specs/039-spool-issues/contracts/issues-v1.md`, `csi-spl-doc/specs/089-calendar-section/spec.md`, `csi-spl-doc/goals/README.md` | `HUB-5`, `CLI-1`, `WUI-4` | `cd csi-spl-iac && ./run -a do_check_dist_hygiene && ./run -a do_check_pre_push_lint` (including `lint-mdlinks`) green; every new route, CLI flag, and field matches code. **Red control:** plant a broken markdown anchor -> `lint-mdlinks` fails. | `specs_and_docs` | `agy` (or `mistral`) |

### 13.8. Open questions for the owner (Q1–Q6)

Formatted for one `poll` form (`csi-spl-doc/doc/help/how-to-post.md` section 7).
The recommended option is listed first with its one-line why; each option says
what it changes in section 13 and the build rows.

1. **Q1. Can an epic belong to one milestone or several?** I recommend **(A)**:
   it keeps `goal -> milestone -> epic -> issue` a clean tree with no duplicate
   epic cards on the timeline.
   - (A) One milestone per epic (`issues.milestone_id` FK): section 13.3.1 as
     written; each epic sits in one milestone band on `/roadmap`.
   - (B) Many-to-many (`milestone_epics` join table): an epic can span multiple
     milestones; `RDB-3` adds `milestone_epics` instead of `issues.milestone_id`,
     `HUB-5`/`CLI-1` add link/unlink endpoints and flags, and `WUI-4` renders
     cross-milestone chips.
2. **Q2. Should `/roadmap` get its own icon in the left navigation rail?** I
   recommend **(A)**: today `/roadmap` is only reachable by typing the URL
   (`utils/rail-order.ts:16`), and the "mountain view" should be one click away
   beside Issues and Calendar.
   - (A) Yes, add a Roadmap icon to the left rail: touches rdb (`humans.rail_order`
     migration), api (`auth.RailTabs` in `internal/auth/handler.go:1022-1033`),
     and wui (`rail-order.ts`, the same pattern as Notes/Expenses at
     `rail-order.ts:103-116`); adds one small rail task alongside `RDB-3`/`WUI-4`.
   - (B) No new rail icon; add a "Roadmap" link inside `IssueEpicsPanel.vue` and
     the Calendar header instead (WUI-only, no `rail_order` migration or
     `auth.RailTabs` change).
   - (C) Keep `/roadmap` URL-only for now (no nav change).
3. **Q3. What counts in an epic's `done / total` roll-up?** I recommend **(A)**:
   it matches `IssueEpicsPanel.vue:31` (`done / (total - canceled)`) so the
   Issues panel and `/roadmap` always show the same percentage and never
   double-count a parent issue plus its subtasks.
   - (A) Direct level-2 issues only, excluding `diss` (canceled): section 13.3.2
     as written.
   - (B) All descendants (level-2 issues + level-3 subtasks), excluding `diss`:
     `STORE-2` and `epicSummaries` (`issues.go:836`) walk subtasks too so both
     views reflect subtask granularity.
4. **Q4. Are workspace milestones and epic dates visible signed out on a public
   roadmap?** I recommend **(A)**: epics often carry internal operational
   titles, so keeping milestones and epics member-only while approved goals stay
   publishable via `roadmap_public` avoids accidental leaks.
   - (A) Member-only for now: section 13.6 as written (`calendar_web.go`
     unchanged).
   - (B) Follow `tenants.roadmap_public` (spec 12.5): when public, milestone
     titles/dates and epic titles/progress also appear signed out on `/roadmap`
     and `/v1/public/calendar/events` (`HUB-5`/`HUB-6` extend `calendar_web.go`).
5. **Q5. On the calendar, which epic dates appear?** I recommend **(A)**: it
   keeps the calendar clean and focused on target and due dates, leaving
   multi-week spans to the `/roadmap` timeline.
   - (A) Epic `end_date` only (open epics), plus every non-canceled milestone
     `target_date`: section 13.6 as written.
   - (B) Full epic span (`start_date` to `end_date` as a multi-day all-day
     banner in Calendar): `HUB-6` projects `[start_date, end_date]` instead of
     `end_date` alone.
6. **Q6. Who may delete a milestone?** I recommend **(A)**: it matches
   `mayDeleteIssue` (`issues.go:1023-1028`) and `agentDeleteIssue`
   (`issues_agent.go:179`), keeping milestones and issues on one consistent rule.
   - (A) Its creator, or a `biz_owner` / `admin` (`tenant.settings`),
     soft-deleted with linked epics detached: section 13.5.1 as written.
   - (B) `biz_owner` or `admin` only (`tenant.settings` / `roadmap.publish`):
     other members and agents cannot delete milestones (they can still set
     status `canceled`); `HUB-5`/`CLI-1` drop the creator-delete branch.

### 13.9. Not in this amendment

- Pushing projected milestones or epic end dates into personal Google Calendars
  (spec 149 `gcal_event_map` reads `calendar_events` only).
- Migrating historical `csi-spl-doc/goals/milestones.yaml` lines into
  `milestones` table rows.
- Editing git-backed `goal.yaml` files from the WUI (workspaces without a repo
  already edit in-app goals via `PUT /v1/workspace/doctree/{doc}/goal`, HUB-3).
- Gantt dependency arrows or automatic date shifting across epics.

### 13.10. Review fold record (c-376, claude, 2026-11-25)

Cross-vendor review of `2a4ae8775` (c-376, FAIL W1–W6, N1–N6, msg `9bb46109` /
holder send-back `b561c30b`), folded item by item:

| item | what changed |
|---|---|
| W1 | 13.3.2 unifies rounding on round half up (`Math.round`, matching `issues-view.mjs:303-306`), restricts archived-child inclusion to archived (closed) epics so open epics match `epicSummaries`, and applies the same shared rule to `GET /v1/view/issues/{ref}` `rollup` (13.5.2, `STORE-2`, `HUB-5`) |
| W2 | 13.3.1 backfills existing epic `deadline` rows (2 measured in prd) into `end_date` and adds `issues_epic_no_deadline_check`; 13.5.2 refuses `deadline` on epic/feature (`400 bad_issue`); `RDB-3`, `HUB-5`, `HUB-6` test and guard it so an epic never has two due dates |
| W3 | 13.6 adds the explicit `internalOK` guard excluding `channel_guest` (and `demo_user`) per spec 089 (`:138,:215,:260`); `HUB-6` adds a `channel_guest` test case and red control |
| W4 | `HUB-5` wires `routeMilestones` in `server.go:542` instead of `calendar.go` (so `HUB-6` is the sole owner of `calendar.go`); `WUI-5` is serialised after `WUI-4` (`L17` after `L14` and `L16`) for `i18n/locales/*.json` |
| W5 | 13.4.1–13.4.3 define `?milestone=<uuid>` and `?epic=<KEY>` deep-link focus (select Timeline tab, centre on card or expand Unscheduled tray, highlight, open popover/sheet); covered in `WUI-4` and `WUI-6` |
| W6 | 13.3.3, 13.4.2–13.4.3 place synced `goal:<Gnn>:m:*` milestones as read-only repo/goal pins under their goal chip on `/roadmap`; 13.6 (`WUI-5`) distinguishes DB milestones (`data-source="milestone"`, "Workspace milestone") from synced goal milestones (`calSynced`) in Calendar |
| N1 | 13.2 "Issues schema" cites rdb `0055`, `0061`, `0071`, `0085` alongside `0047` for current status/priority/soft-delete/archive columns |
| N2 | 13.8 Q2(A) names `auth.RailTabs` (`internal/auth/handler.go:1022-1033`) alongside `rail-order.ts` and the `humans.rail_order` migration |
| N3 | 13.4.4 and `WUI-4` red control assert `"roadmap-timeline"` is absent from `initial_names()` (`perf-budget.py:178`), which fails even for a small eager chunk |
| N4 | 13.3.1 drops stored `'missed'` from `milestones.status` CHECK; `overdue` is derived on read (`status IN ('planned','active') AND target_date < current_date` UTC) |
| N5 | 13.7 cites `spl-lane-mix.func.sh:52-72,110-117` (owner 2026-10-17 `msg 91bf8278` no coding; owner 2026-11-24 `msgs 65a45673` & `591ca574` removing mistral from review seats) |
| N6 | 13.3.3 & 13.4.2 specify that a dangling `milestones.goal_id` stays intact on read and renders as a plain muted chip with no broken link |
