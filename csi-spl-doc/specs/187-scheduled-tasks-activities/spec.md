# Spec 187: Scheduled Tasks and Activities

Status: **Decided v0.8** (2026-11-27). Lanes `c-150` (v0.1, v0.2),
`c-660` (v0.3) and `c-074` (v0.4 the build plan's form, v0.5 its review,
v0.6 the owner's answer to Q1b, v0.7 to Q1c), `claude`, backup for
`specs_and_docs` (agy held by the placer). Questions answered: 1.1.2 to
1.1.5; none is open (1.2). Nothing below is built.
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
`d6b810775` (v0.2); every claim v0.3 adds or changes was read on
`origin/master` `325a47c76`; every claim v0.4 and v0.5 add on `5adcd5fdd`; every claim v0.6 adds on
`208e5f757`.

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

## 1. Decided

### 1.1 The owner's answers

Quoted verbatim; this spec applies them and does not re-ask them.

#### 1.1.1 D1-D8 (poll `38083eff`; msgs `2cc2dea2` and `19171767`)

| # | Answer (verbatim) | What it decides here |
|---|---|---|
| D1 | "A — Both: a fixed action (move, label, archive, notify) or an agent with your prompt" | 4.3: two action kinds, fixed and `agent` |
| D2 | "A — Time and events: a new message, topic or issue that matches the scope" | 4.2: schedule triggers and event triggers |
| D3 | "A — Workspace admins; members may create tasks that touch only their own objects" | 4.5: who may create, the own-objects rule |
| D4 | "A — The instance sets defaults and limits, and can also run tasks across all workspaces; workspaces work within those limits" | section 5: the two levels, the instance wins |
| D5 | "It should be in the scheduled tasks and activities new channel for a workspace." | 6.1: a new default channel per workspace receives every run's result (its name: D13) |
| D6 | "B — Anything, no approval" | 4.3: no dry run, no approval step; a run acts at once, within its scope and its owner's rights |
| D7 | "A — A cap on runs per day and on AI tokens per month, per workspace, set at instance level" | 5.3: two caps per workspace, set by the instance |
| D8 | "A — Yes: daily digest of a channel, nudge stale issues, archive idle topics, weekly status report" | section 7: four templates at launch |

D6 is not the option the form recommended. What it gives up (a dry run, an
approval) is replaced only by what D3, D7 and 4.6 already hold: a task never
acts beyond its owner's rights, beyond its scope, or past the caps, and
every change a run makes is written to the run's history and posted in the
channel (D5), so it can be seen and undone by hand.

#### 1.1.2 D9-D20: the answers to Q1-Q11 of v0.2 (HUM-10, t1 91992830, 2026-11-20)

The form of v0.2 section 10 (poll `558a4577`), answered in msg
`f81b6c38-da1b-42ec-8cfb-3347a86812a6`, verbatim:

> Answer 1: A — Keep both: loops stay per topic and answer in it; tasks are workspace-wide and report in their channel; they share the event hooks
> Answer 2: C — The owners of one named workspace act as instance admins
> Answer 3: A — The agent the task names, from the workspace's agents; if it is offline, any online agent of the workspace
> Answer 5: A — Every member, like the other default channels; a result links objects, and only those who may read an object can open it
> Answer 6: B — Yes, but never itself, at most 3 tasks deep
> Answer 7: A — Not counted, the instance has its own cap; the result goes to each workspace's channel
> Answer 8: A — Topics they started, messages they sent, issues assigned to them or reported by them
> Answer 9: B — 50 runs a day and 500 thousand AI tokens a month
> Answer 10: C — Issues, topics and messages
> Answer 11: B — Yes, as an advanced field beside them

Q2 in chat, msg `fe41bdc8-b16d-4db1-958c-b030a8937194`, verbatim: "The whole
cloud instance admin is the person who is the admin of the t1 - aka the
spool-hub main workspace , a workspace admin is the person who is having the
role of workspace admin role".

Q4 in chat, msg `5fa95db3-1c69-4ba7-a8cc-04f37360a84a`, verbatim: "each
workspace should have the scheduled-runs named channel , the posts should go
there".

| # | Q | Answer | What it decides here |
|---|---|---|---|
| D9 | Q1 | A (msg `f81b6c38`) | Loops (spec 182) and tasks are two objects; they share the event hooks (4.2). Folding loops into tasks is out (section 11). |
| D10 | Q2 | C (msg `f81b6c38`), the workspace named **t1** (msg `fe41bdc8`) | 5.1: an instance admin is a member of `t1` whose role holds `tenant.settings`, the same test as a workspace admin (4.5); no separate flag. |
| D11 | Q3 | A (msg `f81b6c38`) | 4.3: the task names an agent of its workspace; offline, any online agent of the workspace runs it. |
| D12 | Q4 | **A (default, the owner did not pick; holder post 921ac359)** | 6.1: one topic per task in the channel; each run is a reply in it. |
| D13 | Q4 | the channel is named `scheduled-runs` (msg `5fa95db3`) | 6.1: the D5 channel's id is `scheduled-runs` in every workspace. |
| D14 | Q5 | A (msg `f81b6c38`) | 6.1: every member reads `#scheduled-runs`; each linked object opens only for a reader who may read it. |
| D15 | Q6 | **B** (msg `f81b6c38`) | 4.2.2: a change made by a run may fire another task, never the same task, at most 3 tasks deep. |
| D16 | Q7 | A (msg `f81b6c38`) | 5.3: instance runs do not count against a workspace's caps; the instance has its own caps; each workspace's `#scheduled-runs` gets the result. |
| D17 | Q8 | A (msg `f81b6c38`) | 4.5: a member's own objects. |
| D18 | Q9 | **B** (msg `f81b6c38`) | 5.1: the default caps are 50 runs a day and 500 000 AI tokens a month per workspace. |
| D19 | Q10 | **C** (msg `f81b6c38`) | 4.3.1: `label` applies to issues, topics and messages; topics and messages get labels (a store change, row S11). |
| D20 | Q11 | **B** (msg `f81b6c38`) | 4.2.1: a 5-field cron expression as an advanced trigger beside the five kinds (row S12). |

D15, D18, D19 and D20 are not the options the form recommended. What each
adds is spelled out in the section named, with its own build row or red
control: D15 the chain depth (4.2.2, row S4), D18 the defaults (5.1, row
S6), D19 the label store (4.3.1, row S11), D20 the cron grammar (4.2.1, row
S12).

#### 1.1.3 D21-D22: the build plan's form (poll `bb3b76c2`, HUM-10, t1 91992830, 2026-11-25)

The build plan (`csi-spl-doc/doc/md/spec-187-build-plan.md` 2.4) asked
three questions; Q1 and Q2 change this spec, Q3 (round size, A: one plan)
changes only the plan. Verbatim, as relayed by the dispatch holder c-002:

- Q1 (msg `7b63c45e`): "There should be a scheduled tasks option in the
  right-click menu, both on the channels and on the topic level." The
  owner's own option, neither A nor B.
- Q2 (msg `e17e6c09`): "Answer 2: B — A new field, mention_assignee (yes or
  no)".

| D | Q | answer | where it lands |
|---|---|---|---|
| D21 | plan Q1 | the owner's own words (msg `7b63c45e`) | 6.2: a "Scheduled tasks" item in a channel's right-click menu lists that channel's tasks, and in a topic's right-click menu that topic's tasks; the filter is S7's, the items S8's. |
| D22 | plan Q2 | **B** (msg `e17e6c09`) | 4.3 and 9.1.1: `notify` gets a yes/no field `mention_assignee`; template 7.2 sets it. A contract change: rows S1 (the struct), S3 (the mention), S7 (the save check), S8 (the editor and the template). |

#### 1.1.4 D23: plan question Q1b (HUM-10, t1 91992830, 2026-11-25)

The owner first answered the poll (`9d48f04f`) with B (msg `b6acff79`,
09:40:43Z: "Open \"Settings > Scheduled tasks\" to every member"), then
withdrew it; the withdrawal is the answer (msg
`6b1806e4-654e-419e-81c1-e60b6ff17f71`), verbatim:

> "no no sorry , not b , the scheduled tasks should be accesible via a
> dialog box , which could be set per discussion/topic and per channel ,
> and per issue , and per epic"

Neither A nor B: the owner's own option.

| D | Q | answer | where it lands |
|---|---|---|---|
| D23 | plan Q1b | the owner's own words (msg `6b1806e4`); B withdrawn | 6.2: ONE "Scheduled tasks" dialog, opened per topic, per channel (D21's menus), per issue and per epic (new entries); Settings stays admin-only (6.2 Workspace, unchanged). Two issue operators `key:` and `epic:` bind a task to an issue or an epic (7, row S2); `GET /v1/tasks` takes `?issue=` and `?epic=` (9.1.5, row S7); the dialog and the issue and epic entries are row S8's; S9 opens all four. |

The question as asked (v0.5 1.2): "Where does a member who is not an
admin list and create the tasks the D21 menus do not reach: tasks over all
channels, and every `issue` task". D23 answers it for issue tasks bound to
an issue or an epic; what it left without a member's entry was Q1c,
answered by D24 (1.1.5).

#### 1.1.5 D24: plan question Q1c (HUM-10, t1 91992830, 2026-11-25)

The poll (`a717edfb`), answered in msg
`c5143a2f-3a49-45d7-832f-85fa35c37fb0`, verbatim: "Answer: A — Admins
only: a member's save is refused, and a member makes such a task per epic
or per channel". The recommended option.

