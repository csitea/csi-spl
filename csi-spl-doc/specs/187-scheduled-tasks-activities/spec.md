# Spec 187: Scheduled Tasks and Activities

Status: **Draft v0.2** (2026-11-20). Lane `c-150` (`claude`, backup for
`specs_and_docs`: agy held by the placer). Nothing below is built.
Epic: **SPL-2398**. Issue: **SPL-6067**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:91992830-ca2f-4711-b04e-e4c333d7294d` (`t1`), task
`dispatch-91992830`.
Builds on: [182 topic loop prompt](../182-topic-loop-prompt/spec.md) (a saved
prompt fired by triggers, its ticker and claim), [121 sales channel](../121-sales-channel/spec.md)
section 7 (token budgets and the usage ledger), [098 tenant settings
jsonb](../098-tenant-settings-jsonb/spec.md) (registered workspace settings)
and the search grammar ([search-v1](../003-spool-message-bus/contracts/search-v1.md)).

Number: the highest spec on `origin/master` `d6b810775` is
`186-multicast-prompt` (`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -2`),
and no live worktree other than this lane's own (`c-150`) holds a `187-`
spec folder (`ls -d` of `csi-spl-doc/specs/187*` in every `git worktree list`
path -> only `c-150`), so this is 187.

Paths below: `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`,
`rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `wui/` =
`csi-spl-wui/src/`. Every claim about the code was read on `origin/master`
`d6b810775`.

## 0. The owner's words (HUM-10, t1 91992830, 2026-11-20)

- msg `d61a547c-9c41-438c-8829-905542544357`, 10:37:15Z, verbatim:
  "scheduled tasks and activities - we need to build this feature"
- msg `20eea3ff-ea89-42cf-a674-0932f91272b2`, verbatim: "basically those
  should be configurable in both on spool-hub cloud instance level and per
  workspace level"
- msg `7ee7ac92-4f6a-45ce-bd8a-39b72ac4acc0`, verbatim: "one should be able
  to define which objects the working out of the newly configured task or
  activity should concern - channel , topic , msg , issues , one should be
  able to define also a custom prompt and an interval , it should work a bit
  like the filtering rules in an outlook program and the scheduling tasks for
  Windows , but wit the objects exposed by the spool-hub"

Read as one model, used through the whole spec: a task is a **scope** (which
spool-hub objects it concerns: channels, topics, messages, issues, with
conditions, like an Outlook rule), an **action** (a fixed action, or a custom
prompt an agent works out) and a **trigger** (a schedule, like the Windows
Task Scheduler, or an event).

## 1. Decided, and what is open

### 1.1 The owner's answers (poll `38083eff`; msgs `2cc2dea2` and `19171767`)

Quoted verbatim; this spec applies them and does not re-ask them.

| # | Answer (verbatim) | What it decides here |
|---|---|---|
| D1 | "A — Both: a fixed action (move, label, archive, notify) or an agent with your prompt" | 4.3: two action kinds, fixed and `agent` |
| D2 | "A — Time and events: a new message, topic or issue that matches the scope" | 4.2: schedule triggers and event triggers |
| D3 | "A — Workspace admins; members may create tasks that touch only their own objects" | 4.5: who may create, the own-objects rule |
| D4 | "A — The instance sets defaults and limits, and can also run tasks across all workspaces; workspaces work within those limits" | section 5: the two levels, the instance wins |
| D5 | "It should be in the scheduled tasks and activities new channel for a workspace." | 6.1: a new default channel per workspace receives every run's result |
| D6 | "B — Anything, no approval" | 4.3: no dry run, no approval step; a run acts at once, within its scope and its owner's rights |
| D7 | "A — A cap on runs per day and on AI tokens per month, per workspace, set at instance level" | 5.3: two caps per workspace, set by the instance |
| D8 | "A — Yes: daily digest of a channel, nudge stale issues, archive idle topics, weekly status report" | section 7: four templates at launch |

D6 is not the option the form recommended. What it gives up (a dry run, an
approval) is replaced only by what D3, D7 and 4.6 already hold: a task never
acts beyond its owner's rights, beyond its scope, or past the caps, and
every change a run makes is written to the run's history and posted in the
channel (D5), so it can be seen and undone by hand.

### 1.2 Open

Eleven questions, one form, section 10. None of them changes a column of
section 8 or a contract of 9.1 (each answer is a value of a column or a
setting that exists either way), so rows S1 and S2 do not wait for them.

## 2. What exists, and how this differs or reuses

Not re-specified here; this spec reuses or stays clear of each.

