# Spec 112: Goals, strategy and roadmap

Version **v1.0** (2026-10-08). Drafted by a-597 (v0.1, v0.2 `8c9766cd1`);
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

### 4.3. Audience

Every synced or backfilled event sets `audience` explicitly; the 0125 default
is `public`. Goal, milestone, release and spec events are `public`. A
`db:` event is `internal` (the audience the hub drops for a guest,
`internal/store/calendar.go`). The store refuses a `db:%` key with any other
audience, and a store test covers it.

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