| D | Q | answer | where it lands |
|---|---|---|---|
| D24 | plan Q1c | **A** (msg `c5143a2f`) | 4.5 and 6.2: a task with an unbound scope (a `topic` or `message` task over all channels; an `issue` task whose query holds no positive `key:` or `epic:` leaf) is admin-only; row S7's save check answers a non-admin's `403 not_allowed` (one more D3 row). A member makes such a task per epic (`epic:<KEY>`) or per channel instead, from that object's dialog. Every member's task therefore shows in a dialog. No fifth entry, no extra filter. |

### 1.2 Open

None. Q1c, as it was asked, is in 1.3.

D12 is a default the holder chose and told the owner (post
`921ac359`); a later owner word on the grouping changes only 6.1's topic
rule, no column and no contract.

### 1.3 Q1b and Q1c as they were asked (answered, D23 and D24)

- **Q1c (plan question; spots S7, S8 and S9; no batch waits on it: the
  rows are built with A, and B changes S7, S8 and S9).** Under D23 a
  member reaches a task only through the dialog of an object its scope
  names. No dialog lists: (a) a `topic` or `message` task whose `where` is
  all channels (a task naming several channels lists in each named
  channel's dialog, `?channel=`, 9.1.5; a dialog's "New task" makes a
  one-channel task); (b) an `issue` task whose query holds no positive
  `key:` or `epic:` leaf. Templates 7.2, 7.3 and 7.4 as written are (a) or
  (b); opened from a dialog they take its object's scope instead (7.3 from
  a channel: that channel; 7.2 and 7.4 from an epic: `epic:<KEY>`, from an
  issue: `key:<KEY>`). An admin reaches every task in Settings (6.2); a
  `channel` task is admin-only already (4.5).
  - **A (recommended)**: (a) and (b) are admin-only. S7's save check
    answers a non-admin's (a) or (b) task `403 not_allowed` (one more D3
    row: "member, unbound scope: 403"), so every member's task shows in a
    dialog. Cost: a member's task over all their issues (e.g. 7.2 on every
    issue assigned to them) is made per epic.
  - **B**: members keep (a) and (b) (D17's own-object narrowing still
    applies), and S8 adds a fifth entry that opens the same dialog with
    the member's unbound tasks (e.g. an item in the user menu,
    `wui/components/UserMenu.vue`), over a filter S7 adds for them. Cost:
    one more entry and filter, and S7's refusal comes out again.
  Answered by D24 (1.1.5): A.

- **Q1b (plan question, spot S8 only; batches 1-5 do not wait on it).**
  Where does a member who is not an admin list and create the tasks the
  D21 menus do not reach: tasks over all channels, and every `issue` task
  (`where` is all only for issues, 4.1), which D17 lets a member own
  (templates 7.2, 7.4)? Every Settings section is gated by an admin
  permission (`wui/utils/tenant-settings-nav.ts:28-40`, `filterByPerm`
  `:69`), and `csi-spl-wui/tests/unit/tenant-settings.test.mjs:31` pins
  "CONTROL: a developer sees no entry". A: Settings stays admin-only, and
  members get a non-Settings entry for those tasks (e.g. the
  `#scheduled-runs` channel menu or the Issues header). B: "Settings ->
  Scheduled tasks" opens to every member (that test changes, and Settings
  shows in the sidebar, user menu, lobby and command palette for
  non-admins). Answered by D23 (1.1.4): neither, one dialog.

## 2. What exists, and how this differs or reuses

Not re-specified here; this spec reuses or stays clear of each.

| what | where | relation to this spec |
|---|---|---|
| **Topic loops** (spec 182): a saved prompt on ONE topic, fired by 11 triggers (after and before an agent reply, after a human reply, every hour, every n minutes, daily at, no reply after a human post, keyword, file, blocker, issue status; 182 spec 1.2), cap 12 per hour, sent hidden to the topic's agent | `../182-topic-loop-prompt/spec.md` sections 1.2, 4, 5; its store has landed: `rdb/0301_topic_loops.sql` (182 row L1) | **A different object, a shared pattern (D9).** A loop lives on one topic and answers in it. A scheduled task lives on the workspace (or the instance), its scope is a filter over many objects, it may run a fixed action without any agent, and it reports in its own channel (D5). Reused: 182's ticker and claim (one `UPDATE ... RETURNING` per tick, no catch-up burst, a UUIDv5 of the cause as the id), its time-zone rule and its event hooks (4.2). Loops are not folded into tasks. |
| **Day's tasks** (spec 170): a To-do view in the Calendar of issues by deadline; the morning card dropped (poll `acef24b9`) | `../170-day-tasks-reminder/spec.md` 1.2, 11.4 | **Reused by a template**: "nudge stale issues" (7.2) reads the same issues and links the To-do view `/calendar?k=todo&v=day`. Nothing in 170 changes. |
| **Activity issues** (spec 174): `issues.kind = activity`, the standing duty of a fleet role seat, synced from `csi-spl-orc/cnf/role-activities/activities.tsv` | `../174-activity-issues/spec.md` 3.1, 3.2 | **The same word, a different thing.** 174's activity is the *definition* of a role seat's duty and has no runs. This spec's "activities" are the runs of a scheduled task. A 187 run is never written as an `issues` row of kind `activity`. |
| **Reporter role** (spec 177): a cron-spawned agent with a checklist, writing reports and daily per-member task notes | `../177-reporter-role/spec.md` section 0 | **A fleet job on a box.** Template "weekly status report" (7.4) is the workspace-level, person-configured form of a report; the Reporter stays as it is. |
| **Calendar** (specs 089, 097, 119 section 15): events with a time zone, reminders, the Google sync on its own 60 s ticker | `api/store/calendar.go:156` (`TimeZone`, "" is UTC); `api/hub/gcal_sync.go:44` (`gcalSyncEvery = 60 * time.Second`), `:80` (its ticker), started at `api/hub/server.go:711` | **Reused**: the 60 s ticker pattern and the IANA-zone rule. A task is not a calendar event and is not shown in the Calendar (section 11). |
| **The hub's own timers** | `RunSweeper` (`api/hub/server.go:700`): retention, file, demo and backfill tickers and the chores of each sweep; also `presence.go:41`, `blocker_issue.go:94`, `repo_sync.go:138`, `operator_deploys.go:316`, the `marketing_*` dispatchers, `relay.go:82` | Each is fixed system upkeep that no person configures. The task runner is ONE new ticker beside them (row S3); none of them moves into it. |
| **The fleet's box crons** | 29 actions `csi-spl-orc/src/bash/run/*install-cron*.func.sh` (`ls ... \| wc -l` -> 29): disk sweep, env order, dispatch and orch rotate, spawn place / fill / remote, unanswered sweep, review go, topic archive suggest, cost rollup, ... | **Fleet upkeep on agent boxes, out of scope.** They run on a box as the box user and know the box; a scheduled task runs in the hub for a workspace and knows only spool-hub objects. None is migrated (section 11). `do_spl_topic_archive_suggest` (`spl-topic-archive-suggest.func.sh`) is the nearest neighbour of template 7.3; the template is per workspace and person-configured, the cron stays. |
| **Token budgets** (spec 121 section 7): per-workspace and per-channel `tokens_per_day` / `tokens_per_month`, checked before every agent turn, `429 token_quota`, one 80 % notice | `api/store/token_budget.go` (`BudgetLimitMonth`), `api/hub/token_budget.go` (`tokenBudget`), the ledger `rdb/0171_usage_events.sql`, `meterTurn` `api/hub/usage_events.go:43` | **Reused for the D7 token cap**: an agent run is an agent turn, metered by the same ledger. The task cap is its own limit, read from the same ledger (5.3). |
| **Workspace settings registry** (spec 098) | `RegisterTenantSetting` `api/store/tenant_kv.go:84`; `TenantSettingDef` `:57` (Default, Min, Max, OneOf) | **Reused** for the workspace-level settings (5.2). |
| **Operator routes**: hub calls authorised by a Google ID token whose verified email is in `OperatorEmails` | `api/hub/operator.go:37` (`operatorEnabled`), `:43` (`operatorAuth`) | **Reused** as the instance level's door for service accounts and the CLI (5.1). A person in the web UI comes through the D10 door instead: a `t1` admin's session. |
| **Workspace admin role**: the roles holding `tenant.settings` | `api/rbac/rbac.go:27` (`TenantSettings`); held by `biz_owner` (`:272`) and `admin` (`:279`) in `Defaults` (`:270`) | **Reused** for 4.5 (workspace admin) and D10 (instance admin = that test in `t1`). The `t1` id is not hard-coded: a hub config `SPOOL_HUB_INSTANCE_ADMIN_WORKSPACE` (default `t1`), in the shape of `MemberCardNameOnlyWorkspaces` (`api/config/config.go:549`, `envDefault:"t1"`). `t1` is a workspace, not `store.SystemTenant` (`api/store/system_tenant.go:10`, `"system"`). |
| **Default channels** `#lobby`, `#alerts`, `#feedback`, `#public`: seeded by a tenant trigger; every member reads them without a membership row; the hub posts in them as `HUB-0` | `rdb/0173_default_channel_public.sql` (`spool_seed_default_channels`, its last definition on `325a47c76`); `DefaultChannels` and `PublicChannels` `api/store/channels.go:44,49`; `PostPublicNotices` `api/hub/public_notice.go:27` (signed `box-wui`) | **Reused**: the D5 channel is a fifth default channel, seeded the same way (6.1). The retired `#tasks` id (`ChannelTasks = "tasks"`, `channels.go:40`, "can never be created again") is NOT reused: the new id is `scheduled-runs` (D13; `git grep -c scheduled-runs origin/master` -> 0 before this spec). |
| **Labels**: one catalogue per workspace, used by issues only | `rdb/0047_issues.sql:33` (`issue_labels`: `tenant_id`, `label_id` slug, `name`, `color`), `:59` (`issues.labels text[]`, at most 20); grammar `label:` applies to `TypeIssue` only (`api/search/grammar.go:204`), matched in `MatchEntity` (`api/search/match.go:221`). No label column or table for topics or messages: `git grep -E "(tags\|labels)\s+text\[\]\|topic_labels\|message_labels" origin/master -- 'rdb/*.sql'` -> only `0047_issues.sql:59` | **Extended (D19)**: topics and messages take labels from the SAME catalogue (4.3.1), so there is one label model, not two. |
| **Topic metadata tables** keyed `(tenant_id, task_id)` | `rdb/0214_topic_priorities.sql:27` (`topic_priorities`) | **The shape reused** by `topic_labels` (4.3.1). |
| **Search grammar**: one Gmail-style query language with in-memory matchers | `api/search/grammar.go` (`Version = "1.6"`, `:21`); `MatchMsg` `api/search/match.go:87`, `MatchTopic` `:162`, `MatchEntity` `:191`; operators `type: from: to: box: in: is: has: topic: before: after: on: title: name: ext: larger: smaller: status: prio: assignee: label:` | **Reused as the scope's condition language** (4.1): the Outlook-rule half. One grammar, no second parser. |
| **Object actions** behind routes today | `POST /v1/messages/{msg_id}/move`, `PUT` / `DELETE /v1/messages/{msg_id}/archive`, `PATCH /v1/messages/{msg_id}/kind`, `PUT /v1/topics/{task_id}/priority`, `POST /v1/issues/{ref}/archive`, `PUT /v1/channels/{channel}/archive`; topic archive `handleArchiveTopic` (`api/hub/topic_archive.go`); issue writes `createIssue` / `updateIssue` (`api/hub/issues.go:353,419`) | **Reused**: each fixed action calls the store path its route calls, under the owner's rights (4.3, 4.5). |
| **Cron parsing** | no cron module in the hub: `grep -ciE "cron" csi-spl-api/src/go/spool-hub-api/go.mod` -> 0 | **New, no dependency** (4.2.1, row S12). |

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
  monthly, at a time in a zone, or a cron expression, D20) or an **event** (a
  new message, topic or issue that matches the scope, D2).