| what | where | relation to this spec |
|---|---|---|
| **Topic loops** (spec 182): a saved prompt on ONE topic, fired by 11 triggers (after and before an agent reply, after a human reply, every hour, every n minutes, daily at, no reply after a human post, keyword, file, blocker, issue status; 182 spec 1.2), cap 12 per hour, sent hidden to the topic's agent | `../182-topic-loop-prompt/spec.md` sections 1.2, 4, 5; rows L1-L7 in build; no loop store on master yet (`git ls-tree -r --name-only origin/master csi-spl-api/src/go/spool-hub-api/internal/store/ \| grep -i loop` -> none) | **A different object, a shared pattern.** A loop lives on one topic and answers in it. A scheduled task lives on the workspace (or the instance), its scope is a filter over many objects, it may run a fixed action without any agent, and it reports in its own channel (D5). Reused: 182's ticker and claim (one `UPDATE ... RETURNING` per tick, no catch-up burst, a UUIDv5 of the cause as the id) and its time-zone rule. Whether loops later fold into tasks: **Q1**. |
| **Day's tasks** (spec 170): a To-do view in the Calendar of issues by deadline; the morning card dropped (poll `acef24b9`) | `../170-day-tasks-reminder/spec.md` 1.2, 11.4 | **Reused by a template**: "nudge stale issues" (7.2) reads the same issues and links the To-do view `/calendar?k=todo&v=day`. Nothing in 170 changes. |
| **Activity issues** (spec 174): `issues.kind = activity`, the standing duty of a fleet role seat, synced from `csi-spl-orc/cnf/role-activities/activities.tsv` | `../174-activity-issues/spec.md` 3.1, 3.2 | **The same word, a different thing.** 174's activity is the *definition* of a role seat's duty and has no runs. This spec's "activities" are the runs of a scheduled task. A 187 run is never written as an `issues` row of kind `activity`. |
| **Reporter role** (spec 177): a cron-spawned agent with a checklist, writing reports and daily per-member task notes | `../177-reporter-role/spec.md` section 0 | **A fleet job on a box.** Template "weekly status report" (7.4) is the workspace-level, person-configured form of a report; the Reporter stays as it is. |
| **Calendar** (specs 089, 097, 119 section 15): events with a time zone, reminders, the Google sync on its own 60 s ticker | `api/store/calendar.go:156` (`TimeZone`, "" is UTC); `api/hub/gcal_sync.go:44` (`gcalSyncEvery = 60 * time.Second`), `:80` (its ticker), started at `api/hub/server.go:711` | **Reused**: the 60 s ticker pattern and the IANA-zone rule. A task is not a calendar event and is not shown in the Calendar (section 11). |
| **The hub's own timers** | `RunSweeper` (`api/hub/server.go:700`): retention, file, demo and backfill tickers and the chores of each sweep; also `presence.go:41`, `blocker_issue.go:94`, `repo_sync.go:138`, `operator_deploys.go:316`, the `marketing_*` dispatchers, `relay.go:82` | Each is fixed system upkeep that no person configures. The task runner is ONE new ticker beside them (row S3); none of them moves into it. |
| **The fleet's box crons** | 29 actions `csi-spl-orc/src/bash/run/*install-cron*.func.sh` (`ls ... \| wc -l` -> 29): disk sweep, env order, dispatch and orch rotate, spawn place / fill / remote, unanswered sweep, review go, topic archive suggest, cost rollup, ... | **Fleet upkeep on agent boxes, out of scope.** They run on a box as the box user and know the box; a scheduled task runs in the hub for a workspace and knows only spool-hub objects. None is migrated (section 11). `do_spl_topic_archive_suggest` (`spl-topic-archive-suggest.func.sh`) is the nearest neighbour of template 7.3; the template is per workspace and person-configured, the cron stays. |
| **Token budgets** (spec 121 section 7): per-workspace and per-channel `tokens_per_day` / `tokens_per_month`, checked before every agent turn, `429 token_quota`, one 80 % notice | `api/store/token_budget.go` (`BudgetLimitMonth`), `api/hub/token_budget.go` (`tokenBudget`), the ledger `rdb/0171_usage_events.sql`, `meterTurn` `api/hub/usage_events.go:43` | **Reused for the D7 token cap**: an agent run is an agent turn, metered by the same ledger. The task cap is its own limit, read from the same ledger (5.3). |
| **Workspace settings registry** (spec 098) | `RegisterTenantSetting` `api/store/tenant_kv.go:84`; `TenantSettingDef` `:57` (Default, Min, Max, OneOf) | **Reused** for the workspace-level settings (5.2). |
| **Operator routes**: hub calls authorised by a Google ID token whose verified email is in `OperatorEmails` | `api/hub/operator.go:37` (`operatorEnabled`), `:43` (`operatorAuth`) | **Reused** as the instance level's API door (5.1). A person who is instance admin in the web UI: **Q2**. |
| **Default channels** `#lobby`, `#alerts`, `#feedback`, `#public`: seeded by a tenant trigger; every member reads them without a membership row; the hub posts in them as `HUB-0` | `rdb/0173_default_channel_public.sql` (`spool_seed_default_channels`); `DefaultChannels` and `PublicChannels` `api/store/channels.go:44,49`; `PostPublicNotices` `api/hub/public_notice.go:27` (signed `box-wui`) | **Reused**: the D5 channel is a fifth default channel, seeded the same way (6.1). The retired `#tasks` id (`ChannelTasks = "tasks"`, `channels.go:40`, "can never be created again") is NOT reused: the new id is `scheduled-tasks`. |
| **Search grammar**: one Gmail-style query language with in-memory matchers | `api/search/grammar.go` (Version 1.6); `MatchMsg` `api/search/match.go:87`, `MatchTopic` `:162`, `MatchEntity` `:191`; operators `type: from: to: box: in: is: has: topic: before: after: on: title: name: ext: larger: smaller: status: prio: assignee: label:` | **Reused as the scope's condition language** (4.1): the Outlook-rule half. One grammar, no second parser. |
| **Object actions** behind routes today | `POST /v1/messages/{msg_id}/move`, `PUT` / `DELETE /v1/messages/{msg_id}/archive`, `PATCH /v1/messages/{msg_id}/kind`, `PUT /v1/topics/{task_id}/priority`, `POST /v1/issues/{ref}/archive`, `PUT /v1/channels/{channel}/archive`; topic archive `handleArchiveTopic` (`api/hub/topic_archive.go`); issue writes `createIssue` / `updateIssue` (`api/hub/issues.go:353,419`) | **Reused**: each fixed action calls the store path its route calls, under the owner's rights (4.3, 4.5). |

Nothing named "scheduled task" exists:
`git grep -il "scheduled.task\|scheduled_task" origin/master -- csi-spl-api csi-spl-rdb csi-spl-wui/src | wc -l` -> 0.

## 3. Terms

- **Task**: one saved row: its level, owner, scope, trigger, action, state
  (`on` / `paused`) and counters. The UI calls it a "scheduled task" also
  when its trigger is an event.
- **Level**: `workspace` (the row belongs to one workspace) or `instance`
  (the row belongs to the hub and runs in every workspace, or in a listed
  set, D4).
- **Scope**: the object type (`channel`, `topic`, `message`, `issue`), where
  (all channels or listed ones) and a condition in the search grammar. The
  "which items" half of an Outlook rule.
- **Trigger**: a **schedule** (once, every n minutes, daily, weekly,
  monthly, at a time in a zone) or an **event** (a new message, topic or
  issue that matches the scope, D2).
- **Action**: **fixed** (move, archive, label, set priority, notify) or
  **agent** (the task's prompt plus the matched objects, sent to an agent,
  D1).
- **Run**: one execution of a task: the objects it matched, what it did to
  each, its outcome (`ok`, `partial`, `failed`, `skipped`), the tokens it
  used and the message it posted in the channel. A run is an **activity** in
  the UI's words.
