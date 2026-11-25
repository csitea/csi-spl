# Spec 187 build round - plan v1.5 (13 rows (S12 split), 8 batches)

Epic: SPL-2403 (the brief's line; spec 187 names SPL-2398, see 2.4 N1)  
Spec: csi-spl-doc/specs/187-scheduled-tasks-activities (v0.7)  
Class: feature  
Kind: specs_and_docs  
Issue: SPL-6376  
Topic: 91992830-ca2f-4711-b04e-e4c333d7294d  
Discussion: 91992830-ca2f-4711-b04e-e4c333d7294d (t1 #spool-hub-devel; the dispatch holder owns it; the planner reports on task `dispatch-91992830`)

Owner HUM-10, by pointer:

- t1 91992830, poll 38877deb answer A (msg 201ab3de, 2026-11-24 07:06Z):
  "Plan it as a build round now: a planner orders S1-S12, a panel signs it,
  the rows are queued".
- The owner's question (07:00Z, msg e652574a): scheduled tasks are a
  different kind of scheduling from topic loops (spec 182), with their own
  UI. Spec 187 D9 (Q1 A) keeps both objects and shares the event hooks;
  1.2 below plans those hooks against what spec 182 already built.
- Spec 187 v0.3, `07f34efeb` (SPL-6067): D1-D20 decided, nothing open
  (spec 1.2). Not asked again here.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) R1-R16, sections 3 and 5.
  The rulebook wins over this plan.

**What this round is.** Spec 187 section 9 names twelve build rows, S1-S12.
This plan re-measures each row's sites on one sha, orders the rows into
batches of disjoint files (R1), names each row's kind, vendor and R7
reviewer, and proposes one brief per row. It writes no code.

**Status: v1.5, signed v1.0 plus the owner's answers (v1.1), review a-475's fixes (v1.2), the owner's answer to Q1b (v1.3), review a-521's fixes (v1.4) and the owner's answer to Q1c (v1.5).** Panel PASS (c-342, same-vendor panel, waiver)
on v0.2 `cca84bfdf`; landed as `49f244c16` + `0989526af` (the same tree,
messages reworded for the release-note gate) on the dispatch holder's GO.
Owner questions Q1-Q3 are answered (poll `bb3b76c2`, 2.4): Q1 the
owner's own option (spec D21), Q2 B (spec D22), Q3 A. Q1b is answered
(spec D23: one "Scheduled tasks" dialog per topic, channel, issue and
epic; Settings stays admin-only); Q1c is answered A (spec D24: a
member's unbound task is refused, made per epic or per channel instead).
No owner question is open. Planner: c-074 (claude, the
backup for `specs_and_docs`: agy on its usage limit; the brief's addendum
reads 2026-11-30T21:31Z on one box, the holder's note 8cc25fff "quota out
to 12-01"; the placer reads the live pick, not this line). Panel: one seat,
**c-342 (claude), same-vendor panel, waiver**: agy is out of quota, grok is
off, and mistral sits on no review seat (rulebook 2.7.2). v0.1 (`36d85b32f`)
got FAIL W1-W7; v0.2 answers each; v0.2 PASS (section 4).

**One sha.** Every read is on **`5906e1fe2`** (`origin/master` at
2026-11-24T11:01Z, after a fresh fetch), with `git show` / `git grep`, n=1
per command. `git merge-base --is-ancestor 07f34efeb 5906e1fe2` -> rc 0:
spec 187 v0.3 is in the tree planned on, and no commit after it touches the
spec folder (`git log 07f34efeb..5906e1fe2 -- csi-spl-doc/specs/187-scheduled-tasks-activities`
-> empty). Lane map, queue, vendor and box picks are live state and carry
their own time.

## 1. Baseline

### 1.1 Nothing of spec 187 is built

- `git grep -il -E "scheduled.task|scheduled_task|scheduled-runs|taskcron|hub_settings|topic_labels|message_labels" 5906e1fe2 -- csi-spl-api csi-spl-rdb csi-spl-wui/src | wc -l`
  -> **0**.
- **rdb head.** `git ls-tree --name-only 5906e1fe2 csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1`
  -> `0319_workspace_cancellations.sql`; `git ls-remote origin 'refs/rdb-claims/*'`
  -> highest claim `0320`. S1 and S11 each take their number with
  `cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` when they
  write the file (developer guide 2.8.3); today that is 0321 or later.
- **Search grammar is already 1.7.** `git grep -n 'Version = ' 5906e1fe2 -- csi-spl-api/src/go/spool-hub-api/internal/search/grammar.go`
  -> `:22 const Version = "1.7"`, set by `aafacf21a` (SPL-6251,
  `type:calendar`, 2026-11-22), after spec 187 v0.3 was written. The spec's
  "grammar 1.7" for `idle:` / `changed:` (S2) and `label:` on topics and
  messages (S11) therefore becomes the next free version at build time
  (1.8 today): 2.4 N2.

### 1.2 What spec 182 (topic loops) already built: the shared hooks (D9)

Spec 182 L1-L3 are on master (store `0301_topic_loops.sql`; hub
`hub/topic_loop.go`, `hub/topic_loop_fire.go`; store `store/topic_loop.go`,
`topic_loop_memory.go`, `topic_loop_postgres.go`, each with tests:
`git ls-tree -r --name-only 5906e1fe2 csi-spl-api/src/go/spool-hub-api/internal | grep topic_loop`
-> 9 files). Its hook calls, `git grep -n -E "topicLoop[A-Za-z]*\(" 5906e1fe2 -- '<api>/hub/*.go'`
outside its own files:

| hot path | 182's call on 5906e1fe2 | 187 event | 187 row S4 adds |
|---|---|---|---|
| `wuiAfterStore` `hub/wui.go:649` (web UI post, after the store) | `:658` `s.topicLoopHuman(...)` | `message_new`, `topic_new` | one call beside `:658`, its own function |
| `wuiSend` before the store | `:621` `s.topicLoopBeforeAgent(...)` | none (187 fires only on an inserted row) | nothing |
| `onSend` `hub/ws.go:656` (an agent's post, after `commitRowTyped`, `:1045`) | `:724` `s.topicLoopAgent(...)` | `message_new`, `topic_new` | one call beside `:724` |
| `createIssueOn` `hub/issues.go:360` | **none** (182 has no "new issue" trigger) | `issue_new` | a new call after the store write (spec 187 4.2 reads "the hooks spec 182 names"; here there is no 182 hook to share) |
| `updateIssue` `hub/issues.go:419` | `:449` `topicLoopIssueBefore`, `:471` `topicLoopIssue` | `issue_changed` | one call beside `:471` |
| `handleSetMessageKind` `hub/message_kind.go:132` | `topicLoopKindBlocker` | none | nothing |

Reused patterns, cited: 182's time ticker `runTopicLoopTimer`
(`hub/topic_loop_fire.go:586`) started at `hub/server.go:744`, beside
`runGcalSync` (`:742`, ticker `gcalSyncEvery` `hub/gcal_sync.go:44`, its
loop `:86`), both inside `RunSweeper` (`server.go:731`); the test seam
`TopicLoopTickOnce` (`:603`); the claim `ClaimDueTopicLoops`
(`store/topic_loop_postgres.go:267`, memory `:203`); the loop-id context
(`withLoopID` / `loopIDOf`, `topic_loop_fire.go:572,579`), which
`commitRowTyped` copies into the row (`ws.go:1075`) and which is the model
of 187's `taskChainKey`. "A loop prompt message is never a trigger" (187
4.2) is `isLoopTrigger` (`topic_loop_fire.go:195`).

### 1.3 Sites, re-measured on 5906e1fe2

`api:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `rdb:` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`, `wui:` = `csi-spl-wui/src/`.
Where the spec's line differs, both are given.

| site | spec says | on 5906e1fe2 |
|---|---|---|
| `api:hub/server.go` `RunSweeper`, `runGcalSync` start | `:700`, `:711` | `:731`, `:742`; `runTopicLoopTimer` `:744` (1012 lines) |
| `api:hub/gcal_sync.go` `gcalSyncEvery`, ticker | `:44`, `:80` | `:44`; `runGcalSync` `:86`, `NewTicker` `:87` |
| `api:hub/wui.go` `wuiAfterStore` | (by name) | `:649` (1479 lines) |
| `api:hub/ws.go` `onSend`, `commitRowTyped` | (by name) | `:656`, `:1045` (1275 lines) |
| `api:hub/issues.go` `createIssue`, `createIssueOn`, `updateIssue` | `:353,360,419` | same (1250 lines) |
| `api:hub/dispatch.go` `dispatchEnvelope` | (by name) | `:228` |
| `api:hub/public_notice.go` `PostPublicNotices` | `:27` | `:27` |
| `api:hub/operator.go` `operatorEnabled`, `operatorAuth` | `:37`, `:43` | same |
| `api:rbac/rbac.go` `TenantSettings` | `:27` | `:27` |
| `api:config/config.go` `MemberCardNameOnlyWorkspaces` | `:549` | `:560` |
| `api:store/tenant_kv.go` `TenantSettingDef`, `RegisterTenantSetting` | `:57`, `:84` | same |
| `api:store/tenant_settings.go` `ArchivePolicyStarter` | `:49` | `:49` |
| `api:store/system_tenant.go` `SystemTenant` | `:10` | `:10` |
| `api:store/channels.go` `ChannelTasks`, `DefaultChannels`, `PublicChannels` | `:40`, `:44`, `:49` | same |
| `api:store/token_budget.go` `BudgetLimitMonth` | (by name) | `:31` |
| `api:hub/token_budget.go` `tokenBudget` | (by name) | `:40` |
| `api:hub/usage_events.go` `meterTurn` | `:43` | `:43` |
| `api:hub/fallback.go` `agentOnline` (D11's "online") | `presence.go` | `:74`; `presence.go` holds the TTL (`:26`, `:36`) |
| `api:search/grammar.go` `Version`, `MaxQueryUnits`, `label:` | `:21`, (name), `:204` | `:22` (`"1.7"`), `:26`, `:213` (`Applies: []Type{TypeIssue}`) |
| `api:search/match.go` `MatchMsg`, `MatchTopic`, `MatchEntity`, `OpLabel` | `:87`, `:162`, `:191`, `:221` | same |
| search compile (Postgres) | "the stores' compile" | `api:store/search_postgres.go` (also `search_docs_postgres.go`, `search_file_lines_postgres.go`, which S2 and S11 do not change) |
| fixed-action routes | 4.3 table | move `hub/topic_merge.go:49`; message archive `server.go:573-574` -> `handleArchiveTopic` `hub/topic_archive.go:197`; kind `server.go:568`; topic priority `hub/topic_priority.go:38`; issue archive `hub/issues.go:887`; channel archive `hub/channel_members.go:42` |
| `rdb:0047_issues.sql` `issue_labels`, `labels text[]` | `:33`, `:59` | same |
| `rdb:0214_topic_priorities.sql` | `:27` | `:27` |
| `rdb:0223_tenant_role_grants.sql` `issues.edit` | `:46` | `:46` |
| `rdb:0173_default_channel_public.sql` `spool_seed_default_channels` | last definition | `:26` (still the last) |
| `api:channelmove/catalogue.go` | (by name) | `topic_priorities` `:92`, `issue_labels` `:195` (245 lines) |
| `api:store/rls_test.go` `TestRLSCoversEveryTenantTable` | (by name) | `:103` |
| `api:hub/roundtrips_perf_test.go` `TestRoundTripsPerRequest` | (by name) | `:30` |
| `api:hub/openapi_routes_test.go` `TestOpenAPIRoutes` | (not cited) | `:314`: every new route of S6, S7 and S11 is also written into `api:hub/openapi.json` |
| WUI entry points (Q1 = spec D21) | "Settings -> Scheduled tasks"; a "Scheduled tasks" item in the channel and topic right-click menus | channel row menu `wui:components/SidebarRowMenu.vue` (`choose(id)` `:245-277`; items built by `wui:utils/sidebar-row-menu.mjs` `rowMenuItems` `:17-58`, channel block `:24-37`), opened from `ChannelSidebar.vue` `@contextmenu` (`:325`); topic card menu `wui:components/MessageMenu.vue` (spec 182's `loops` item `:75`, `:203`; items built by `wui:utils/msg-menu.mjs` `msgMenuItems` `:102-162`, `topic-loops` `:155`, desktop only), shown by `MessageCard.vue`'s `topicMenu` (`:764-767`); read on `5adcd5fdd`. A channel's item lists that channel's tasks, a topic's that topic's (S7's `?channel=` / `?topic=`). D23 (read on `208e5f757`): the issue and epic menu `wui:composables/useIssueCtxMenu.ts` `menuItemsFor` (`:45`; `top` = epic or feature), opened from an issue row, the sidebar epic row (`wui:components/IssueEpicsPanel.vue` `:22`, `onEpicContext` `:67`) and the epic title-row button (`openEpicMenu` `:91`); the issue detail header `wui:components/IssueDetailActions.vue` (`:50`). S7's `?issue=` / `?epic=` |
| WUI Settings sections | "Settings -> Scheduled tasks" | `wui:utils/tenant-settings-nav.ts` (94 lines): each section carries a `perm` (`:29-39`), filtered by `filterByPerm` (`:69`); pages under `wui:pages/tenant-settings/` (13 files) |
| `csi-spl-wui/i18n/locales/` | (by rule) | 19 files |
| user help | S10 | `csi-spl-doc/doc/help/` (31 files), copied by `node src/node/help/sync-help.mjs` (csi-spl-wui; `--check` exits 1 on a difference) |

## 2. Rows

Kinds from spec 187 section 9; vendors from
`LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` (csi-spl-orc, 11:04Z):

| kind | pick at 11:04Z | main / backup |
|---|---|---|
| `simple_coding` | agy | claude / agy |
| `complex_coding` | claude | claude / agy |
| `tests` | claude | claude / agy |
| `specs_and_docs` | agy | agy / claude |
| `i18n` | agy (the required check is Google Cloud Translation, `do_spl_lang_review_gct`; an agy review is optional) | agy |

agy is on its usage limit until 2026-11-30T21:31Z on one box (the brief's
addendum); the placer re-runs `do_spl_lane_mix` at placement and takes the
backup when the main cannot run. S8, S9 and S10 (its help copy) touch
`csi-spl-wui/` and never go to mistral (developer guide 5.1); no coding or
test row goes to mistral (owner b61851fb msg 91bf8278).

**R7** (rulebook 2.7.2: agy reviews claude, claude reviews agy). The R7
reviewer of every claude-authored row is an **agy** seat. Grok is off
fleet-wide (cnf `all.env.yaml`, "grok off, t1 476aff8f msg 6c969b3c") and
mistral sits on no review seat (`mistral_review_allowed: false`), so
neither is named. While agy is out of quota (above), the row's R7 is a
**claude same-vendor seat, waiver**, as this plan's own panel: a fresh
session, the tree only, the brief names the waiver. It lapses when the
placer's agy pick comes back, and what counts is when the verdict is given,
not when the seat was placed. An agy-authored row takes a claude reviewer.
No other same-vendor line.

### 2.1 Action table

| row | what | kind | vendor (main) | R7 | depends on | batch |
|---|---|---|---|---|---|---|
| S1 | rdb + store: tasks, runs, `hub_settings`, `#scheduled-runs` | complex_coding | claude | agy (claude waiver while agy out; 2 R7) | none | 1 |
| S2 | grammar: `idle:`, `changed:`, `key:`, `epic:` | simple_coding | claude (pick agy; either) | agy if claude (waiver while out); claude if agy | none | 1 |
| S12a | cron parser `api:taskcron` | simple_coding | claude (pick agy; either) | agy if claude (waiver while out); claude if agy | none | 1 |
| S3 | hub runner + fixed actions + run cap + the two seams (2.4 N4 f) | complex_coding | claude | agy (waiver while out) | S1 | 2 |
| S4 | event triggers + chains | complex_coding | claude | agy (waiver while out) | S3 | 3 |
| S7 | workspace routes | simple_coding | claude (pick agy; either) | agy if claude (waiver while out); claude if agy | S1, S2, S3 | 3 |
| S12b | cron in store validation and next time | simple_coding | claude (pick agy; either) | agy if claude (waiver while out); claude if agy | S12a, S3 | 3 |
| S5 | agent action + token cap + reply hook + timeout | complex_coding | claude | agy (waiver while out) | S3, S4 (reply hook), S12b (`scheduled_tasks.go`) | 4 |
| S11 | labels on topics and messages | complex_coding | claude | agy (waiver while out) | S1, S2, S3 (`scheduled_task_actions.go`), S7 (`server.go`) | 4 |
| S6 | two levels | complex_coding | claude | agy (waiver while out) | S1, S3, S11 (`server.go`) | 5 |
| S8 | web UI, then the language check | simple_coding | claude (never mistral) | agy (waiver while out) | S6, S7, S11, S12b | 6 |
| S9 | e2e | tests | claude | agy (waiver while out) | S8 | 7 |
| S10 | docs + help | specs_and_docs | agy, backup claude (never mistral) | cross to the author (claude if agy; agy or waiver if claude) | S3-S9, S11, S12b | 8 |

S12 is split in two, as spec 187 9 and its tasks.md T012 already say
("parser: —; store and runner part: T003"). S6 depends on S11 and S8 on S6
here for the shared files and the Instance section (2.2, 2.4 N4 e). S5
moves to batch 4 (v0.2, W4): its reply hook sits in S4's file and its
timeout in the ticker file S12b also edits. 13 rows exceed rulebook 1.1's
hard cap of 10: owner question Q3 (2.4), answered A (one plan).

### 2.2 Batches and disjoint files (R1, R16)

The binding constraint is `api:hub/server.go` and `api:hub/openapi.json`:
S3 starts its ticker in `server.go` (beside `:744`), and S6, S7 and S11
each register new routes there and in `openapi.json`
(`TestOpenAPIRoutes`). R1 lets no file sit in two rows of one batch, so
these four rows take four batches. 2.4 N3 offers the holder a shorter
order.

- **Batch 1: S1, S2, S12a.** S1: one new `rdb:<NNNN>_scheduled_tasks.sql`;
  new `api:store/scheduled_task.go`, `scheduled_task_postgres.go`,
  `scheduled_task_memory.go`, `scheduled_task_test.go`, `hub_settings.go`;
  `api:store/channels.go`; `api:store/rls_test.go`;
  `api:channelmove/catalogue.go`. S2: `api:search/grammar.go`,
  `values.go`, `match.go`, `grammar_test.go`, `api:store/search_postgres.go`,
  `api:hub/search.go` + `api:hub/search_issue_test.go` (D23's `key:` /
  `epic:`, no other row touches them),
  `csi-spl-doc/specs/003-spool-message-bus/contracts/search-v1.md`. S12a:
  new `api:taskcron/cron.go`, `cron_test.go`. No path in two rows.
- **Batch 2: S3.** New `api:hub/scheduled_tasks.go` (ticker, claim, next
  due time), `scheduled_task_run.go` (`runTask`),
  `scheduled_task_actions.go` (the fixed actions, an action table keyed by
  `action_kind`), `scheduled_task_limits.go` (`taskEffective` with the
  instance defaults of 5.1 and the run cap; S6 extends it), their tests;
  `api:hub/server.go` (the ticker start and the 30-day delete chore).
- **Batch 3: S4, S7, S12b** (within 30 min of S3 landing, R16). S4:
  `api:hub/wui.go`, `ws.go`, `issues.go`, `scheduled_task_run.go` (the
  chain check), new `api:hub/scheduled_task_events.go` + test (it also
  registers the "has event tasks" refresh on S3's task-write seam, 2.4 N4
  f). S7: new `api:hub/tasks_routes.go` + test, `server.go`,
  `openapi.json`; every task save calls S3's `validateTaskSave` and every
  create, update and delete calls S3's `afterTaskWrite` (2.4 N4 f). S12b:
  `api:store/scheduled_task.go` (the `cron` validation),
  `api:hub/scheduled_tasks.go` (the `cron` next time, and the save-time
  floor walk as a validator on S3's `validateTaskSave` seam). Disjoint;
  no edge inside the batch.
- **Batch 4: S5, S11.** S5: new `api:hub/scheduled_task_agent.go` + test
  (it adds `agent` to S3's action table from its own file);
  `api:hub/scheduled_task_events.go` (S4's, landed: its `onSend` hook
  hands a reply in a run's topic to S5's `taskAgentReply`, which closes the
  run); `api:hub/scheduled_tasks.go` (S3's and S12b's, landed: the
  `agent_run_timeout_min` sweep in the ticker, ending a run `no_answer`).
  S11: new `rdb:<NNNN>_topic_message_labels.sql`; new
  `api:store/object_labels.go`, `object_labels_postgres.go`,
  `object_labels_memory.go`, `object_labels_test.go`; `rls_test.go`;
  `catalogue.go`; `api:search/grammar.go`, `match.go`, `grammar_test.go`;
  `api:store/search_postgres.go`; new `api:hub/object_labels.go`;
  `server.go`; `openapi.json`; `search-v1.md`; and the `label` fixed action
  for topics and messages in `scheduled_task_actions.go` (2.4 N4 d).
- **Batch 5: S6.** New `api:hub/operator_tasks.go` + test;
  `scheduled_task_limits.go`; `api:config/config.go`; the 5.2 settings'
  registration (`RegisterTenantSetting`, in `operator_tasks.go` or a new
  `scheduled_task_settings.go`); `server.go`; `openapi.json`.
- **Batch 6: S8.** `wui:components/ScheduledTasks*.vue`, a new
  `wui:pages/tenant-settings/scheduled-tasks.vue`,
  `wui:utils/tenant-settings-nav.ts`, the "Scheduled tasks" item in
  `wui:components/SidebarRowMenu.vue` + `ChannelSidebar.vue` +
  `wui:utils/sidebar-row-menu.mjs` and in `wui:components/MessageMenu.vue`
  + `MessageCard.vue` + `wui:utils/msg-menu.mjs` (Q1, spec D21), the one
  new `wui:components/ScheduledTasksDialog.vue` and its item in
  `wui:composables/useIssueCtxMenu.ts` + `wui:components/IssueDetailActions.vue`
  + a new `wui:composables/useScheduledTasksDialog.ts` (Q1b, spec D23),
  the Instance section, the four
  templates, the topic and message label chips, `wui:utils/spool-client*.mjs`,
  `csi-spl-wui/i18n/locales/*.json`, their unit tests.
- **Batch 7: S9.** New `csi-spl-wui/tests/e2e/scheduled-tasks.test.mjs`
  only.
- **Batch 8: S10.** `csi-spl-doc/specs/187-scheduled-tasks-activities/spec.md`
  and `tasks.md` (row states), a new `csi-spl-doc/doc/help/<page>.md` and
  its copy under `wui:public/help-md/` (`sync-help.mjs`).

S5 and S11 share no path.

Order of the serial rows: S3 first (four rows wait on it), S7 in batch 3
(S8's list and editor need it), S11 before S6 (S11 also feeds S9's label
chips and is the larger store change), S6 last of the api rows.

### 2.3 R3: live and queued lanes, read 11:02-11:04Z (v0.1)

`lane-map.sh --check <row paths> --agent c-074`, per row:

- **c-918** (`c-918-c002-s181-b11-signin-relay`, spec 181 B11): at v0.1 it
  had changed `api:hub/server.go`, `ws.go`, `openapi.json`,
  `api:config/config.go`, `wui:utils/spool-client.mjs` and the locales.
  **Landed since** (v0.2): `git merge-base --is-ancestor <c> origin/master`
  rc 0 on `787a3814a` for each of `61869b56f`, `a51a7f1da`, `50dbdaa6d`
  (SPL-6345), so no row waits on it any more.
- **c-299** (s158 wui-create-wait-text, no files recorded): the panel's
  live `--check` flags `csi-spl-wui/i18n/locales/en.json` for it, S8's
  path; the placer asks it at S8's placement.
- **15 lanes with no files recorded** (exit 4 on every other row's paths):
  c-029, c-041, c-086, c-146, c-187, c-728, c-927, g-565, g-730 (rotation
  seats), c-678 (`s181-b9-keep-invoices-at-purge`), c-680
  (`bug-acfc125c-back-from-section-top-to-topic`), c-713, c-714, c-721
  (hand-placed release-tooling lanes), c-747
  (`c002-agent-login-from-wui-spec`, a spec lane). Not free by the rule:
  the placer re-runs `--check` per row at placement (R3) and asks any lane
  that still answers exit 4.
- **Queue** (`./run -a do_spl_spawn_queue`, 11:03Z, 6 rows): the skills
  panel editor (SPL-6375), perf rounds 19 and 20 planners, a revoke-card
  spec, a spec 149 change, spec 154 contacts. Their summaries name no file
  of this plan; the two perf planners write plans only. The placer
  re-checks at placement.

### 2.4 Rows needing a decision

**For the owner (the holder asks as a form).** Answered (poll
`bb3b76c2`, relayed by c-002, 2026-11-25): Q1 the owner's own words, msg
`7b63c45e`: "There should be a scheduled tasks option in the right-click
menu, both on the channels and on the topic level." (spec D21); Q2 **B**,
msg `e17e6c09`: "A new field, mention_assignee (yes or no)" (spec D22); Q3
**A**, msg `e17e6c09`: "One plan, 13 rows in 8 batches, at most 3 rows live
at once". Spec 187 v0.4 carries Q1 and Q2 (6.2, 4.3, 9.1.1, 9.1.5, 7.2);
the briefs below follow it.

- **Q1b (answered v1.3, below; review a-475 W1).** Q1's menus
  list a channel's and a topic's tasks; they do not reach tasks over all
  channels or `issue` tasks (spec 4.1: issues are all channels only),
  which D17 lets a member own. Settings is admin-only
  (`wui:utils/tenant-settings-nav.ts:28-40`; `csi-spl-wui/tests/unit/tenant-settings.test.mjs:31`
  "CONTROL: a developer sees no entry"). A: Settings stays admin-only, and
  members get a non-Settings entry for those tasks (the `#scheduled-runs`
  channel menu, or the Issues header). B: "Settings -> Scheduled tasks"
  opens to every member (the test changes; Settings shows to non-admins).
  Spot: S8 only; batches 1-5 do not wait on it. **Answered (v1.3)**: the
  owner chose B (msg `b6acff79`) and withdrew it (msg `6b1806e4`,
  verbatim: "no no sorry , not b , the scheduled tasks should be accesible
  via a dialog box , which could be set per discussion/topic and per
  channel , and per issue , and per epic"). Spec D23: ONE dialog, opened
  per topic and channel (D21's menus) and per issue and epic (the issue
  menu `menuItemsFor`, the issue detail header, the epic sidebar row and
  title button); Settings stays admin-only. A contract change in three
  rows: S2 adds `key:` and `epic:` on issues to grammar 1.7 (matched in
  `api:hub/search.go` `issueEntities`, v1.4), S7 (now after S2) adds
  `GET /v1/tasks?issue=` / `?epic=`, S8 builds the dialog and the two new
  entries (S9 opens all four). No row, batch or vendor moves; S2 gains
  `api:hub/search.go` (v1.4), S7 keeps its files.
- **Q1c (raised by D23; spec 187 1.3). Answered A (v1.5)**, msg
  `c5143a2f`, verbatim: "Admins only: a member's save is refused, and a
  member makes such a task per epic or per channel" (spec D24). The rows
  are built with A as planned; nothing moves. As asked:
  No dialog lists, for a member who is not an admin: (a) a `topic` or
  `message` task over all channels (one naming several channels lists in
  each one's dialog); (b) an `issue` task with no positive `key:` or
  `epic:` leaf. Templates 7.2-7.4 opened from a dialog take its object's
  scope. Admins reach every task in Settings. **A (recommended)**: (a)
  and (b) admin-only, S7 refuses a non-admin's with `403 not_allowed`.
  **B**: members keep them, S8 adds a fifth entry (e.g. the user menu)
  over a filter S7 adds. Spot: S7, S8, S9. No batch waits: the rows are
  built with A; B changes S7 (drop the refusal, add the filter), S8 (the
  entry) and S9.

The questions as asked:

- **Q1. Where a member opens "Scheduled tasks".** Spec 6.2
  (`spec.md:526-530` at `07f34efeb`) puts the list in Settings and lets "a
  member see their own and, read-only, the others". Every Settings section
  is gated by a permission (`wui:utils/tenant-settings-nav.ts:29-39`,
  `filterByPerm`), and only the roles holding `tenant.settings` are admins
  (spec 4.5). Reading: the section shows to every member while
  `tasks.members_may_create` is on, and to admins always. Note: 6.2 does
  not tie a member's view to `members_may_create`; that tie is this
  reading's, and the question shows it. Alternative: members reach their tasks from the
  `#scheduled-runs` channel header, and Settings stays admin-only. Spot:
  S8 (S7's `GET /v1/tasks` already answers a member, spec 6.2).
- **Q2. Template 7.2 "mentioning each issue's assignee".** Template 7.2
  (`spec.md:562`) says "mentioning each issue's assignee"; the `notify`
  action (`:301`) says "`@`-mentioning listed members", and the binding
  contract's `TaskActionSpec.Mention` (9.1.1, `:815`, "notify: member
  ids") is a fixed list; nothing in it names "the assignee of each matched
  object". Reading:
  a reserved value `assignee` in `mention` resolves per object at run time
  (the issue's assignee; for a topic, its starter). Alternative: a new
  `mention_assignee bool` field. Either is a contract change that lands in
  the spec before the code (spec 9.1); S3 builds `notify` with fixed ids
  only until it is decided. Spot: S3 (or the row the holder names), S8
  (the template).
- **Q3. Round size.** Rulebook 1.1 (`rounds-rulebook.md:24-26`): "A round
  must never exceed 10 rows. The 10 is the hard cap for every kind." This
  plan has 13 rows (S12 split); no build-round exemption is written
  (`git grep -n -i 'build round' origin/master -- csi-spl-doc/doc/md`
  finds only the build plans). Precedent: spec 153's plan named the same
  breach (13 rows) as its H7, and the owner answered A, one plan
  (`spec-153-build-plan.md:163`). Reading (A): one plan, 13 rows in 8
  batches; the batches keep at most 3 rows live (batch 3). Alternative
  (B): cut after batch 4: round 1 = S1, S2, S12a, S3, S4, S7, S12b, S5,
  S11 (9 rows, batches 1-4); round 2 = S6, S8, S9, S10 (4 rows, batches
  5-8) under its own plan version and panel line. Spot: the holder's
  queueing only; no row brief changes. Until answered, nothing past batch
  4 is queued under either reading.

**For the holder (no owner question).**

- **N1. Epic.** The brief says SPL-2403; spec 187 and its tasks.md say
  SPL-2398. This plan carries the brief's line; each row brief carries
  whichever the holder names.
- **N2. Grammar version.** 1.7 is taken (1.1). S2 bumps to the next free
  version at its build time (1.8 today) and S11 to the one after, unless
  S11 lands in the same unreleased version; each row re-reads `Version`
  and writes its version into `search-v1.md`. The matching one-line fix
  of spec 187 4.3.1 and 7 goes with S10.
- **N3. A shorter order (needs an R1 waiver).** Batches 2-5 are four only
  because of `server.go` and `openapi.json`. Putting S6, S7 and S11 in one
  batch would put those two files in three rows of one batch, which
  **breaks** R1 (`rounds-rulebook.md` 2.1); it needs an explicit R1 waiver
  from whoever may grant one, and this plan does not assume it. The plan as
  written keeps R1 strict.
- **N4. File split decisions the spec leaves to the build.** (a) S3's
  `runTask` checks the run cap with the instance defaults
  (`scheduled_task_limits.go`); S6 extends that file with overrides and
  the workspace level. (b) The token cap is S5's alone: only an agent run
  spends tokens (spec 5.3 item 4). (c) S5 adds `agent` to S3's action table
  from its own file. (d) The `label` action on topics and messages is
  wired by S11 (S3 builds it for issues; the store S11 adds does not exist
  before), so S3 depends only on S1, as the spec says. (e) S8 also depends
  on S6 (the Instance section reads the 5.1 routes). (f) **Two seams S3
  owns** (v0.2, W5 and W6), in `scheduled_tasks.go`: `validateTaskSave(ctx,
  t) error`, a list of validators run before every task save (S3 seeds it
  with the scope and action checks; S12b adds the cron floor walk against
  the effective `tasks.min_interval_min`, spec 4.2.1 `spec.md:253-255`);
  and `afterTaskWrite(ctx, tenant)`, a list of hooks run after every task
  create, update and delete (S4 registers the "has event tasks" refresh,
  spec 8.2 `spec.md:702-703`). The callers are S7's `tasks_routes.go`
  (batch 3) and S6's `operator_tasks.go` (batch 5). Registration is from
  each row's own file, so batch 3 has no edge inside it. (g) **The agent
  reply and timeout** (v0.2, W4): an agent's post reaches the hub only via
  `onSend` (`ws.go:724` at `5906e1fe2`, `:725` on `787a3814a`), whose
  187 hook is S4's `scheduled_task_events.go`; S5 (batch 4) adds there the
  hand-off of a reply in a run's topic to its `taskAgentReply`, and the
  `agent_run_timeout_min` sweep (`no_answer`, spec `:402-404`) to the
  ticker in `scheduled_tasks.go`.
- **N5. The language step.** Spec 187 6.3 says "agy has the final word on
  the locales"; the rule since SPL-6174 (owner msg 36b3ff7f) is the Google
  Cloud Translation check `do_spl_lang_review_gct`, an agy review optional.
  S8 adds the en keys and machine drafts for the 18 other locales, runs
  `cd csi-spl-orc && ./run -a do_spl_lang_review_gct` over its new keys,
  and carries the `Lang-review: gct <run id>` line the pre-push part
  `wui-lang-review` checks. S10's help page is English only.
- **N6. Round size.** Rulebook 5.1's 2-3 rows binds bug-fix and refactor
  rounds only (`rounds-rulebook.md:293`), not this build round. Rulebook
  1.1's hard cap of 10 does bind it: 13 rows, owner question Q3. The
  batches cap the live rows at three (batch 3).
- **N7. Drift since `5906e1fe2`.** At v0.2, `origin/master` is `787a3814a`;
  the hooks moved (`wui.go` topicLoopHuman `:669`, `ws.go` topicLoopAgent
  `:725`, `issues.go` `:471`, `server.go` runTopicLoopTimer `:752`) and the
  rdb head is `0323_fleet_ask_queue_order.sql`; the grammar is still 1.7.
  Every brief re-measures its lines at work time.

## 3. Proposed row briefs

Each brief carries: `Epic:` (2.4 N1), `Spec: csi-spl-doc/specs/187-scheduled-tasks-activities`,
`Class: feature`, its `Kind:`, its row's line of spec 187 section 9
verbatim (R4), its R7 seat, "plan on origin/master at work time, re-measure
the cited lines", the binding contract of spec 9.1 it builds or calls, and
the fleet's standing Never list (no prd writes, no installs, no keys, no
owner-topic post, PUBLIC repo hygiene, commit as the repo's identity,
explicit pathspecs, no force-push). Each row files its own issue at
placement and cites it in its subject, e.g.
`feat(api, SPL-<n>): ... (spec 187 S3)`.

### 3.1 S1 - rdb + store

- Kind `complex_coding`. Batch 1. R7 agy (the claude waiver seat while agy is out; 2 R7).
- Files: batch 1's S1 list (2.2). Migration number from
  `DRY_RUN=0 ./run -a do_rdb_migration_next` (csi-spl-orc). The SQL is
  spec 8.1's S1 block, plus `scheduled-runs` added to
  `spool_seed_default_channels` (its last body, `rdb:0173:26`) and inserted
  for every existing workspace, as `0173` did for `#public`.
- Contract: spec 9.1.1 whole, v0.4 (with `TaskActionSpec.MentionAssignee`, D22) (`ScheduledTaskStore`, both stores, the
  constants, `ChannelScheduledRuns` in `channels.go` beside
  `ChannelPublicID`). `DefaultChannels` gains it (`channels.go:44`);
  `PublicChannels` follows (`:49`). Cron validation is a stub that refuses
  `trigger_kind = cron` with `ErrBadTask` until S12b.
- Done and red control: spec 187 S1's cells verbatim (parity, each CHECK,
  two claimers, the second run insert a no-op, RLS on both tenant tables
  and the instance row invisible in a tenant scope, `#scheduled-runs` in a
  new and an existing workspace; red: drop `next_due_at <= now()` and the
  two-claimer test runs the task twice). `PRE_PUSH_TIER=full`.
- Test column (R2), at least: `store/rls_test.go`, `store/channels_test.go`,
  `store/channel_issues_test.go`, `store/channel_delete_test.go`,
  `store/set_reads_test.go`, `store/stmt_print_test.go`,
  `store/clock_seam_test.go`, `store/flow_fold_plan_test.go`,
  `store/flow_tail_test.go`, `hub/channel_privacy_test.go`,
  `hub/channel_delete_test.go`, `hub/public_notice_test.go` (each names
  `DefaultChannels` or `PublicChannels`), the channel-move tests, and
  `bash csi-spl-api/src/bash/tests/run-all-tests.sh`.
- Not touched: any `api:hub/` file, the search package.

### 3.2 S2 - grammar `idle:`, `changed:`, `key:` and `epic:`

- Kind `simple_coding`. Batch 1. R7 agy if placed on claude (the waiver
  seat while agy is out); claude if placed on agy.
- Files: batch 1's S2 list. Version: 2.4 N2. It edits a store file
  (`api:store/search_postgres.go`): `PRE_PUSH_TIER=full`.
- Content (spec 7): `idle:<duration>` (a topic: no message since; an
  issue: no change since) and `changed:<duration>` (its inverse), on
  `TypeTopic` and `TypeIssue`; in `MatchTopic` / `MatchEntity` and in the
  Postgres compile (`search_postgres.go`); `after:` / `before:` unchanged.
  D23 (v1.3, v1.4): `key:<KEY>` (exactly that issue) and `epic:<KEY>`
  (the issues and subtasks whose level-1 row is KEY, not KEY itself), on
  `TypeIssue` only. Issues are not compiled in Postgres
  (`search_postgres.go` has no issue term): add `Key` and `Epic` to
  `search.Entity` (`api:search/match.go:43`), set them in `issueEntities`
  (`api:hub/search.go:825`) with `treeKind` (`api:hub/issues.go:120`), and
  match them in `MatchEntity`.
- Done and red control: spec 187 S2's cells verbatim (31-day vs 29-day
  topic in both paths; an issue by its last change; `changed:7d` the
  inverse; `key:SPL-7` not SPL-70; `epic:SPL-17` its issues, not itself;
  both refused on a non-issue type; red: compile `idle:` as `after:`).
- Test column: `search/grammar_test.go`, the `search/match*` tests,
  `hub/search_issue_test.go`, every store test of `search_postgres.go`, the operators route test
  (`GET /v1/view/search/operators`, search-v1 section 6), and any WUI test
  that reads the operator list (`git grep -l "search/operators" csi-spl-wui/tests`).
- Not touched: `label:` (S11's).

### 3.3 S12a - the cron parser

- Kind `simple_coding`. Batch 1. R7 agy if placed on claude (the waiver
  seat while agy is out); claude if placed on agy.
- Files: new `api:taskcron/cron.go`, `cron_test.go`; no module added
  (`go.mod` unchanged).
- Contract: spec 9.1.3 (`Parse`, `Schedule.Next`, `MinGap`, `ErrCron`).
- Done: spec 187 S12's parser cells (each field's range, lists, ranges,
  steps; `0`/`7` Sunday; the either-day rule; `*/30 8-18 * * 1-5` in
  `Europe/Helsinki` across a DST change; `MinGap` of `*/5 * * * *` is 5
  minutes and `0 0 30 2 *` has none; `MON`, `@hourly` `syntax`; 6 fields
  `fields`).
- Red control: drop the either-day rule and the `0 0 13 * 5` test fails
  (the save-time floor red control is S12b's, where the floor walk lives).

### 3.4 S3 - hub runner, fixed actions, run cap

- Kind `complex_coding`. Batch 2: after S1 has landed. R7 agy (waiver while out).
- Files: batch 2's list. The ticker `runScheduledTasks` (60 s, the
  `gcalSyncEvery` shape) is started beside `server.go:744`; a test seam
  `ScheduledTaskTickOnce` as 182's `TopicLoopTickOnce`
  (`topic_loop_fire.go:603`).
- Contract: spec 9.1.2 `runTask`, `taskEffective` (defaults only, 2.4 N4
  a), `taskLimits`; the fixed actions call the store paths of 1.3's route
  row under the owner's rights (4.5); the result post in the task's one
  topic in `#scheduled-runs` as `HUB-0` via the `public_notice.go` path;
  the run id a UUIDv5 of `(task_id, cause)` through `api:uid`. `label` on
  issues only; `notify` with fixed ids and `mention_assignee` (spec 4.3,
  D22: an issue's assignee, a topic's starter, a message's sender;
  "unassigned" mentions no one; one mention per member across the matched
  objects and `mention`). `validateTaskSave` refuses `mention_assignee`
  on `object = channel` (`ErrBadTask`). The two seams
  `validateTaskSave` and `afterTaskWrite` (2.4 N4 f), with their tests.
- Done and red control: spec 187 S3's cells verbatim (each schedule kind's
  next local time across a DST change, a missed tick runs once, each fixed
  action through its store path, D17's own-object test, owner left, 5
  failures pause, the reply in the one topic, D14's id-only naming, the
  post fires nothing; red: remove the own-object check at run).
- Test column: the new tests; `hub/public_notice_test.go`; the tests of
  each reused handler's store path (`topic_merge`, `topic_archive`,
  `topic_priority`, `issues`, `channel_members`); `TestRoundTripsPerRequest`
  (`hub/roundtrips_perf_test.go:30`); `bash csi-spl-api/src/bash/tests/run-all-tests.sh`.
- Not touched: `wui.go`, `ws.go`, `issues.go` (S4's hooks), any route.

### 3.5 S4 - event triggers and chains

- Kind `complex_coding`. Batch 3: after S3. R7 agy (waiver while out).
- Files: batch 3's S4 list. One call per hook beside 182's (1.2 table:
  `wui.go:658`, `ws.go:724`, `issues.go:471`) and a new one in
  `createIssueOn` (`issues.go:360`), each 187's own function in
  `scheduled_task_events.go`; the per-workspace "has event tasks" bit;
  registered on S3's `afterTaskWrite` (2.4 N4 f), so every task write
  refreshes it; `taskChainKey` modelled on `withLoopID` (`topic_loop_fire.go:572`); the
  chain check in `runTask`.
- Done and red control: spec 187 S4's cells verbatim (one run per new
  message, topic and issue; not on a replay, a `HUB-0` note, a loop prompt
  (`isLoopTrigger`), a `#scheduled-runs` post; `chain_self` for A -> A and
  A -> B -> A; A -> B -> C runs; no extra round trip with no event task;
  red: a 4-deep chain, remove the depth check, D runs).
- Test column: `hub/topic_loop_fire_test.go` and `topic_loop_test.go`
  (the shared hooks must leave 182 green), the `hub/wui*` and `hub/ws*`
  tests that name `wuiAfterStore` or `onSend`, the `hub/issues*` tests,
  `TestRoundTripsPerRequest`.
- Not touched: 182's functions (`topic_loop_fire.go`).

### 3.6 S5 - agent action and the token cap

- Kind `complex_coding`. Batch 4: after S3, S4 and S12b. R7 agy (waiver
  while out).
- Files: batch 4's S5 list (2.4 N4 c, g): new
  `api:hub/scheduled_task_agent.go` + test; the reply hand-off in S4's
  `scheduled_task_events.go`; the timeout sweep in `scheduled_tasks.go`.
- Content: spec 4.3 "Agent" and D11: one `kind: task` message in the
  task's topic, `dispatchEnvelope` (`dispatch.go:228`) + `commitRowTyped`
  (`ws.go:1045`) as 182's `loopSend` does; the named agent, else the most
  recently seen online agent (`agentOnline`, `fallback.go:74`), else
  `failed` `no_agent`; the answer closes the run;
  `agent_run_timeout_min`; the token cap read from the ledger (`rdb:0171`)
  the way `tokenBudget` (`hub/token_budget.go:40`) reads it; the 80 %
  notice once; spec 121's `429 token_quota` still applies.
- Done and red control: spec 187 S5's cells verbatim (red: count fixed
  runs against the token cap, and the fixed-run test is skipped at 100 %).
- Test column: the new test; S4's `scheduled_task_events` test (the
  reply hand-off); the `hub/token_budget*` and
  `hub/usage_events*` tests; `topic_loop_fire_test.go` (the send path it
  mirrors).

### 3.7 S7 - workspace routes

- Kind `simple_coding`. Batch 3: after S1, S2 and S3 (D23's leaves). R7 agy if placed on
  claude (the waiver seat while agy is out); claude if placed on agy.
- Files: new `api:hub/tasks_routes.go` + test, `server.go` (registration),
  `openapi.json` (the seven routes). Every save calls S3's
  `validateTaskSave`, every create, update and delete S3's
  `afterTaskWrite` (2.4 N4 f).
- Contract: spec 9.1.5 (`/v1/tasks` JSON, the errors, and D21's
  `GET /v1/tasks?channel=` / `?topic=` filters with a test each;
  `?topic=` matches a positive `OpTopic` leaf of `search.Parse`, the id
  lower-cased, so `-topic:<id>` is not a match); D23's `?issue=` /
  `?epic=` the same way over a positive `key:` / `epic:` leaf, a test
  each; D24 (Q1c A): a non-admin's `topic` or `message` task over
  all channels (empty `scope_where`), or an `issue` task with no
  positive `key:` / `epic:` leaf, answers `403 not_allowed`, a test;
  the `scope_where` check applies to `topic` / `message` only (spec
  4.5);
  `mention_assignee` on `object = channel` answers `400 bad_task` (D22)
  from S3's `validateTaskSave`, so S6's instance tasks share it.
  `GET /v1/tasks/preview` counts and writes nothing.
- Done and red control: spec 187 S7's cells verbatim (the D3 table; the
  grammar's error; red: save a member's task without narrowing its scope).
- Test column: the new test, `hub/openapi_routes_test.go`,
  `hub/openapi_serve_test.go`.

### 3.8 S12b - cron in the store and the runner

- Kind `simple_coding`. Batch 3: after S12a and S3. R7 agy if placed on
  claude (the waiver seat while agy is out); claude if placed on agy.
  It edits a store file (`api:store/scheduled_task.go`):
  `PRE_PUSH_TIER=full`.
- Files: `api:store/scheduled_task.go` (replace S1's stub: `taskcron.Parse`,
  `fields` / `range` / `syntax` / `never`), `api:hub/scheduled_tasks.go`
  (the `cron` next time with `Schedule.Next`; the save-time floor walk
  against the effective `min_interval_min`, `floor`, registered as a
  validator on S3's `validateTaskSave`, which S7's save calls; 2.4 N4 f).
- Done and red control: spec 187 S12's save cells (`*/15 * * * *` saves;
  `*/5 * * * *` and `0,10 * * * *` refused `floor`; `0 0 30 2 *` refused
  `never`; red: drop the floor walk and `*/5 * * * *` saves).

### 3.9 S11 - labels on topics and messages

- Kind `complex_coding`. Batch 4: after S1, S2, S3 and S7 have landed. R7 agy (waiver while out).
- Files: batch 4's list; migration number from `do_rdb_migration_next`.
- Contract: spec 9.1.4 (`ObjectLabelStore`, `ObjectLabelsMax`,
  `ErrBadLabel`), 9.1.5's `400 bad_label` and `204`; the 4.3.1 routes
  behind `issues.edit` (`rdb:0223:46`) and the object's read right;
  `label:` `Applies` gains `TypeMessage` and `TypeTopic` (`grammar.go:213`);
  the Postgres compile an `EXISTS` on the two tables; both tables in
  `catalogue.go`, a missing label created in the target catalogue by a
  move; the `label` fixed action for topics and messages (2.4 N4 d).
  Version: 2.4 N2.
- Done and red control: spec 187 S11's cells verbatim (red: leave
  `TypeMessage` out of `label:`'s `Applies`). `PRE_PUSH_TIER=full`.
- Test column: S2's search column, `rls_test.go`, the channel-move tests,
  `openapi_routes_test.go`, the issue label tests (the `hub/issues*` tests
  naming `labels`).

### 3.10 S6 - two levels

- Kind `complex_coding`. Batch 5: after S1, S3 and S11. R7 agy (waiver while out).
- Files: batch 5's list. `SPOOL_HUB_INSTANCE_ADMIN_WORKSPACE`
  (`envDefault:"t1"`) beside `MemberCardNameOnlyWorkspaces`
  (`config.go:560`); `instanceAdmin` (spec 9.1.2) with `rbac.TenantSettings`
  (`rbac.go:27`); the 5.1 routes behind `operatorAuth` (`operator.go:43`)
  and the new `instanceAdminAuth`; the 5.2 settings by
  `RegisterTenantSetting` (`tenant_kv.go:84`); `taskEffective` with 5.3's
  rules. Its instance-task writes call S3's `validateTaskSave` and
  `afterTaskWrite` too (2.4 N4 f).
- Done and red control: spec 187 S6's cells verbatim (D10 door test, D18
  defaults, instance off, the lower-cap rule, the action intersection, D16
  instance runs; red: count instance runs against the workspace cap).
- Test column: the new tests, the `hub/operator*` tests, the config tests
  naming `MemberCardNameOnlyWorkspaces`, the tenant settings registry
  tests, `openapi_routes_test.go`.

### 3.11 S8 - the web UI

- Kind `simple_coding`, then the language check. Batch 6: after S6, S7,
  S11 and S12b. R7 agy (waiver while out). Never mistral.
- Files: batch 6's list. The Settings section (spec 6.2) and the
  "Scheduled tasks" item in the channel and topic right-click menus (spec
  6.2, D21: a channel's item lists that channel's tasks, a topic's that
  topic's; "New task" there fills the scope; the topic item desktop only
  as `topic-loops`, `msg-menu.mjs:155`, unless it fits the phone sheet
  budget of `tests/e2e/phone-card-menu.test.mjs`); D23 (2.4 Q1b): the list is ONE `ScheduledTasksDialog.vue`, the same
  from all four entries, with a "Scheduled tasks" item also in the issue
  and epic menu (`useIssueCtxMenu.ts` `menuItemsFor`, a `top` target for
  an epic) and the issue detail header (`IssueDetailActions.vue`, which
  only emits: every entry opens the dialog through one composable,
  `wui:composables/useScheduledTasksDialog.ts`, in the shape of
  `useAddToNote.ts`, so `pages/issues.vue` is not touched); "New task",
  and the header button, bind `epic:<KEY>` on a level-1 row (epic or
  feature) and `key:<KEY>` otherwise; Settings stays admin-only
  (`csi-spl-wui/tests/unit/tenant-settings.test.mjs:31` unchanged); D24
  (Q1c A): no member entry for unbound tasks, and the editor opened from a
  dialog keeps the scope bound (no "all channels" choice for a member);
  the
  editor in spec 6.3's order with the Advanced cron field and its next
  three times (from the preview route or a client copy of the rule: name
  which in the commit), the agent pick (D11), the four templates of spec 7
  (7.2 with `mention_assignee` on, D22), the history, the Instance section for `t1`
  admins only, the topic and message label chips as the issue chips.
- Language (2.4 N5): every string a key (developer guide 2.7); en plus
  machine drafts in the 18 other locales; `do_spl_lang_review_gct` over
  the new keys; the `Lang-review: gct <run id>` line in the commit body.
- Done and red control: spec 187 S8's cells verbatim (`pnpm run typecheck`;
  `test:unit` with the i18n parity, untranslated and raw-text gates and
  cleancode; the editor's required fields per trigger and action kind; the
  summary sentence per kind, cron included; no Instance section for a
  non-`t1` admin; red: a raw string in the editor fails
  `i18n-no-raw-text`).
- Test column: the new unit tests, the `tests/unit/i18n-*` tests,
  `cleancode.test.mjs`, `unused-exports.test.mjs`, the tests naming
  `tenant-settings-nav`, `issue-detail-buttons.test.mjs` (`:23-29` pins
  the header's four buttons; the new one is added), and the e2e files
  `WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e` (csi-spl-iac)
  selects; the reviewer runs that selection (rulebook 2.7.4).

### 3.12 S9 - e2e

- Kind `tests`. Batch 7: after S8. R7 agy (waiver while out). Never mistral.
- Files: new `csi-spl-wui/tests/e2e/scheduled-tasks.test.mjs` only; the
  mock's answers are S8's (`spool-client-mock.mjs`).
- Done: spec 187 S9's flows on the generated bundle, mock-served
  (`BASE_URL=<bundle> pnpm run test:e2e`), plus the dialog opened from a
  channel and a topic (D21) and from an issue and an epic (D23), each
  listing only its own tasks.
- Red control: skip the template fill, and the template test finds an
  empty editor (RED, then GREEN, in the commit body).

### 3.13 S10 - docs

- Kind `specs_and_docs`. Batch 8: after the rows above. agy, backup
  claude; never mistral (the help copy is under `csi-spl-wui/`). R7
  claude if agy wrote it; agy (or the waiver seat) if claude did.
- Files: spec 187's row status and the 2.4 N2 version fix, its `tasks.md`
  states, a new user help page in `csi-spl-doc/doc/help/` (scheduled
  tasks, the `#scheduled-runs` channel, the templates) and its copy by
  `node src/node/help/sync-help.mjs` (csi-spl-wui).
- Done: `do_check_dist_hygiene`, `do_check_fleet_rules_drift`,
  `node src/node/help/sync-help.mjs --check` rc 0,
  `tests/unit/help-sync.test.mjs`.
- Red control: none automatic (the spec's cell is "—"); the reviewer runs
  `sync-help.mjs --check` with the copy left out and sees rc 1.

## 4. Consensus

| seat | vendor | sha | verdict |
|---|---|---|---|
| c-342 | claude, same-vendor panel, waiver | `36d85b32f` (v0.1) | FAIL (W1-W7) |
| c-342 | claude, same-vendor panel, waiver | `cca84bfdf` (v0.2) | PASS (W1-W7 closed; nit: two agy-out dates in the status line, no block) |
| holder | c-002 (dispatch holder) | `cca84bfdf`, then `0989526af` | GO (first on `cca84bfdf`; replaced by a GO on `0989526af` because the release-note gate refused the old messages: same tree, messages only) |

## 5. Versions

| version | what |
|---|---|
| v0.1 | first plan for the panel, on `5906e1fe2` |
| v0.2 | c-342's FAIL on `36d85b32f`: W1 R7 = agy (claude waiver while out), no grok or mistral reviewer; W2 panel recorded as same-vendor, waiver; W3 owner Q3 (13 rows > 10); W4 S5 to batch 4 with the reply hook and timeout (N4 g); W5 and W6 S3's two seams (N4 f); W7 `PRE_PUSH_TIER=full` on S2 and S12b. Notes: 13 settings pages, S11 after S3, N3 needs an R1 waiver, c-918 landed, drift N7, title 13 rows, Q1/Q2 cite spec lines |
| v1.0 | c-342 PASS on `cca84bfdf` (review line checked rc 0); the holder's GO; landed as `49f244c16` + `0989526af` with release-note trailers added to the two messages (tree unchanged, the holder's second GO); owner Q1-Q3 posted as a form, first readings stand until answered |
| v1.1 | the owner's answers (poll `bb3b76c2`): Q1 own option, a "Scheduled tasks" item in the channel and topic right-click menus (spec v0.4 D21; S7 filters, S8 items, sites row and batch 6 files); Q2 B, `notify`'s `mention_assignee` (spec D22; S1 struct, S3 mention, S7 save check, S8 template); Q3 A, one plan, unchanged. No row, batch or vendor moves |
| v1.2 | review a-475 (agy) FAIL on `31d6b4886`: W1 reading (c) unsound: the member's view of tasks over all channels and `issue` tasks is owner question Q1b, open, spot S8 only (2.4, spec 1.2 / 6.2); W2 `SidebarRowMenu.vue` `:245-277` and the two menu util files in the sites row and batch 6. Notes: N1 `?topic=` by parsed positive leaf (S7); N2 channel refusal in `validateTaskSave`, mentions deduplicated (S3, S7); N3 topic item's phone rule (S8), D21 menus in S9; N4 spec status and sha lines. Readings (a), (b) judged sound |
| v1.3 | owner answer to Q1b (spec v0.6 D23; B of msg `b6acff79` withdrawn by msg `6b1806e4`): one "Scheduled tasks" dialog per topic, channel, issue and epic, Settings admin-only; the issue and epic entry sites (1.3); S2 `key:` / `epic:`, S7 `?issue=` / `?epic=`, S8 the dialog and two entries, S9 four entries; Q1c open (2.4). Header line 4 now names spec v0.6 (a-475's N1: it said v0.4). No row, batch or vendor moves |
| v1.4 | review a-521 (agy) FAIL on `6499cd116`: W1 Q1c gets options A (recommended: unbound scopes admin-only, S7 refuses with 403) and B (a fifth member entry), spot S7, S8, S9, rows built with A; W2 issue search is matched in `api:hub/search.go` `issueEntities` (no issue term in `search_postgres.go`): S2 adds that file and its test, `Key` / `Epic` on `search.Entity` via `treeKind`; S7 depends on S2 (still batch 3). Notes: N1 one composable opens the dialog, the header button binds `epic:` on a level-1 row, `issue-detail-buttons.test.mjs` changes; N2 S2's name; N3 the unit test's full path; N4 a several-channel task lists in each channel's dialog, Q1c (a) = all channels |
| v1.5 | the owner's answer to Q1c (poll `a717edfb`, msg `c5143a2f`): A, spec v0.7 D24: a member's unbound task is refused (S7, `403 not_allowed`), made per epic or per channel instead; S8 has no member entry for unbound tasks. a-521's notes on `6029af37c`: N1 the status line says v1.5 (it said v1.3) and lists the versions with commas; N2 S8's "not queued before the answer" removed (Q1c is answered). No row, batch or vendor moves |