- **Action**: **fixed** (move, archive, label, set priority, notify) or
  **agent** (the task's prompt plus the matched objects, sent to an agent,
  D1).
- **Run**: one execution of a task: the objects it matched, what it did to
  each, its outcome (`ok`, `partial`, `failed`, `skipped`), the tokens it
  used, its chain (D15) and the message it posted in the channel. A run is
  an **activity** in the UI's words.
- **Chain**: the tasks whose runs led to this run, oldest first (4.2.2). An
  ordinary run's chain is empty; its depth is 1.
- **Owner** of a task: the member who created it, or who last edited it
  (as a loop's author in spec 182 4.5: "the editor becomes its author"); `HUB-0` for an instance task.
- **Workspace admin**: a member whose role holds `tenant.settings`.
  **Instance admin** (D10): a workspace admin of `t1`.

## 4. The task

### 4.1 Scope (which objects)

| field | values | meaning |
|---|---|---|
| `object` | `channel`, `topic`, `message`, `issue` | one type per task |
| `where` | all, or a list of 1..50 channel ids | the channels the scope reads; for `issue`, all only (issues are workspace-wide) |
| `query` | a search-grammar string, at most 512 UTF-16 units (`MaxQueryUnits`, `api/search/grammar.go`) | the conditions, e.g. `from:HUM-3 has:file`, `status:wip`, `is:task in:#ops`, `label:urgent` (on every object type, D19) |
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
| `cron` | `cron` (5 fields, 4.2.1), `tz` | at each minute the expression names, in `tz` (D20; an advanced field in the editor) |
| `event` | `on`: `message_new`, `topic_new`, `issue_new`, `issue_changed` | when such an object is stored and matches the scope (D2) |

- **Time zone**: an IANA name, checked with `time.LoadLocation` before the
  write; "" is UTC. The editor defaults it to the browser's zone, as spec
  182's `daily_tz`. A local time that does not exist on a DST day runs at
  the next valid minute; one that occurs twice runs once.
- **The 15-minute floor** of `every_n_minutes` is an instance setting (5.1).
  Spec 182's floor of 5 is for one topic; a task may scan a whole workspace.
  The same floor binds `cron` (4.2.1).
- **Missed runs**: a schedule missed while no hub instance ran runs once at
  the next tick, never as a burst (spec 182 4.2 step 5).
- **Event hooks** are the ones spec 182 4.2 names, so each hot path gets one
  hook for both features (D9): `message_new` and `topic_new` in
  `wuiAfterStore` (`api/hub/wui.go`, after the store) and in `onSend` after
  `commitRowTyped` (`api/hub/ws.go`); `topic_new` when the stored row is the
  first on its task id; `issue_new` in `createIssueOn`, `issue_changed` in
  `updateIssue` (`api/hub/issues.go:360,419`). Only an inserted row fires (a
  replay does not).
- **Never a trigger**: a `HUB-0` note, a loop prompt message (spec 182 5.2),
  a run's own result post (6.1), and a change made by a run that the chain
  rule refuses (4.2.2).

#### 4.2.1 The cron field (D20)

An advanced field beside the five kinds: the editor shows it under
"Advanced", the five kinds stay the first choice.

- **Grammar**: exactly 5 fields separated by single spaces or tabs, the
  POSIX `crontab` order: minute `0-59`, hour `0-23`, day of month `1-31`,
  month `1-12`, day of week `0-7` (`0` and `7` = Sunday). Each field is `*`,
  a number, a range `a-b`, a step `*/n` or `a-b/n`, or a comma list of
  these. Nothing else: no seconds or year field, no names (`MON`, `JAN`), no
  macros (`@hourly`), no `L`, `W`, `#` or `?`. At most 64 characters.
- **Day rule**: when both day of month and day of week are restricted (not
  `*`), a day matches if EITHER matches (the classic cron rule); when one is
  `*`, only the other counts.
- **Time zone**: the expression is read in the task's `tz` (the rule
  above: "" is UTC; a nonexistent DST minute runs at the next valid minute;
  a repeated one runs once).
- **The floor**: at save, the hub walks the expression's fire times over the
  next 366 days from now in `tz`; any two consecutive fire times closer
  than the effective `tasks.min_interval_min` (15, 5.1) refuse the save
  (`*/15 * * * *` is accepted; `*/5 * * * *` and `0,10 * * * *` are refused).
  An expression with no fire time in 366 days (`0 0 30 2 *`) is refused.
- **Validation** answers `400 bad_task` naming the field `cron` and the
  reason (`fields`, `range`, `syntax`, `floor`, `never`); the editor shows the
  next three fire times in `tz` before save.
- **Parser**: a new package `api/taskcron` (parse, `Next(after, loc)`), no
  new module dependency (section 2, cron row). The summary sentence (6.3)
  reads "On the cron schedule `*/30 8-18 * * 1-5` (Europe/Helsinki); next:
  <three times>".

#### 4.2.2 Task chains (D15)

A change made by a run (a fixed action's move, archive, label or priority;
a `notify` post is a result post and fires nothing) may fire another task's
event trigger, **never the same task, at most 3 tasks deep**.

- **The chain is carried per run**: `scheduled_task_runs.chain` (8.1) is the
  list of task ids whose runs led to this run, oldest first; an ordinary run
  (a schedule, or an event a person or an agent caused) has `{}`, depth 1.
- A fixed action applies its change with the run's chain plus its own task
  id in the request context (`taskChainKey`); the event hook reads it and
  gives each run it fires that list as its `chain`.
- **Refused**: a run whose chain already holds its own task id (directly,
  A -> A, or round a cycle, A -> B -> A) is written `skipped` with error
  `chain_self`; a run whose chain holds 3 task ids (it would be the 4th
  task deep) is written `skipped` with error `chain_depth`. Neither acts or
  posts; both are in the task's history.
- A change an agent makes during an agent run is the agent's, as any agent
  post is: it carries no chain (the hub cannot tie it to the run), so it
  starts at depth 1. It is bounded by the caps (5.3) and by the rule that
  posts in `#scheduled-runs` fire nothing (6.1). A risk, section 12.
- Red control (row S4): tasks A, B, C, D, where A's change fires B, B's
  fires C and C's fires D; A, B and C run, D's run is `skipped`
  `chain_depth`; with the depth check removed, D runs and the test fails.

### 4.3 Action (what runs)

**Fixed** (D1), one action per task, applied to every matched object:

| action | objects | does | path reused |
|---|---|---|---|
| `move` | message | moves it to the named channel | `POST /v1/messages/{msg_id}/move` |
| `archive` | message, topic, issue, channel | archives it | `PUT /v1/messages/{msg_id}/archive`, `handleArchiveTopic`, `POST /v1/issues/{ref}/archive`, `PUT /v1/channels/{channel}/archive` |
| `label` | issue, topic, message (D19) | adds the named label from the workspace's label catalogue | `updateIssue`; for a topic or a message the new label store (4.3.1) |
| `set_priority` | topic, issue | sets the priority | `PUT /v1/topics/{task_id}/priority`, `updateIssue` |
| `notify` | any | posts in the task's topic in `#scheduled-runs` (6.1) naming the matched objects, `@`-mentioning listed members and, with `mention_assignee` on (D22), each matched object's assignee: an issue's `assignee`, a topic's starter, a message's sender; an issue with no assignee is named "unassigned" and mentions no one; a member mentioned twice is mentioned once; refused at save for `object = channel` (`400 bad_task`, in the save check every level shares, so instance tasks too) | a hub post as `HUB-0`, the `PostPublicNotices` path |

#### 4.3.1 Labels on topics and messages (D19)

Today only issues carry labels (section 2, labels row). D19 adds them to
topics and messages. The store change, built by row S11:

- **One catalogue**: the label a topic or a message carries is a `label_id`
  of the workspace's existing `issue_labels` catalogue (`rdb/0047`). No
  second catalogue, so a label means the same on an issue, a topic and a
  message; the catalogue's editor stays where it is. (The table keeps its
  name: renaming it touches every issue path for no gain.)
- **Two new tables** (8.1): `topic_labels (tenant_id, task_id, label_id)` in
  the shape of `topic_priorities` (`rdb/0214`), and `message_labels
  (tenant_id, msg_id, label_id)`; each row references
  `issue_labels (tenant_id, label_id)` `ON DELETE CASCADE` (a label removed
  from the catalogue leaves no object), at most 20 labels per object (the
  issues' cap, enforced in the store), RLS in the tenant shape.
- **Why rows, not a `labels text[]` column** as on `issues`: `messages` is
  the hub's largest table and its rows are written once; a column would
  rewrite no row but put a GIN index on the hot insert path. Rows touch
  only the labelled objects.
- **Grammar 1.7** (with `idle:` and `changed:`, row S2): `label:` applies to
  `TypeMessage`, `TypeTopic` and `TypeIssue`; the Postgres compile reads the
  two tables with `EXISTS`; `MatchMsg` and `MatchTopic` take the object's
  labels from the hook's object.
- **Routes**: `PUT` / `DELETE /v1/topics/{task_id}/labels/{label_id}` and
  `/v1/messages/{msg_id}/labels/{label_id}`, behind `issues.edit` (the
  permission that edits an issue's labels, `rdb/0223_tenant_role_grants.sql:46`)
  and the object's read right. The web UI shows a topic's and a message's
  labels as the issue chips do; the chips and their i18n keys are row S8's.
- **Channel move or copy** (spec 169): both tables are listed in
  `api/channelmove/catalogue.go`; a label missing in the target catalogue is
  created there by the move.

**Agent** (D1, D11): the task's **prompt** (1..4000 characters) and the
matched objects (each as a link and a 600-character quote, at most
`max_objects`) go to an agent as one `kind: task` message on the task's
topic in `#scheduled-runs`, signed `box-wui` with `dispatchEnvelope` and
stored with `commitRowTyped`, as spec 182 4.3 step 2. **Which agent (D11)**:
the agent the task names (`action_spec.agent`), chosen in the editor from
the workspace's agents; if it is offline at the run (the hub's presence,
`api/hub/presence.go`), any online agent of the workspace, the one seen
most recently; with none online the run ends `failed` with reason
`no_agent` (and is retried once, 4.6). The run records which agent ran it.
The agent answers in that topic; its answer is the run's result. The agent
acts with its own rights in the workspace; the prompt is the owner's
instruction, as any `@agent` post is.

**No approval, no dry run (D6).** A fixed action is applied as the run
finds each object. Before save, the editor shows how many objects the scope
matches now (one read-only search): a count, not an approval step.

### 4.4 State: pause, resume, delete

- `on` or `paused`. Pause keeps everything; resume computes the next due
  time from now (no catch-up).
- The hub pauses a task with a reason the list shows: `done` (a `once` task
  ran), `owner_left` (the owner left the workspace or lost the right of
  4.5), `failing` (5 runs in a row `failed`), `cap` (a cap of 5.3 is
  reached; the task resumes itself when the window rolls over),
  `channel_moved` (a channel move took the task's only channel, or the
  channel its `move` action names; 8.1, rdb `0333`).
- Delete is soft: the row and its runs are kept 30 days, then a new chore in
  `RunSweeper`'s sweep removes them.

### 4.5 Who may create and edit (D3, D17, D24)

- **Workspace admins** (a role holding `tenant.settings`, `api/rbac/rbac.go:27`)
  create, edit, pause and delete any workspace task.
- **A member** creates and edits tasks that touch only their **own
  objects (D17)**, and only with a bound scope (**D24**): a `topic` or
  `message` task names its channels (not all), an `issue` task holds a
  positive `key:` or `epic:` leaf; a member's unbound task is refused at
  save with `403 not_allowed`. The check is syntactic: one positive leaf
  anywhere binds the query (`key:SPL-1 OR status:wip` is bound, lists in
  `SPL-1`'s dialog, and D17 still narrows it to the member's own issues). The member's own objects are: the topics they started (the starter of the archive
  policy, `ArchivePolicyStarter`, `api/store/tenant_settings.go:49`), the
  messages they sent (`from`), and the issues assigned to them (`assignee`)
  or reported by them (`created_by`, `rdb/0047_issues.sql`). A task whose
  object is `channel` is admin-only. It is enforced twice: at save, the
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

- One `scheduled_task_runs` row per run (8.1): start, end, cause, chain,
  matched and acted counts, outcome, failures, error text (at most 500
  characters), tokens, the agent that ran it, and the msg_id of its result
  post.
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

### 5.1 The instance level (D10)

**Who** (D10, msgs `f81b6c38` and `fe41bdc8`): an instance admin is a
member of the workspace `t1` ("the spool-hub main workspace") whose role
holds `tenant.settings`, the same test as a workspace admin (4.5), read at
each request; no separate flag, no new role. The workspace id is the hub
config `SPOOL_HUB_INSTANCE_ADMIN_WORKSPACE` (default `t1`, section 2), so a
test or a fresh instance can name another. Two doors reach the same
handlers:

- a person in the web UI: their `t1` session (`instanceAdminAuth`, new),
  which answers `403 not_allowed` to a member who is not a `t1` admin;
- a service account or the CLI: `operatorAuth` (`api/hub/operator.go:43`),
  as v0.2.

The instance holds:

| setting | default | meaning |
|---|---|---|
| `tasks.enabled` | true | the switch for every workspace |
| `tasks.runs_per_day.default` | **50** (D18) | the D7 run cap of a workspace with no override |
| `tasks.tokens_per_month.default` | **500000** (D18) | the D7 AI-token cap, the same way |
| per-workspace overrides of both caps | none | the instance raises or lowers one workspace's caps (D7: "set at instance level") |
| `tasks.instance.runs_per_day` | 50 | the instance tasks' own run cap (D16), counted over all their runs in all workspaces; not an owner value: the instance admins change it |
| `tasks.instance.tokens_per_month` | 500000 | the instance tasks' own AI-token cap (D16), the same way |
| `tasks.max_per_workspace` | 100 | tasks per workspace, deleted ones not counted |
| `tasks.min_interval_min` | 15 | the floor of `every_n_minutes` and of `cron` (4.2.1) |
| `tasks.max_chain_depth` | 3 | D15; may be set lower, never higher than 3 |
| `tasks.allowed_actions` | the five fixed and `agent` | an action switched off everywhere |
| `tasks.agent_run_timeout_min` | 30 | 4.6 |
| `tasks.history_days` | 90 | 4.6 |
| **instance tasks** | none | tasks the instance runs across all workspaces, or a listed set (D4) |

Stored in one new table, `hub_settings` (8.1): key, JSON value, set by, set
at. It has no tenant column: only the instance routes and the runner read
it. The routes, each behind either door: `GET` / `PUT
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
   lower of the instance's (its override, else its default: 50 runs a day,
   500 000 tokens a month, D18) and the workspace's own. A workspace never
   raises a cap ("workspaces work within those limits", D4).
3. **A set takes the intersection**: an action is allowed only where both
   levels allow it.
4. **Caps are checked at claim.** A run is claimed only while the
   workspace's runs today (UTC) are under its cap. The token cap is read
   from the usage ledger (`rdb/0171`) over the turns of this month's (UTC)
   agent runs, the way `tokenBudget` reads it. At 80 % the workspace admins
   get one notice in `#scheduled-runs`; at 100 % agent runs are `skipped`
   and their tasks pause with `cap` until the window rolls over. A fixed run
   counts towards the run cap only (it spends no AI tokens). A run refused
   by the chain rule (4.2.2) counts towards no cap.
5. **The token budget of spec 121 still applies**: an agent run is an agent
   turn, so the workspace's budget can still refuse it (`429 token_quota`);
   the run then ends `failed` with that reason.
6. **Instance tasks (D16)**: their runs do NOT count against a workspace's
   caps; they count against the instance's own caps
   (`tasks.instance.runs_per_day`, `tasks.instance.tokens_per_month`), with
   the same 80 % notice (to the instance admins, in `t1`'s
   `#scheduled-runs`) and the same `cap` pause. Each workspace an instance
   task runs in gets its result in its own `#scheduled-runs` (6.1).

## 6. Where it shows

### 6.1 The `#scheduled-runs` channel (D5, D12, D13, D14)