- **Owner** of a task: the member who created it, or who last edited it
  (as a loop's author in spec 182 4.5: "the editor becomes its author"); `HUB-0` for an instance task.

## 4. The task

### 4.1 Scope (which objects)

| field | values | meaning |
|---|---|---|
| `object` | `channel`, `topic`, `message`, `issue` | one type per task |
| `where` | all, or a list of 1..50 channel ids | the channels the scope reads; for `issue`, all only (issues are workspace-wide) |
| `query` | a search-grammar string, at most 512 UTF-16 units (`MaxQueryUnits`, `api/search/grammar.go`) | the conditions, e.g. `from:HUM-3 has:file`, `status:wip`, `is:task in:#ops` |
| `max_objects` | 1..500, default 100 | at most this many objects per run; the rest wait for the next run, and the run says so |

- The query is parsed with `search.Parse` at save; a query the grammar
  refuses is refused with its error, as the search route answers. An
  operator that does not apply to the object type (`ext:` on an issue) is
  refused.
- A **schedule** run reads the matching objects through the search stores,
  as the reader the run acts for (4.5): the same statements and the same RLS
  as `GET /v1/view/search`, so a task never sees what its owner could not.
- An **event** run matches the one new object in memory with `MatchMsg`,
  `MatchTopic` or `MatchEntity`, with no store probe.
- The editor offers the common conditions as fields (from, in channel, has
  a file, kind, status, priority, label, idle for) that write the query, and
  shows the query text for editing, the way Outlook's rule wizard writes its
  conditions.

### 4.2 Trigger (when)

| kind | fields | fires |
|---|---|---|
| `once` | `at` (date and time), `tz` | once at that time; then the task pauses with reason `done` |
| `every_n_minutes` | `interval_min` 15..10080 | n minutes after the last run |
| `daily` | `at_time` hh:mm, `tz` | every day at that local time |
| `weekly` | `at_time`, `tz`, `weekdays` (1..7 = Mon..Sun) | on those days at that local time |
| `monthly` | `at_time`, `tz`, `month_day` 1..28 or last | that day each month |
| `event` | `on`: `message_new`, `topic_new`, `issue_new`, `issue_changed` | when such an object is stored and matches the scope (D2) |

- **Time zone**: an IANA name, checked with `time.LoadLocation` before the
  write; "" is UTC. The editor defaults it to the browser's zone, as spec
  182's `daily_tz`. A local time that does not exist on a DST day runs at
  the next valid minute; one that occurs twice runs once.
- **The 15-minute floor** of `every_n_minutes` is an instance setting (5.1).
  Spec 182's floor of 5 is for one topic; a task may scan a whole workspace.
- **Missed runs**: a schedule missed while no hub instance ran runs once at
  the next tick, never as a burst (spec 182 4.2 step 5).
- **Event hooks** are the ones spec 182 4.2 names, so each hot path gets one
  hook for both features: `message_new` and `topic_new` in `wuiAfterStore`
  (`api/hub/wui.go`, after the store) and in `onSend` after
  `commitRowTyped` (`api/hub/ws.go`); `topic_new` when the stored row is the
  first on its task id; `issue_new` in `createIssueOn`, `issue_changed` in
  `updateIssue` (`api/hub/issues.go:360,419`). Only an inserted row fires (a
  replay does not).
- **Never a trigger**: a `HUB-0` note, a loop prompt message (spec 182 5.2),
  a run's own result post (6.1), and **[Q6]** a change made by a task run.
- **Cron expressions** (`*/30 8-18 * * 1-5`) are not in v0.1: **Q11**.

### 4.3 Action (what runs)

**Fixed** (D1), one action per task, applied to every matched object:

| action | objects | does | path reused |
|---|---|---|---|
| `move` | message | moves it to the named channel | `POST /v1/messages/{msg_id}/move` |
| `archive` | message, topic, issue, channel | archives it | `PUT /v1/messages/{msg_id}/archive`, `handleArchiveTopic`, `POST /v1/issues/{ref}/archive`, `PUT /v1/channels/{channel}/archive` |
| `label` | issue | adds the named label from the workspace's label catalogue | `updateIssue` |
| `set_priority` | topic, issue | sets the priority | `PUT /v1/topics/{task_id}/priority`, `updateIssue` |
| `notify` | any | posts in the task's channel topic (6.1) naming the matched objects, `@`-mentioning listed members | a hub post as `HUB-0`, the `PostPublicNotices` path |

Topics and messages carry no labels today (the grammar's `label:` applies to
issues, `api/search/match.go` `OpLabel` in `MatchEntity`); whether D1's
"label" adds them: **Q10**.

**Agent** (D1): the task's **prompt** (1..4000 characters) and the matched
objects (each as a link and a 600-character quote, at most `max_objects`)
go to an agent as one `kind: task` message on the run's topic in the task
channel, signed `box-wui` with `dispatchEnvelope` and stored with
`commitRowTyped`, as spec 182 4.3 step 2. Which agent: **Q3**. The agent
answers in that topic; its answer is the run's result. The agent acts with
its own rights in the workspace; the prompt is the owner's instruction, as
any `@agent` post is.

**No approval, no dry run (D6).** A fixed action is applied as the run
finds each object. Before save, the editor shows how many objects the scope
matches now (one read-only search): a count, not an approval step.

### 4.4 State: pause, resume, delete

- `on` or `paused`. Pause keeps everything; resume computes the next due
  time from now (no catch-up).
- The hub pauses a task with a reason the list shows: `done` (a `once` task
  ran), `owner_left` (the owner left the workspace or lost the right of
  4.5), `failing` (5 runs in a row `failed`), `cap` (a cap of 5.3 is
  reached; the task resumes itself when the window rolls over).
- Delete is soft: the row and its runs are kept 30 days, then a new chore in
  `RunSweeper`'s sweep removes them.

### 4.5 Who may create and edit (D3)

- **Workspace admins** (a role holding `tenant.settings`, `api/rbac/rbac.go`)
  create, edit, pause and delete any workspace task.
- **A member** creates and edits tasks that touch only their **own
  objects** (which those are: **Q8**). It is enforced twice: at save, the
  scope is narrowed with the member's own-object condition; at run, each
  matched object is checked again before a fixed action applies. A member's
  task acts with the member's rights only. An admin may switch the member
  right off (5.2).
- **A run acts as its owner**, with the owner's member id and role at the
  time of the run (not of the save). If the owner left or lost the right,
  the run is `skipped` and the task pauses with `owner_left`. An admin may
  take a task over by editing it; the editor becomes its owner (spec 182
  4.5).
- **An instance task** acts as `HUB-0` with a workspace admin's rights in
  each workspace it runs in, and is set only through the instance level
  (5.1).

### 4.6 Runs: history and failure

- One `scheduled_task_runs` row per run (8.1): start, end, cause, matched
  and acted counts, outcome, failures, error text (at most 500 characters),
  tokens, and the msg_id of its result post.
- **Idempotent per cause**: a run's id is a UUIDv5 of `(task_id, cause)`;
  the cause is the due time for a schedule and the object's id for an event
  (spec 182 4.3 step 3). A second claim of the same cause is a no-op.
- **Partial failure**: a fixed action that fails on one object goes on with
  the others; the run is `partial` and lists each failed object with its
  reason. Nothing is retried inside a run: the next run takes the object
  again if it still matches.
- **A failed run** is retried once after 5 minutes; failing again, it counts
  towards `failing` (4.4). An agent run with no answer within the instance's
  `agent_run_timeout_min` (default 30) ends `failed` with reason
  `no_answer`.
- **History** is kept `history_days` (default 90, an instance setting) and
  shown per task (6.2).

## 5. Two levels: instance and workspace (D4, msg 20eea3ff)

### 5.1 The instance level

The hub's operators (the identities in `OperatorEmails`,
`api/hub/operator.go`) configure the instance; who that is in the web UI:
**Q2**. The instance holds:

| setting | default | meaning |
|---|---|---|
| `tasks.enabled` | true | the switch for every workspace |
| `tasks.runs_per_day.default` | **Q9** | the D7 run cap of a workspace with no override |
| `tasks.tokens_per_month.default` | **Q9** | the D7 token cap, the same way |
| per-workspace overrides of both caps | none | the instance raises or lowers one workspace's caps (D7: "set at instance level") |
| `tasks.max_per_workspace` | 100 | tasks per workspace, deleted ones not counted |
| `tasks.min_interval_min` | 15 | the floor of `every_n_minutes` |
| `tasks.allowed_actions` | the five fixed and `agent` | an action switched off everywhere |
| `tasks.agent_run_timeout_min` | 30 | 4.6 |
| `tasks.history_days` | 90 | 4.6 |
| **instance tasks** | none | tasks the instance runs across all workspaces, or a listed set (D4) |

Stored in one new table, `hub_settings` (8.1): key, JSON value, set by, set
at. It has no tenant column: only the operator routes and the runner read
it. The routes, each behind `operatorAuth`: `GET` / `PUT
/v1/operator/task-settings`, `GET` / `POST /v1/operator/tasks`, `PUT` /
`DELETE /v1/operator/tasks/{id}`, `GET /v1/operator/task-runs`.

### 5.2 The workspace level

Workspace admins configure, as registered workspace settings (spec 098,
`RegisterTenantSetting`):

| setting | default | meaning |
|---|---|---|
| `tasks.enabled` | true | the workspace switches the feature off for itself |
| `tasks.members_may_create` | true | D3's member right |
| `tasks.runs_per_day` | the instance's value | may be set LOWER, never higher |
| `tasks.tokens_per_month` | the instance's value | the same |
| `tasks.allowed_actions` | the instance's set | a subset of it |

### 5.3 Which wins

1. **Instance off beats everything**: `tasks.enabled = false` at the
   instance stops every run in every workspace, instance tasks included.
2. **A limit takes the lower value**: a workspace's effective cap is the
   lower of the instance's (its override, else its default) and the
   workspace's own. A workspace never raises a cap ("workspaces work within
   those limits", D4).
3. **A set takes the intersection**: an action is allowed only where both
   levels allow it.
4. **Caps are checked at claim.** A run is claimed only while the
   workspace's runs today (UTC) are under its cap. The token cap is read
   from the usage ledger (`rdb/0171`) over the turns of this month's (UTC)
   agent runs, the way `tokenBudget` reads it. At 80 % the workspace admins
   get one notice in the task channel; at 100 % agent runs are `skipped` and
   their tasks pause with `cap` until the window rolls over. A fixed run
   counts towards the run cap only (it spends no AI tokens).
5. **The token budget of spec 121 still applies**: an agent run is an agent
   turn, so the workspace's budget can still refuse it (`429 token_quota`);
   the run then ends `failed` with that reason.
6. **Instance tasks**: whether they count against a workspace's caps, and
   where their results go: **Q7**.

## 6. Where it shows

### 6.1 The "scheduled tasks and activities" channel (D5)

- A fifth default channel, id `scheduled-tasks`, shown as "Scheduled tasks
  and activities" (a translation key). It is added to
  `spool_seed_default_channels` (every new workspace) and inserted for every
  existing one by the same migration, as `rdb/0173` did for `#public`, and
  added to `DefaultChannels`. Being a default channel, every member reads it
  (`PublicChannels`, `api/store/channels.go:49`); whether that is right:
  **Q5**.
- Every run that matched at least one object posts its result here as
  `HUB-0`, signed `box-wui` (the `public_notice.go` path): the task's name,
  the trigger, the matched and acted counts, the outcome, each object as a
  link, and for an agent run the agent's answer. Topic layout: **Q4**.
- A run that matched nothing posts nothing (its history row is still
  written), so a quiet task does not fill the channel.
- A result post fires no task and no loop (4.2).

### 6.2 The lists

- **Workspace**: Settings -> "Scheduled tasks", a new section: name, object,
  next run, last outcome, state (with the pause reason), owner; per row
  Edit, Pause / Resume, Run now, History, Delete; "New task" and "From a
  template". An admin sees every task; a member sees their own and,
  read-only, the others.
- **Instance**: the instance tasks, and per workspace its task count, runs
  today and tokens this month against its caps (the 5.1 routes; the page is
  **Q2**).
- **History**: per task, its runs of the last `history_days`, newest first,
  each linked to its result post.

### 6.3 The editor

One dialog, in the Windows Task Scheduler's order, then a summary:

1. **What it concerns** (4.1): object type, channels, conditions, and the
   live match count.
2. **When** (4.2).
3. **What it does** (4.3): a fixed action and its argument, or a prompt
   (and the agent, per Q3).