- A fifth default channel, id **`scheduled-runs`** (D13, msg `5fa95db3`:
  "each workspace should have the scheduled-runs named channel"), shown as
  `#scheduled-runs` with a translated description "Scheduled tasks and
  activities" (a translation key). It is added to
  `spool_seed_default_channels` (every new workspace) and inserted for every
  existing one by the same migration, as `rdb/0173` did for `#public`, and
  added to `DefaultChannels` (`api/store/channels.go:44`).
- **Who reads it (D14)**: every member, as every default channel
  (`PublicChannels`, `api/store/channels.go:49`). A result post links its
  objects; each link opens only for a reader who may read that object (the
  object's own route answers as it does today), and the post names an
  object the reader of the post may not read only by its id: the result is
  rendered once, so the post itself shows titles only of objects in
  channels every member reads, and ids for the rest. Row S3 proves both.
- **Layout (D12: A, default, the owner did not pick; holder post
  `921ac359`)**: one topic per task, its id a UUIDv5 of `(task_id,
  "scheduled-runs")`, titled with the task's name; each run is a reply in
  that topic. An agent run's prompt and its agent's answer are replies in
  the same topic. An instance task has one topic per task in each
  workspace's channel.
- Every run that matched at least one object posts its result as `HUB-0`,
  signed `box-wui` (the `public_notice.go` path): the trigger, the matched
  and acted counts, the outcome, each object as a link (rule above), and for
  an agent run the agent's answer. A `skipped` run with `chain_self` or
  `chain_depth` posts nothing.
- A run that matched nothing posts nothing (its history row is still
  written), so a quiet task does not fill the channel.
- A post in `#scheduled-runs` fires no task and no loop (4.2), whoever wrote
  it.

### 6.2 The lists

- **Workspace**: Settings -> "Scheduled tasks", a new section: name, object,
  next run, last outcome, state (with the pause reason), owner; per row
  Edit, Pause / Resume, Run now, History, Delete; "New task" and "From a
  template". An admin sees every task. Settings stays admin-only (D23):
  no section of it opens to a member who is not an admin
  (`csi-spl-wui/tests/unit/tenant-settings.test.mjs:31`, "CONTROL: a developer sees no entry",
  keeps passing). Such a member reaches tasks only through the dialog
  below, and a member's task always has one (D24).
- **Instance (D10)**: in `t1`'s Settings, an "Instance" section shown only to
  `t1` admins: the 5.1 settings, the instance tasks, and per workspace its
  task count, runs today and tokens this month against its caps (the 5.1
  routes).
- **The "Scheduled tasks" dialog (D21, D23)**: ONE dialog
  (`wui/components/ScheduledTasksDialog.vue`, row S8), the same for every
  object it is opened from; it lists that object's tasks with the
  workspace list's rows and per-row actions, under D3's rights, and its
  "New task" opens the editor (6.3) with the scope bound to that object.
  It opens from four places, each a "Scheduled tasks" item shown to every
  member:
  - **channel and topic** (D21): the right-click menus below;
  - **issue** (D23): the issue's right-click menu (`menuItemsFor`,
    `wui/composables/useIssueCtxMenu.ts:45`, for a target that is not
    `top`; opened from an issue row) and the issue detail
    dialog's header buttons (`wui/components/IssueDetailActions.vue:50`,
    the Copy / Note / Archive / Delete row). It lists the tasks whose
    parsed query holds a positive `key:<KEY>` leaf (`GET
    /v1/tasks?issue=<KEY>`); "New task" fills `object = issue`, query
    `key:<KEY>`;
  - **epic** (D23; a level-1 row, epic or feature): the same
    `menuItemsFor` for a `top` target, which serves both the sidebar's
    epic row right-click (`wui/components/IssueEpicsPanel.vue:22`,
    `onEpicContext` `:67`) and the epic view's title-row button
    (`openEpicMenu`, `useIssueCtxMenu.ts:91`). It lists the tasks whose
    parsed query holds a positive `epic:<KEY>` leaf (`GET
    /v1/tasks?epic=<KEY>`); "New task" fills `object = issue`, query
    `epic:<KEY>`.
  A task bound to several objects (e.g. `key:A OR key:B`) lists in each
  one's dialog. Every entry opens the dialog through one composable
  (`wui/composables/useScheduledTasksDialog.ts`, in the shape of
  `useAddToNote.ts`), so `IssueDetailActions.vue`, which only emits, needs
  no page wiring; its header button, like the menu, binds `epic:<KEY>`
  when the open issue is a level-1 row (epic or feature: the issue dialog
  opens those too, `useIssueCtxMenu.ts:48`) and `key:<KEY>` otherwise.
  `csi-spl-wui/tests/unit/issue-detail-buttons.test.mjs:23-29` pins the
  header's four buttons and changes with it.
- **Channel and topic menus (D21)**: the right-click menu of a channel row
  in the sidebar (`wui/components/SidebarRowMenu.vue`, opened from
  `ChannelSidebar.vue`'s `@contextmenu`) and of a topic card
  (`wui/components/MessageMenu.vue`, the menu spec 182's "Discussion loops"
  item sits in) carry a "Scheduled tasks" item for every member. A
  channel's item lists that channel's tasks: those whose `where` names the
  channel. A topic's item lists that topic's tasks: those whose parsed
  query holds a positive (not negated) `topic:<task_id>` leaf (the grammar's existing `topic:` operator,
  `api/search/grammar.go:200`). The list is the workspace list's rows and
  per-row actions, with D3's rights (a member edits their own tasks and
  reads the others). "New task" there fills the editor's scope with that
  channel (`where`) or that topic (`where` = its channel, query
  `topic:<task_id>`). `topic` and `message` tasks over all channels, and
  `issue` tasks with no positive `key:` or `epic:` leaf, are in no dialog: they are admin-only (D24) and
  listed in Settings. The items
  are built in `wui/utils/sidebar-row-menu.mjs` (`rowMenuItems`) and
  `wui/utils/msg-menu.mjs` (`msgMenuItems`); the topic item follows the
  `topic-loops` item's phone rule (`msg-menu.mjs:155`, desktop only, the
  phone bottom-sheet height budget) unless S8 shows it fits.
- **History**: per task, its runs of the last `history_days`, newest first,
  each linked to its reply in the task's topic.

### 6.3 The editor

One dialog, in the Windows Task Scheduler's order, then a summary:

1. **What it concerns** (4.1): object type, channels, conditions, and the
   live match count.
2. **When** (4.2): the five kinds, an event, and under "Advanced" the cron
   field (4.2.1) with its next three fire times.
3. **What it does** (4.3): a fixed action and its argument, or a prompt and
   the agent (D11: a pick of the workspace's agents).
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
| 7.2 | Nudge stale issues | `issue`, `status:wip idle:7d` | `weekly` Monday 09:00 | `notify` with `mention_assignee` on (D22) |
| 7.3 | Archive idle topics | `topic`, `idle:30d` | `daily` 03:00 | `archive` |
| 7.4 | Weekly status report | `issue`, changed in the last 7 days | `weekly` Friday 15:00 | `agent`: "Write a status report of the week from these issues: done, in progress, blocked, next. Link each issue." |

The grammar has no "idle for" operator (the operators are listed in section
2). Row S2 adds `idle:<duration>` (no message since, for a topic; no change
since, for an issue) and `changed:<duration>` (its inverse), grammar
version 1.7; `after:` and `before:` stay as they are. Row S11 adds to the
same 1.7 `label:` on topics and messages (4.3.1).

The grammar has no operator for one issue or for an epic's issues either
(`OpName` "an issue's key and title" is a contains match,
`api/search/grammar.go:205`). For D23 row S2 adds to 1.7, on `issue`
only: `key:<KEY>` (exactly that issue, case-insensitive) and `epic:<KEY>`
(the issues and subtasks whose level-1 row is KEY; not the epic row
itself, which `key:` reaches). Issue search is not compiled in Postgres:
`api/store/search_postgres.go` holds no issue term (`git grep -c -i issue`
on it: no match at `208e5f757`); `TypeIssue` is matched in process,
`issueEntities` (`api/hub/search.go:825`) builds a `search.Entity`
(`api/search/match.go:43`) per issue for `MatchEntity`. `store.Issue` has
no epic field; `treeKind` (`api/hub/issues.go:120`) gives an issue's
level-1 key (the `epic` of the issue JSON, `issues.go:55`). So S2 adds
`Key` and `Epic` to `search.Entity`, sets them in `issueEntities` through
`treeKind`, and matches `key:` / `epic:` in `MatchEntity`.

## 8. Store

### 8.1 Tables

Two forward-only migrations, numbered by `do_rdb_migration_next` at build
time (head on `origin/master` `325a47c76`: `0302`; the number moves, the
action picks it): row S1's (the tasks, runs, settings and the fifth default
channel) and row S11's (the two label tables).

```sql
-- row S1
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
    trigger_kind     text        NOT NULL CHECK (trigger_kind IN ('once','every_n_minutes','daily','weekly','monthly','cron','event')),
    trigger_spec     jsonb       NOT NULL,                       -- cron: {"cron": "<5 fields>"}, at most 64 characters, checked in Go (4.2.1)
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
    level         text        NOT NULL DEFAULT 'workspace' CHECK (level IN ('workspace','instance')), -- D16: which caps it counts against
    cause         text        NOT NULL CHECK (cause <> '' AND length(cause) <= 128),
    chain         uuid[]      NOT NULL DEFAULT '{}' CHECK (cardinality(chain) <= 3), -- D15: the tasks that led here, oldest first
    started_at    timestamptz NOT NULL,
    ended_at      timestamptz,
    outcome       text        NOT NULL DEFAULT 'running' CHECK (outcome IN ('running','ok','partial','failed','skipped')),
    matched       integer     NOT NULL DEFAULT 0,
    acted         integer     NOT NULL DEFAULT 0,
    failures      jsonb       NOT NULL DEFAULT '[]',
    error         text        NOT NULL DEFAULT '' CHECK (length(error) <= 500),
    tokens        bigint      NOT NULL DEFAULT 0,
    agent_id      text        NOT NULL DEFAULT '' CHECK (length(agent_id) <= 64), -- D11: who ran an agent run
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

-- row S11 (D19)
CREATE TABLE IF NOT EXISTS topic_labels (
    tenant_id text        NOT NULL,
    task_id   uuid        NOT NULL,
    label_id  text        NOT NULL,
    set_by    text        NOT NULL CHECK (length(set_by) <= 64),
    set_at    timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, task_id, label_id),
    FOREIGN KEY (tenant_id, label_id) REFERENCES issue_labels (tenant_id, label_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS topic_labels_label ON topic_labels (tenant_id, label_id);

CREATE TABLE IF NOT EXISTS message_labels (
    tenant_id text        NOT NULL,
    msg_id    uuid        NOT NULL,
    label_id  text        NOT NULL,
    set_by    text        NOT NULL CHECK (length(set_by) <= 64),
    set_at    timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, msg_id, label_id),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, label_id) REFERENCES issue_labels (tenant_id, label_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS message_labels_label ON message_labels (tenant_id, label_id);
```

- **RLS**: `scheduled_task_runs`, `topic_labels` and `message_labels` in the
  shape every tenant table has (developer guide 2.6.4); `scheduled_tasks`
  with the same policy for rows that have a `tenant_id`, and its instance
  rows (`tenant_id IS NULL`) readable only outside a tenant scope (the
  instance routes and the runner). Rows S1 and S11 prove it
  (`TestRLSCoversEveryTenantTable`, `api/store/rls_test.go`).
- **Instance runs** are written once per workspace they ran in, under that
  workspace's `tenant_id`, with `level = 'instance'`, so each workspace's
  history reads only its own rows and its caps skip the instance's (D16).
- **Channel move or copy** (spec 169): `scheduled_tasks`,
  `scheduled_task_runs`, `topic_labels` and `message_labels` are listed in
  `api/channelmove/catalogue.go`; a moved channel's id is removed from a
  staying task's `scope_where` and from a `move` action's `channel`
  (`Rewritten`, `rewriteTasks` in `api/store/channel_move_apply_postgres.go`),
  and the next run says so. A task the move leaves with `scope_where` `{}`
  (which would read every channel) or a `move` with no target is paused,
  reason `channel_moved` (4.4), with no next due time; a deleted task only
  loses the id. The P7 proofs allow exactly those columns on a staying row
  (`rewrites` in `api/channelmove/proof.go`).
- **Next due time**: computed in Go from `trigger_kind`, `trigger_spec` and
  `tz` (for `cron`, with `taskcron.Next`), never in SQL.

### 8.2 The runner

`runScheduledTasks`, one 60 s ticker started beside `runGcalSync`
(`api/hub/server.go:711`):

1. **Claim** due schedule tasks with one `UPDATE scheduled_tasks SET
   next_due_at = <next> ... WHERE state = 'on' AND next_due_at <= now() ...
   RETURNING`, so two hub instances never run the same due time (spec 182
   4.2 step 5).
2. **Check the caps** (5.3) of the task's workspace, or the instance's for
   an instance task (D16); over a cap the run is `skipped`.
3. **Insert the run** with `ON CONFLICT DO NOTHING` on `run_id`; a conflict
   is a second claim of the same cause and stops here.
4. **Read the scope** as the owner (4.1, 4.5) and **act** (4.3), with the
   run's chain in the context (4.2.2).
5. **Post the result** (6.1) in the task's topic and close the run row.

An event task runs steps 2 to 5 from its hook (4.2), after the chain check
(4.2.2), off the request path (a goroutine with its own context), so a post
or an issue write never waits on a task. A per-workspace "has event tasks"
bit in memory, refreshed on every task write, keeps a workspace with none at
zero extra probes (spec 182 4.2 step 6); `TestRoundTripsPerRequest` proves
it.

## 9. Build order

| row | depends on | kind | files | done test | red control |
|---|---|---|---|---|---|
| **S1 rdb + store** | — | `complex_coding` | `rdb/<NNNN>_scheduled_tasks.sql` (8.1 row S1 and the fifth default channel `scheduled-runs`); `api/store/{scheduled_task.go,scheduled_task_postgres.go,scheduled_task_memory.go,scheduled_task_test.go,hub_settings.go}`; `api/store/channels.go` (`DefaultChannels`); `rls_test.go`; `api/channelmove/catalogue.go` | `PRE_PUSH_TIER=full`: Postgres and Memory parity; each CHECK refuses its stray value (a `chain` of 4, a `trigger_kind` outside the seven); of two concurrent claimers one gets a due task; a second run insert for the same cause is a no-op; RLS covers both tenant tables and an instance row is invisible in a tenant scope; a new and an existing workspace both have `#scheduled-runs` | drop `next_due_at <= now()` from the claim, and the two-claimer test runs the task twice |
| **S2 grammar** | — | `simple_coding` | `api/search/{grammar.go,values.go,match.go,grammar_test.go}`, the stores' compile of `idle:` and `changed:`, `api/hub/search.go` (`issueEntities`: an issue's `Key` and `Epic` for D23's `key:` and `epic:`, matched in `MatchEntity`; 7) and `api/hub/search_issue_test.go`, `../003-spool-message-bus/contracts/search-v1.md` (1.7) | `idle:30d` matches a topic with no message for 31 days and not one with a message 29 days ago, in the Postgres compile and in `MatchTopic`; for an issue, by its last change; `changed:7d` is the inverse; `key:SPL-7` matches SPL-7 and not SPL-70; `epic:SPL-17` matches the issues under SPL-17 and not SPL-17 itself; both refused on a non-issue type | compile `idle:` as `after:`, and the 31-day topic is not matched |
| **S3 hub runner + fixed actions** | S1 | `complex_coding` | `api/hub/{scheduled_tasks.go,scheduled_task_run.go,scheduled_task_actions.go}` and their tests; the ticker start in `server.go`; the 30-day delete chore | each schedule kind gives the right next local time, across a DST change in `Europe/Helsinki`; a missed tick runs once; each fixed action changes its object through its store path; a member's task never acts on another member's object (D17: a topic started by, a message sent by, an issue neither assigned to nor reported by the member); an owner who left skips the run and pauses the task; 5 failures pause it; the result is a reply in the task's one topic in `#scheduled-runs` as `HUB-0` (D12), names an unreadable object by id only (D14), and fires no task | remove the own-object check at run (4.5), and the member test archives another member's topic |
| **S4 event triggers + chains** | S3 | `complex_coding` | the hooks in `wui.go`, `ws.go`, `issues.go` (shared with spec 182 row L2: one call per hook, each feature its own function, D9); `taskChainKey` and the chain check (4.2.2) | a new matching message, topic and issue each run the task once; a replay, a `HUB-0` note, a loop prompt and a post in `#scheduled-runs` do not; A -> A is `skipped` `chain_self`, A -> B -> A is `skipped` `chain_self`; A -> B -> C runs all three; `TestRoundTripsPerRequest` shows no extra round trip in a workspace with no event task | a 4-deep chain A -> B -> C -> D: remove the depth check and D runs (the test wants D `skipped` `chain_depth`) |
| **S5 agent action + caps** | S3 | `complex_coding` | `api/hub/scheduled_task_agent.go`, the cap read over `rdb/0171`, their tests | the prompt reaches the named agent as one `task` in the task's topic with the objects quoted; the named agent offline -> an online agent of the workspace runs it and `agent_id` says which; none online -> `failed` `no_agent` (D11); the answer closes the run `ok`; no answer within the timeout closes it `failed` `no_answer`; at the run cap the next run is `skipped`; at 100 % tokens an agent run is skipped and its task pauses `cap`; the 80 % notice posts once | count fixed runs against the token cap, and the fixed-run test is skipped at 100 % |
| **S6 two levels** | S1, S3 | `complex_coding` | `api/hub/operator_tasks.go` (the 5.1 routes behind `operatorAuth` and `instanceAdminAuth`); `api/config/config.go` (`SPOOL_HUB_INSTANCE_ADMIN_WORKSPACE`, default `t1`); the 5.2 settings (`RegisterTenantSetting`); `taskEffective` (5.3) | a `t1` member with `admin` or `biz_owner` reaches the instance routes, a `t1` `developer` and an admin of another workspace get `403` (D10); a fresh workspace's caps read 50 runs and 500 000 tokens (D18); instance off stops a workspace that is on; a workspace cap above the instance's is refused and one below is used; an action off at either level is refused at save and skipped at run; an instance task runs in each listed workspace, writes one run row in each with `level = 'instance'`, and leaves the workspace's run count unchanged while the instance's rises (D16) | count instance runs against the workspace cap, and the D16 test sees the workspace's run count rise |
| **S7 workspace routes** | S1, S2 (D23's `key:` / `epic:` leaves), S3 | `simple_coding` | `api/hub/tasks_routes.go`: `GET` (with D21's `?channel=` and `?topic=`, D23's `?issue=` and `?epic=`) / `POST /v1/tasks`, `PUT` / `DELETE /v1/tasks/{id}`, `POST /v1/tasks/{id}/run`, `GET /v1/tasks/{id}/runs`, `GET /v1/tasks/preview` (the live count) | the D3 table (admin: any task; member: own objects per D17; member on another's objects: 403; member with `object = channel`: 403; member with an unbound scope, D24: 403); a refused query answers the grammar's error; the preview counts and writes nothing | save a member's task without narrowing its scope, and the D3 test passes on another member's objects |
| **S8 wui** | S7, S11, S12 | `simple_coding`, then `i18n` (agy has the last word) | `wui/components/ScheduledTasks*.vue` (list, editor with the Advanced cron field and the agent pick, history), the Settings section and `t1`'s Instance section, the one `ScheduledTasksDialog.vue` and its "Scheduled tasks" item in `SidebarRowMenu.vue` and `MessageMenu.vue` (D21), in `useIssueCtxMenu.ts` `menuItemsFor` (issue and epic) and `IssueDetailActions.vue` (D23), the four templates, the topic and message label chips, `wui/utils/spool-client*.mjs`, `csi-spl-wui/i18n/locales/*.json` | `pnpm run typecheck`; `test:unit` (i18n parity, untranslated and raw-text gates, cleancode; the editor's required fields per trigger and action kind; the summary sentence per trigger kind, cron included); the Instance section is absent for a non-`t1` admin; `issue-detail-buttons.test.mjs` names the new header button; the issue and epic menus carry the item and "New task" binds `key:` / `epic:`; a developer still sees no Settings entry (`csi-spl-wui/tests/unit/tenant-settings.test.mjs:31` unchanged) | a raw string in the editor, and `i18n-no-raw-text` fails |
| **S9 e2e** | S8 | `tests` | `csi-spl-wui/tests/e2e/scheduled-tasks.test.mjs` | on the mock: create from each template, edit, pause, resume, run now, read the history, see the result as a reply in the task's topic in `#scheduled-runs`; save a cron task and read its next three times; open the dialog from a channel, a topic, an issue and an epic, each listing only its own tasks | skip the template fill, and the template test finds an empty editor |
| **S10 docs** | S3-S8, S11, S12 | `specs_and_docs` | this spec's row status; a help page under `csi-spl-doc/doc/help/` | `do_check_dist_hygiene`, `do_check_fleet_rules_drift` | — |
| **S11 labels on topics and messages** | S2 | `complex_coding` | `rdb/<NNNN>_topic_message_labels.sql` (8.1 row S11); `api/store/{object_labels.go,object_labels_postgres.go,object_labels_memory.go,object_labels_test.go}`; `rls_test.go`; `api/channelmove/catalogue.go`; `api/search/{grammar.go,match.go,grammar_test.go}` (`label:` applies to message and topic), the stores' compile; `api/hub/object_labels.go` (the 4.3.1 routes); `search-v1.md` (1.7) | `PRE_PUSH_TIER=full`: Postgres and Memory parity; a label not in the catalogue is refused; the 21st label on one object is refused; deleting a catalogue label removes it from topics and messages; `label:urgent` finds a labelled topic and message in the Postgres compile and in `MatchTopic` / `MatchMsg`; RLS covers both tables; a moved channel carries its labels | leave `TypeMessage` out of `label:`'s `Applies`, and the message search for `label:urgent` is refused |
| **S12 cron trigger** | S3 | `simple_coding` | `api/taskcron/{cron.go,cron_test.go}` (new, no module added); the `cron` kind in `api/store/scheduled_task.go` validation and in S3's next-time function | the 4.2.1 grammar: each field's range, lists, ranges and steps; `0`/`7` both Sunday; the either-day rule; `*/30 8-18 * * 1-5` in `Europe/Helsinki` gives the right next times across a DST change; `*/15 * * * *` saves, `*/5 * * * *` and `0,10 * * * *` are refused `floor`, `0 0 30 2 *` refused `never`, `MON` and `@hourly` refused `syntax`, a 6-field string refused `fields` | drop the floor walk, and the `*/5 * * * *` test saves |