4. **Summary**: one sentence ("Every weekday at 08:00 Europe/Helsinki, for
   issues with status wip idle for 7 days, notify their assignees") and
   Save.

Every word is a translation key (developer guide 2.7); agy has the final
word on the locales (the language rule).

## 7. Templates at launch (D8)

A template fills the editor; the person changes anything before saving.

| # | template | scope | trigger | action |
|---|---|---|---|---|
| 7.1 | Daily digest of a channel | `message`, the chosen channel, `after:1d` | `daily` 08:00, the creator's zone | `agent`: "Summarise the messages of the last day in this channel: decisions, open questions, who waits on whom. Link each point." |
| 7.2 | Nudge stale issues | `issue`, `status:wip idle:7d` | `weekly` Monday 09:00 | `notify`, mentioning each issue's assignee |
| 7.3 | Archive idle topics | `topic`, `idle:30d` | `daily` 03:00 | `archive` |
| 7.4 | Weekly status report | `issue`, changed in the last 7 days | `weekly` Friday 15:00 | `agent`: "Write a status report of the week from these issues: done, in progress, blocked, next. Link each issue." |

The grammar has no "idle for" operator (the operators are listed in section
2). Row S2 adds `idle:<duration>` (no message since, for a topic; no change
since, for an issue) and `changed:<duration>` (its inverse), grammar
version 1.7; `after:` and `before:` stay as they are.

## 8. Store

### 8.1 Tables

One forward-only migration, numbered by `do_rdb_migration_next` at build
time (head on `origin/master` `d6b810775`: `0300`; the number moves, the action picks it).

```sql
CREATE TABLE IF NOT EXISTS scheduled_tasks (
    tenant_id        text        REFERENCES tenants (tenant_id) ON DELETE CASCADE, -- NULL = instance task
    task_id          uuid        NOT NULL PRIMARY KEY,
    level            text        NOT NULL CHECK (level IN ('workspace','instance')),
    name             text        NOT NULL CHECK (name <> '' AND length(name) <= 120),
    owner_id         text        NOT NULL CHECK (owner_id <> '' AND length(owner_id) <= 64),
    template         text        NOT NULL DEFAULT '' CHECK (template IN ('','channel_digest','stale_issues','idle_topics','weekly_status')),
    scope_object     text        NOT NULL CHECK (scope_object IN ('channel','topic','message','issue')),
    scope_where      text[]      NOT NULL DEFAULT '{}' CHECK (cardinality(scope_where) <= 50), -- {} = all channels
    scope_query      text        NOT NULL DEFAULT '' CHECK (length(scope_query) <= 1024),
    max_objects      integer     NOT NULL DEFAULT 100 CHECK (max_objects BETWEEN 1 AND 500),
    trigger_kind     text        NOT NULL CHECK (trigger_kind IN ('once','every_n_minutes','daily','weekly','monthly','event')),
    trigger_spec     jsonb       NOT NULL,
    tz               text        NOT NULL DEFAULT 'UTC' CHECK (tz <> '' AND length(tz) <= 64),
    action_kind      text        NOT NULL CHECK (action_kind IN ('move','archive','label','set_priority','notify','agent')),
    action_spec      jsonb       NOT NULL,
    state            text        NOT NULL DEFAULT 'on' CHECK (state IN ('on','paused','deleted')),
    paused_reason    text        NOT NULL DEFAULT '' CHECK (paused_reason IN ('','by_person','done','owner_left','failing','cap')),
    next_due_at      timestamptz,
    fail_streak      integer     NOT NULL DEFAULT 0,
    instance_tenants text[]      NOT NULL DEFAULT '{}',          -- instance task: {} = every workspace
    created_by       text        NOT NULL,
    created_at       timestamptz NOT NULL,
    updated_at       timestamptz NOT NULL,
    deleted_at       timestamptz,
    CHECK ((level = 'instance') = (tenant_id IS NULL))
);
CREATE INDEX IF NOT EXISTS scheduled_tasks_tenant ON scheduled_tasks (tenant_id) WHERE state <> 'deleted';
CREATE INDEX IF NOT EXISTS scheduled_tasks_due ON scheduled_tasks (next_due_at) WHERE state = 'on';
CREATE INDEX IF NOT EXISTS scheduled_tasks_event ON scheduled_tasks (tenant_id, scope_object) WHERE state = 'on' AND trigger_kind = 'event';

CREATE TABLE IF NOT EXISTS scheduled_task_runs (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    run_id        uuid        NOT NULL,                          -- UUIDv5(task_id, cause)
    task_id       uuid        NOT NULL,
    cause         text        NOT NULL CHECK (cause <> '' AND length(cause) <= 128),
    started_at    timestamptz NOT NULL,
    ended_at      timestamptz,
    outcome       text        NOT NULL DEFAULT 'running' CHECK (outcome IN ('running','ok','partial','failed','skipped')),
    matched       integer     NOT NULL DEFAULT 0,
    acted         integer     NOT NULL DEFAULT 0,
    failures      jsonb       NOT NULL DEFAULT '[]',
    error         text        NOT NULL DEFAULT '' CHECK (length(error) <= 500),
    tokens        bigint      NOT NULL DEFAULT 0,
    result_msg_id uuid,
    PRIMARY KEY (tenant_id, run_id)
);
CREATE INDEX IF NOT EXISTS scheduled_task_runs_task ON scheduled_task_runs (tenant_id, task_id, started_at DESC);

CREATE TABLE IF NOT EXISTS hub_settings (
    key    text        NOT NULL PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_.]{0,63}$'),
    value  jsonb       NOT NULL,
    set_by text        NOT NULL,
    set_at timestamptz NOT NULL
);
```

- **RLS**: `scheduled_task_runs` in the shape every tenant table has
  (developer guide 2.6.4); `scheduled_tasks` with the same policy for rows
  that have a `tenant_id`, and its instance rows (`tenant_id IS NULL`)
  readable only outside a tenant scope (the operator routes and the
  runner). Row S1 proves both (`TestRLSCoversEveryTenantTable`,
  `api/store/rls_test.go`).
- **Instance runs** are written once per workspace they ran in, under that
  workspace's `tenant_id`, so each workspace's history and caps read only
  its own rows.
- **Channel move or copy** (spec 169): `scheduled_tasks` and
  `scheduled_task_runs` are listed in `api/channelmove/catalogue.go`; a
  moved channel's id is removed from a staying task's `scope_where`
  (`Rewritten`), and the next run says so.
- **Next due time**: computed in Go from `trigger_kind`, `trigger_spec` and
  `tz`, never in SQL.

### 8.2 The runner

`runScheduledTasks`, one 60 s ticker started beside `runGcalSync`
(`api/hub/server.go:711`):

1. **Claim** due schedule tasks with one `UPDATE scheduled_tasks SET
   next_due_at = <next> ... WHERE state = 'on' AND next_due_at <= now() ...
   RETURNING`, so two hub instances never run the same due time (spec 182
   4.2 step 5).
2. **Check the caps** (5.3) of the task's workspace; over a cap the run is
   `skipped`.
3. **Insert the run** with `ON CONFLICT DO NOTHING` on `run_id`; a conflict
   is a second claim of the same cause and stops here.
4. **Read the scope** as the owner (4.1, 4.5) and **act** (4.3).
5. **Post the result** (6.1) and close the run row.

An event task runs steps 2 to 5 from its hook (4.2), off the request path (a
goroutine with its own context), so a post or an issue write never waits on
a task. A per-workspace "has event tasks" bit in memory, refreshed on every
task write, keeps a workspace with none at zero extra probes (spec 182 4.2
step 6); `TestRoundTripsPerRequest` proves it.

## 9. Build order

| row | depends on | kind | files | done test | red control |
|---|---|---|---|---|---|
| **S1 rdb + store** | — | `complex_coding` | `rdb/<NNNN>_scheduled_tasks.sql` (8.1 and the fifth default channel); `api/store/{scheduled_task.go,scheduled_task_postgres.go,scheduled_task_memory.go,scheduled_task_test.go,hub_settings.go}`; `api/store/channels.go` (`DefaultChannels`); `rls_test.go`; `api/channelmove/catalogue.go` | `PRE_PUSH_TIER=full`: Postgres and Memory parity; each CHECK refuses its stray value; of two concurrent claimers one gets a due task; a second run insert for the same cause is a no-op; RLS covers both tenant tables and an instance row is invisible in a tenant scope; a new and an existing workspace both have `#scheduled-tasks` | drop `next_due_at <= now()` from the claim, and the two-claimer test runs the task twice |
| **S2 grammar** | — | `simple_coding` | `api/search/{grammar.go,values.go,match.go,grammar_test.go}`, the stores' compile of the two new terms, `../003-spool-message-bus/contracts/search-v1.md` (1.7) | `idle:30d` matches a topic with no message for 31 days and not one with a message 29 days ago, in the Postgres compile and in `MatchTopic`; for an issue, by its last change; `changed:7d` is the inverse | compile `idle:` as `after:`, and the 31-day topic is not matched |
| **S3 hub runner + fixed actions** | S1 | `complex_coding` | `api/hub/{scheduled_tasks.go,scheduled_task_run.go,scheduled_task_actions.go}` and their tests; the ticker start in `server.go`; the 30-day delete chore | each trigger kind gives the right next local time, across a DST change in `Europe/Helsinki`; a missed tick runs once; each fixed action changes its object through its store path; a member's task never acts on another member's object; an owner who left skips the run and pauses the task; 5 failures pause it; the result lands in `#scheduled-tasks` as `HUB-0` and fires no task | remove the own-object check at run (4.5), and the member test archives another member's topic |
| **S4 event triggers** | S3 | `complex_coding` | the hooks in `wui.go`, `ws.go`, `issues.go` (shared with spec 182 row L2: one call per hook, each feature its own function) | a new matching message, topic and issue each run the task once; a replay, a `HUB-0` note, a loop prompt and a result post do not; `TestRoundTripsPerRequest` shows no extra round trip in a workspace with no event task | drop the "has event tasks" bit, and the round-trip test fails |
| **S5 agent action + caps** | S3 | `complex_coding` | `api/hub/scheduled_task_agent.go`, the cap read over `rdb/0171`, their tests | the prompt reaches the agent as one `task` on the run's topic with the objects quoted; the answer closes the run `ok`; no answer within the timeout closes it `failed` `no_answer`; at the run cap the next run is `skipped`; at 100 % tokens an agent run is skipped and its task pauses `cap`; the 80 % notice posts once | count fixed runs against the token cap, and the fixed-run test is skipped at 100 % |
| **S6 two levels** | S1, S3 | `complex_coding` | `api/hub/operator_tasks.go` (the 5.1 routes behind `operatorAuth`); the 5.2 settings (`RegisterTenantSetting`); `taskEffective` (5.3) | instance off stops a workspace that is on; a workspace cap above the instance's is refused and one below is used; an action off at either level is refused at save and skipped at run; an instance task runs in each listed workspace and writes one run row in each | take the higher of the two caps, and the "a workspace never raises" test fails |
| **S7 workspace routes** | S1, S3 | `simple_coding` | `api/hub/tasks_routes.go`: `GET` / `POST /v1/tasks`, `PUT` / `DELETE /v1/tasks/{id}`, `POST /v1/tasks/{id}/run`, `GET /v1/tasks/{id}/runs`, `GET /v1/tasks/preview` (the live count) | the D3 table (admin: any task; member: own objects; member on another's objects: 403); a refused query answers the grammar's error; the preview counts and writes nothing | save a member's task without narrowing its scope, and the D3 test passes on another member's objects |
| **S8 wui** | S7 | `simple_coding`, then `i18n` (agy has the last word) | `wui/components/ScheduledTasks*.vue` (list, editor, history), the Settings section, the four templates, `wui/utils/spool-client*.mjs`, `csi-spl-wui/i18n/locales/*.json` | `pnpm run typecheck`; `test:unit` (i18n parity, untranslated and raw-text gates, cleancode; the editor's required fields per trigger and action kind; the summary sentence per trigger kind) | a raw string in the editor, and `i18n-no-raw-text` fails |
| **S9 e2e** | S8 | `tests` | `csi-spl-wui/tests/e2e/scheduled-tasks.test.mjs` | on the mock: create from each template, edit, pause, resume, run now, read the history, see the result in `#scheduled-tasks` | skip the template fill, and the template test finds an empty editor |
| **S10 docs** | S3-S8 | `specs_and_docs` | this spec's row status; a help page under `csi-spl-doc/doc/help/` | `do_check_dist_hygiene`, `do_check_fleet_rules_drift` | — |

S1 and S2 run in parallel now; S3 after S1; S4, S5, S6 and S7 in parallel
after S3; S8 after S7; S9 after S8. Q1..Q11 change no column of 8.1 and no
contract of 9.1.

### 9.1 Contracts for parallel rows (binding)

A row that needs to change one asks the dispatch holder first, and the
change lands in this spec before the code. Every name below is new.

#### 9.1.1 Go store (S1 builds it; S3, S5, S6, S7 call it)

Package `store`, file `api/store/scheduled_task.go`, implemented by `Memory`
and `Postgres` (`var _ ScheduledTaskStore = (*Memory)(nil)` and
`(*Postgres)(nil)`).

```go
const (
	TaskLevelWorkspace = "workspace"
	TaskLevelInstance  = "instance"
	TaskOn             = "on"
	TaskPaused         = "paused"
	TaskDeleted        = "deleted"
	TaskMaxObjects     = 500
	TaskPromptMax      = 4000 // characters
	TaskNameMax        = 120  // characters
	TaskWhereMax       = 50   // channel ids
	TaskIntervalMax    = 10080 // minutes; the floor is the instance's tasks.min_interval_min
)

var TaskObjects  = []string{"channel", "topic", "message", "issue"}
var TaskTriggers = []string{"once", "every_n_minutes", "daily", "weekly", "monthly", "event"}
var TaskActions  = []string{"move", "archive", "label", "set_priority", "notify", "agent"}
var TaskEvents   = []string{"message_new", "topic_new", "issue_new", "issue_changed"}
var TaskOutcomes = []string{"running", "ok", "partial", "failed", "skipped"}
var TaskPauseReasons = []string{"", "by_person", "done", "owner_left", "failing", "cap"}

// ErrBadTask: a value outside the CHECKs of 8.1, a zone time.LoadLocation
// refuses, or a trigger or action spec that does not fit its kind. Before
// any write.
var ErrBadTask = errors.New("store: bad scheduled task")

type ScheduledTask struct {
	TenantID        string // "" = instance task
	TaskID          string // uuid, lower case
	Level           string
	Name            string
	OwnerID         string // member id, or HUB-0 for an instance task
	Template        string
	ScopeObject     string
	ScopeWhere      []string // empty = all channels
	ScopeQuery      string
	MaxObjects      int
	TriggerKind     string
	Trigger         TaskTriggerSpec
	TZ              string // IANA; "" read and written as "UTC"
	ActionKind      string
	Action          TaskActionSpec
	State           string
	PausedReason    string
	NextDueAt       time.Time // zero: event task, or paused
	FailStreak      int
	InstanceTenants []string // instance task: empty = every workspace
	CreatedBy       string
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// TaskTriggerSpec is trigger_spec; only the fields of its kind are set.
type TaskTriggerSpec struct {
	At          time.Time `json:"at,omitempty"`           // once
	IntervalMin int       `json:"interval_min,omitempty"` // every_n_minutes
	AtTime      string    `json:"at_time,omitempty"`      // "hh:mm": daily, weekly, monthly
	Weekdays    []int     `json:"weekdays,omitempty"`     // 1..7 = Mon..Sun: weekly
	MonthDay    int       `json:"month_day,omitempty"`    // 1..28; 0 = last: monthly
	On          string    `json:"on,omitempty"`           // event: one of TaskEvents
}

// TaskActionSpec is action_spec; only the fields of its kind are set.
type TaskActionSpec struct {
	Channel  string   `json:"channel,omitempty"`  // move
	Label    string   `json:"label,omitempty"`    // label
	Priority int      `json:"priority,omitempty"` // set_priority
	Mention  []string `json:"mention,omitempty"`  // notify: member ids
	Prompt   string   `json:"prompt,omitempty"`   // agent
	Agent    string   `json:"agent,omitempty"`    // agent: per Q3; "" = the Q3 default
}

type TaskRun struct {
	TenantID    string
	RunID       string // UUIDv5(task_id, cause)
	TaskID      string
	Cause       string // RFC 3339 due time, or the object's id
	StartedAt   time.Time
	EndedAt     time.Time // zero while running
	Outcome     string
	Matched     int
	Acted       int
	Failures    []TaskRunFailure
	Error       string
	Tokens      int64
	ResultMsgID string
}

type TaskRunFailure struct {
	Object string `json:"object"`
	Reason string `json:"reason"`
}

type ScheduledTaskStore interface {
	CreateTask(ctx context.Context, t ScheduledTask) (ScheduledTask, error)
	UpdateTask(ctx context.Context, t ScheduledTask) (ScheduledTask, error) // by (TenantID, TaskID)
	SetTaskState(ctx context.Context, tenant, taskID, state, reason string, at time.Time) error
	GetTask(ctx context.Context, tenant, taskID string) (ScheduledTask, error)
	ListTasks(ctx context.Context, tenant string) ([]ScheduledTask, error) // "" = instance tasks
	// ClaimDueTasks moves next_due_at of each due task to next(task) in the
	// claiming statement and returns the tasks as they were before the move.
	ClaimDueTasks(ctx context.Context, now time.Time, next func(ScheduledTask) time.Time, limit int) ([]ScheduledTask, error)
	EventTasks(ctx context.Context, tenant, object string) ([]ScheduledTask, error)
	StartRun(ctx context.Context, r TaskRun) (bool, error) // false: the run_id exists
	FinishRun(ctx context.Context, r TaskRun) error
	ListRuns(ctx context.Context, tenant, taskID string, limit int) ([]TaskRun, error)
	RunsSince(ctx context.Context, tenant string, since time.Time) (int, error)
	HubSetting(ctx context.Context, key string) (json.RawMessage, bool, error)
	SetHubSetting(ctx context.Context, key string, v json.RawMessage, by string, at time.Time) error
}
```

#### 9.1.2 Hub (S3 builds it; S4, S5, S6 call it)

```go
// runTask runs one claimed or event-fired task in one workspace for one
// cause; obj is the event's object, nil for a schedule. It never panics
// the ticker and always returns the run row it wrote.
func (s *Server) runTask(ctx context.Context, t store.ScheduledTask, tenant, cause string, obj *taskObject) store.TaskRun

// taskEffective answers the effective settings of 5.3 for tenant.
func (s *Server) taskEffective(ctx context.Context, tenant string) (taskLimits, error)

type taskLimits struct {
	Enabled          bool
	MembersMayCreate bool
	RunsPerDay       int
	TokensPerMonth   int64
	Actions          map[string]bool
	MinIntervalMin   int
}
```

#### 9.1.3 Wire (S7 builds it; S8 calls it)

`/v1/tasks` JSON uses the snake_case of the 8.1 columns, with
`trigger_spec` and `action_spec` as the objects of 9.1.1's JSON tags.
Errors: `400 bad_task` (naming the field), `400 bad_query` (the grammar's
message), `403 not_allowed` (D3), `409 cap_reached`, `404 not_found`.

## 10. Open questions (one form)

Each question names its recommendation, below the form.

```poll
Q1. Spec 182's topic loops and these scheduled tasks overlap (a prompt on a timer). What should happen to loops?
(A) Keep both: loops stay per topic and answer in it; tasks are workspace-wide and report in their channel; they share the event hooks
(B) Fold loops into tasks later: a loop becomes a task scoped to one topic
(C) Stop building loops; tasks replace them now
Q2. Who is the instance admin in the web UI?
(A) A person the operator flags as instance admin; they see an Instance settings page
(B) Nobody in the UI: the instance is configured only through the operator API and CLI
(C) The owners of one named workspace act as instance admins
Q3. Which agent runs a task whose action is an agent with a prompt?
(A) The agent the task names, from the workspace's agents; if it is offline, any online agent of the workspace
(B) Always the workspace's dispatcher agent
(C) A fresh agent started for each run
Q4. How are the results laid out in the scheduled tasks and activities channel?
(A) One topic per task; each run is a reply in it
(B) One topic per run
(C) One topic per day for all tasks
Q5. Who can read the scheduled tasks and activities channel?
(A) Every member, like the other default channels; a result links objects, and only those who may read an object can open it
(B) Admins, plus each task's owner for their own task's topic
(C) Admins only
Q6. Can a change made by a task (a move, an archive, a label) start another task?
(A) No: a task's own changes never start any task
(B) Yes, but never itself, at most 3 tasks deep
(C) Yes, limited only by the caps
Q7. Instance tasks run across all workspaces: do they count against a workspace's caps, and where do their results go?
(A) Not counted, the instance has its own cap; the result goes to each workspace's channel
(B) Counted against each workspace's caps; the result goes to each workspace's channel
(C) Not counted; the result goes only to the instance admin's list
Q8. Which are a member's own objects, the only ones a member's task may touch?
(A) Topics they started, messages they sent, issues assigned to them or reported by them
(B) Only messages they sent and issues assigned to them
(C) Everything they can read
Q9. The default caps per workspace, until the instance sets its own?
(A) 200 runs a day and 2 million AI tokens a month
(B) 50 runs a day and 500 thousand AI tokens a month
(C) No default: tasks stay off in a workspace until the instance sets its caps
Q10. The fixed action "label": today only issues have labels. What may a task label?
(A) Issues only
(B) Issues and topics: topics get labels
(C) Issues, topics and messages
Q11. Should a schedule also take a cron expression (for example every 30 minutes, 08-18, Monday to Friday)?
(A) Not now: once, every n minutes, daily, weekly and monthly
(B) Yes, as an advanced field beside them
```

- **Q1 A** (recommended): 182's rows are in build against binding contracts
  (182 7.1); C throws that work away, and B can still be done later without
  a change here. A touches each hot path once (4.2).
- **Q2 A** (recommended): D4 asks for an instance that sets limits; the
  operator door (`operatorAuth`) takes a service-account token, not a
  person's session, so a person needs a flag and a page. B leaves the limits
  to the CLI. C ties the instance to one workspace's members.
- **Q3 A** (recommended): a prompt is often about one area, and the agent of
  that area knows it; B loads the dispatcher with every task; C pays an
  agent start per run.
- **Q4 A** (recommended): a task's runs read as one thread, and the
  channel's topic list has one row per task, not one per run.
- **Q5 A** (recommended): it is what a default channel is today (every
  member reads it, `PublicChannels`); B and C need the channel taken out of
  `PublicChannels` and, for B, a per-topic read rule the hub does not have
  (the unit of reading is the channel). Not measured: whether every link in
  a result post is checked against the reader's rights; row S3 checks it
  and the result names an object a reader cannot read only by its id.
- **Q6 A** (recommended): with D6 (no approval) a chain can archive or move
  more than anyone meant; under A every change traces back to one task's
  scope.
- **Q7 A** (recommended): an operator's chores should not use up a
  workspace's own allowance, and the workspace still sees what was done in
  it.
- **Q8 A** (recommended): it follows the hub's own notions of "mine": the
  `assignee:me` filter (`api/search/match.go`, `OpAssignee`) and the
  topic starter of the archive policy (`ArchivePolicyStarter`,
  `api/store/tenant_settings.go`).
- **Q9 A** (recommended): room for the four templates and dozens of tasks in
  one workspace; B is tight for an hourly task plus digests; C keeps the
  feature off everywhere until the operator acts.
- **Q10 A** (recommended): issues have the label catalogue and the `label:`
  operator today; B and C need new tables and grammar work.
- **Q11 A** (recommended): the five kinds cover the basic triggers of the
  Windows Task Scheduler; a cron field adds a parser dependency and does not
  read well in the editor's summary sentence (6.3).

## 11. Not in this spec

- Moving any box cron or hub timer into tasks (section 2).
- A run shown in the Calendar as an event; a later spec may add it.
- External actions (mail, webhooks, other systems): an agent task does what
  its agent can do; nothing is added here.
- A dry run or an approval step (D6).
- Tasks over objects other than channels, topics, messages and issues
  (docs, files, contacts).

## 12. Risks

- **D6 with a wide scope**: one run can archive many topics. Bounded by
  `max_objects` (default 100), the live count in the editor, the list of
  every changed object in the result post, and Q6 A.
- **Agent token spend**: an agent task on a busy channel can use a month's
  cap in days. Bounded by the D7 cap and its 80 % notice (5.3); spec 121's
  budget still applies.
- **Hot-path cost of event triggers**: bounded by the in-memory "has event
  tasks" bit and the round-trip test (S4).

## 13. Changes

- v0.1 (2026-11-20): first draft; D1-D8 from poll `38083eff`; Q1-Q11 open.
- v0.2 (2026-11-20): review m-181 (msg `7f5dce3f`) folded: W1 spec 182 has 11
  triggers, not 12; W2 `server.go` and `operator.go` lines re-read on
  `origin/master` `d6b810775`; N1 the owner rule quotes 182 4.5; N2 rdb head
  `0300`; N3 the number check names this lane's own worktree. Q1-Q11 unchanged.