S1, S2 and S12's parser run in parallel now; S11 after S2 (the same grammar
version 1.7, one lane after the other on `grammar.go`); S3 after S1; S4,
S5, S6 and S7 in parallel after S3; S12's store and runner part after S3;
S8 after S7, S11 and S12; S9 after S8.

### 9.1 Contracts for parallel rows (binding)

A row that needs to change one asks the dispatch holder first, and the
change lands in this spec before the code. Every name below is new.

#### 9.1.1 Go store (S1 builds it; S3, S4, S5, S6, S7, S12 call it)

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
	TaskCronMax        = 64   // characters (4.2.1)
	TaskChainMax       = 3    // D15: tasks deep; tasks.max_chain_depth may only lower it
	TaskRunsPerDayDefault     = 50     // D18
	TaskTokensPerMonthDefault = 500000 // D18
	ChannelScheduledRuns      = "scheduled-runs" // D13; in channels.go beside ChannelPublicID
)

var TaskObjects  = []string{"channel", "topic", "message", "issue"}
var TaskTriggers = []string{"once", "every_n_minutes", "daily", "weekly", "monthly", "cron", "event"}
var TaskActions  = []string{"move", "archive", "label", "set_priority", "notify", "agent"}
var TaskEvents   = []string{"message_new", "topic_new", "issue_new", "issue_changed"}
var TaskOutcomes = []string{"running", "ok", "partial", "failed", "skipped"}
var TaskPauseReasons = []string{"", "by_person", "done", "owner_left", "failing", "cap"}
// Run errors with a fixed meaning (TaskRun.Error starts with one of them).
var TaskRunErrors = []string{"chain_self", "chain_depth", "no_agent", "no_answer", "token_quota", "cap"}

// ErrBadTask: a value outside the CHECKs of 8.1, a zone time.LoadLocation
// refuses, a cron expression 4.2.1 refuses, or a trigger or action spec
// that does not fit its kind. Before any write.
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
	Cron        string    `json:"cron,omitempty"`         // cron: 5 fields, 4.2.1 (0..7 = Sun..Sun)
	On          string    `json:"on,omitempty"`           // event: one of TaskEvents
}

// TaskActionSpec is action_spec; only the fields of its kind are set.
type TaskActionSpec struct {
	Channel  string   `json:"channel,omitempty"`  // move
	Label    string   `json:"label,omitempty"`    // label: an issue_labels.label_id (issue, topic, message; D19)
	Priority int      `json:"priority,omitempty"` // set_priority
	Mention  []string `json:"mention,omitempty"`  // notify: member ids
	MentionAssignee bool `json:"mention_assignee,omitempty"` // notify (D22): also each matched object's assignee (4.3)
	Prompt   string   `json:"prompt,omitempty"`   // agent
	Agent    string   `json:"agent,omitempty"`    // agent (D11): the named agent; offline -> any online agent of the workspace
}

type TaskRun struct {
	TenantID    string
	RunID       string // UUIDv5(task_id, cause)
	TaskID      string
	Level       string   // the task's level (D16)
	Cause       string   // RFC 3339 due time, or the object's id
	Chain       []string // D15: task ids that led here, oldest first; len <= TaskChainMax
	StartedAt   time.Time
	EndedAt     time.Time // zero while running
	Outcome     string
	Matched     int
	Acted       int
	Failures    []TaskRunFailure
	Error       string
	Tokens      int64
	AgentID     string // D11: who ran an agent run
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
	// RunsSince counts runs of one level: a workspace's own (level
	// "workspace", tenant set) or the instance's over every tenant
	// (level "instance", tenant ""), D16. Chain-refused runs are not counted.
	RunsSince(ctx context.Context, tenant, level string, since time.Time) (int, error)
	HubSetting(ctx context.Context, key string) (json.RawMessage, bool, error)
	SetHubSetting(ctx context.Context, key string, v json.RawMessage, by string, at time.Time) error
}
```

#### 9.1.2 Hub (S3 builds it; S4, S5, S6 call it)

```go
// runTask runs one claimed or event-fired task in one workspace for one
// cause; obj is the event's object, nil for a schedule; chain is the
// event's chain (nil for a schedule), checked against 4.2.2 before
// anything else. It never panics the ticker and always returns the run row
// it wrote.
func (s *Server) runTask(ctx context.Context, t store.ScheduledTask, tenant, cause string, obj *taskObject, chain []string) store.TaskRun

// taskChainKey carries a run's chain plus its own task id into the store
// paths its fixed action calls, so the event hooks read it (4.2.2).
type taskChainKey struct{}

// taskEffective answers the effective settings of 5.3 for tenant.
func (s *Server) taskEffective(ctx context.Context, tenant string) (taskLimits, error)

type taskLimits struct {
	Enabled          bool
	MembersMayCreate bool
	RunsPerDay       int
	TokensPerMonth   int64
	Actions          map[string]bool
	MinIntervalMin   int
	MaxChainDepth    int
}

// instanceAdmin reports whether member is an admin (a role holding
// tenant.settings) of the config's instance-admin workspace (D10).
func (s *Server) instanceAdmin(ctx context.Context, tenant, member string) (bool, error)
```

#### 9.1.3 Cron (S12 builds it; S1's validation and S3's next time call it)

```go
package taskcron

// ErrCron names the refused part: "fields", "range", "syntax".
type ErrCron struct{ Reason, Field string }

// Schedule is a parsed 5-field expression (4.2.1).
type Schedule struct{ /* bit sets per field, the either-day flag */ }

func Parse(expr string) (Schedule, error)
// Next answers the first fire time strictly after after, in loc, with the
// DST rule of 4.2.
func (s Schedule) Next(after time.Time, loc *time.Location) time.Time
// MinGap walks the fire times from from over horizon and answers the
// smallest gap between two consecutive ones; ok=false when none fires.
func (s Schedule) MinGap(from time.Time, loc *time.Location, horizon time.Duration) (gap time.Duration, ok bool)
```

#### 9.1.4 Labels (S11 builds it; S3's `label` action and S8 call it)

Package `store`, file `api/store/object_labels.go`, implemented by `Memory`
and `Postgres`.

```go
const ObjectLabelsMax = 20 // per topic or message, the issues' cap

// ErrBadLabel: a label_id not in the tenant's issue_labels, or the 21st.
var ErrBadLabel = errors.New("store: bad label")

type ObjectLabelStore interface {
	AddTopicLabel(ctx context.Context, tenant, taskID, labelID, by string, at time.Time) error   // idempotent
	RemoveTopicLabel(ctx context.Context, tenant, taskID, labelID string) error
	TopicLabels(ctx context.Context, tenant string, taskIDs []string) (map[string][]string, error)
	AddMessageLabel(ctx context.Context, tenant, msgID, labelID, by string, at time.Time) error // idempotent
	RemoveMessageLabel(ctx context.Context, tenant, msgID, labelID string) error
	MessageLabels(ctx context.Context, tenant string, msgIDs []string) (map[string][]string, error)
}
```

#### 9.1.5 Wire (S7, S11 build it; S8 calls it)

`/v1/tasks` JSON uses the snake_case of the 8.1 columns, with
`trigger_spec` and `action_spec` as the objects of 9.1.1's JSON tags; a run
carries `chain` (task ids) and `agent_id`. `GET /v1/tasks` takes
`?channel=<channel_id>` (tasks whose `where` names it) and
`?topic=<task_id>` (tasks whose query holds `topic:<task_id>`) for the D21
menus, and (D23) `?issue=<KEY>` / `?epic=<KEY>` (tasks whose parsed query
holds a positive `key:<KEY>` / `epic:<KEY>` leaf) for the issue and epic
dialogs. Errors: `400 bad_task` (naming
the field; for `cron` also the 4.2.1 reason), `400 bad_query` (the
grammar's message), `400 bad_label`, `403 not_allowed` (D3, D10), `409
cap_reached`, `404 not_found`. The label routes of 4.3.1 answer `204` on
success.

## 10. Questions: answered

The v0.2 form (poll `558a4577`, Q1-Q11; its text and the recommendations
are in v0.2, `1f1a614bd`, section 10) is answered: section 1.1.2, D9-D20.
The build plan's form (poll `bb3b76c2`) is answered: section 1.1.3, D21-D22.
Plan questions Q1b and Q1c are answered: sections 1.1.4 and 1.1.5, D23
and D24. No question is open.

## 11. Not in this spec

- Moving any box cron or hub timer into tasks (section 2).
- Folding spec 182's topic loops into tasks (D9).
- A run shown in the Calendar as an event; a later spec may add it.
- External actions (mail, webhooks, other systems): an agent task does what
  its agent can do; nothing is added here.
- A dry run or an approval step (D6).
- Tasks over objects other than channels, topics, messages and issues
  (docs, files, contacts).
- Cron extensions beyond 4.2.1 (seconds, names, macros, `L`, `W`, `#`).
- A second label catalogue for topics or messages (4.3.1: one catalogue).

## 12. Risks

- **D6 with a wide scope**: one run can archive many topics. Bounded by
  `max_objects` (default 100), the live count in the editor, the list of
  every changed object in the result post, and the D15 chain limit (no
  self-trigger, at most 3 tasks deep).
- **D15 chains through an agent**: an agent's own changes carry no chain
  (4.2.2), so an agent task whose agent changes objects that match another
  event task starts a fresh chain. Bounded by the run and token caps (D7,
  D18), the `failing` pause, and by `#scheduled-runs` firing nothing.
- **Agent token spend**: an agent task on a busy channel can use a month's
  cap in days, sooner at D18's 500 000 tokens. Bounded by the D7 cap and its
  80 % notice (5.3); spec 121's budget still applies.
- **D18's 50 runs a day are tight**: one `every_n_minutes` task at the
  15-minute floor uses 96 runs a day, so it reaches the cap by the early
  afternoon (UTC) and pauses `cap`. The editor shows the task's runs a day
  against the workspace's cap before save; the instance admins raise a
  workspace's cap with an override (5.1).
- **Hot-path cost of event triggers**: bounded by the in-memory "has event
  tasks" bit and the round-trip test (S4).
- **D19 on the messages table**: label rows, not a column, keep the insert
  path as it is (4.3.1); the `label:` compile is an `EXISTS` on an indexed
  table, measured by row S11's search test.

## 13. Changes

- v0.1 (2026-11-20): first draft; D1-D8 from poll `38083eff`; Q1-Q11 open.
- v0.2 (2026-11-20): review m-181 (msg `7f5dce3f`) folded: W1 spec 182 has 11
  triggers, not 12; W2 `server.go` and `operator.go` lines re-read on
  `origin/master` `d6b810775`; N1 the owner rule quotes 182 4.5; N2 rdb head
  `0300`; N3 the number check names this lane's own worktree. Q1-Q11 unchanged.
- v0.3 (2026-11-21, lane `c-660`): the owner's answers to Q1-Q11 (msgs
  `f81b6c38`, `fe41bdc8`, `5fa95db3`) written in as D9-D20 (1.1.2); Q4's
  grouping A is the holder's default (post `921ac359`). The channel is
  `scheduled-runs`, one topic per task; instance admins are `t1`'s admins;
  default caps 50 runs a day and 500 000 tokens a month; instance runs have
  their own caps; task chains (no self, 3 deep, `scheduled_task_runs.chain`);
  labels on topics and messages from the one catalogue (row S11); a 5-field
  cron trigger (row S12). Status Decided; section 10 answered; claims re-read
  on `origin/master` `325a47c76` (rdb head `0302`, `0301_topic_loops.sql`
  landed).
- v0.4 (2026-11-25, lane `c-074`): the build plan's form (poll `bb3b76c2`)
  written in as D21-D22 (1.1.3). D21: a "Scheduled tasks" item in the
  channel and topic right-click menus (6.2), the list filter `?channel=` /
  `?topic=` (9.1.5, row S7). D22: `notify`'s `mention_assignee` (4.3,
  9.1.1, template 7.2). Code paths read on `origin/master` `5adcd5fdd`.
- v0.5 (2026-11-25, lane `c-074`): review a-475 (agy) FAIL on `31d6b4886` folded: W1 the member's view of
  tasks the menus do not list is plan question Q1b, open (1.2, 6.2; spot
  S8 only); W2 the menu util files named (6.2). Notes N1-N4: the
  `?topic=` filter matches a positive `topic:` leaf of the parsed query;
  the `mention_assignee` channel refusal sits in the shared save check;
  mentions deduplicated; the topic item's phone rule.
- v0.6 (2026-11-25, lane `c-074`): plan question Q1b answered (1.1.4, D23:
  the owner's msg `6b1806e4`, B of msg `b6acff79` withdrawn): ONE
  "Scheduled tasks" dialog opened per topic, channel, issue and epic;
  Settings stays admin-only (6.2). The issue and epic entries named (the
  issue menu `menuItemsFor`, the issue detail header, the epic sidebar row
  and title button); grammar 1.7 adds `key:` and `epic:` on issues (7, row
  S2); `GET /v1/tasks?issue=` / `?epic=` (9.1.5, row S7). Q1c open: the
  tasks no dialog reaches for a member (1.2). Code paths read on
  `origin/master` `208e5f757`.
  Review a-521 (agy) FAIL on `6499cd116` folded: W1 Q1c gets options A
  (recommended: unbound scopes admin-only, S7 refuses) and B, and its spot
  names S7; W2 issue search is matched in `api/hub/search.go`
  `issueEntities`, not compiled in `search_postgres.go`: S2 adds that file
  and `Key` / `Epic` on `search.Entity` via `treeKind` (7, row S2), and S7
  depends on S2. Notes: N1 the header button binds `epic:` on a level-1
  row, `key:` otherwise, the dialog opens through one composable, and
  `issue-detail-buttons.test.mjs` changes (6.2, row S8); N3 the unit
  test's full path; N4 a several-channel task lists in each channel's
  dialog, so Q1c (a) is all channels only.
- v0.7 (2026-11-25, lane `c-074`): plan question Q1c answered A (1.1.5,
  D24, msg `c5143a2f`): a task with an unbound scope is admin-only, S7
  refuses a member's with `403 not_allowed` (4.5, 6.2, row S7's D3 cell);
  a member makes it per epic or per channel. No question open (1.2, 10).
- v0.8 (2026-11-27, lane `c-752`, SPL-6659; the R7 notes N3 and N1 of row
  S1): a channel move also clears a `move` action's target, and pauses a
  task it leaves with no channel, reason `channel_moved` (4.4, 8.1, rdb
  `0333`); a run's error is cut to 500 characters on every run write,
  `StartRun` too (4.6). Dispatch holder's go: msg `b3c19bbc`.
