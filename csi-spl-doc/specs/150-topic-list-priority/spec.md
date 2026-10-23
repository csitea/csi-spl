# 150 Topic-list controls and discussion priority

Version v0.1 (2026-10-23). This is step 1 of the owner rule for a big change
(HUM-10, quoted in the spec 099 header: "1. The written spec and the run
tests. 2. The proper spec with the panel discussion. 3. The actual
implementation."): the asks, what exists, the design, the case table and the
build rows. Step 2 (the panel) writes its opinion files into this folder and
v1.0.

Source: prd t1 topic `/t/0344254d-90fa-4341-989e-ec3675da374d`. Issue:
SPL-3027 (this spec), epic SPL-2454. The owner's go to build is msg
`ab0fae01` (2026-10-23): "start implmentation".

Paths: `wui/` = `csi-spl-wui/src/`, `api/` = `csi-spl-api/src/go/spool-hub-api/`,
`store/` = `api/internal/store/`, `hub/` = `api/internal/hub/`,
`rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `orc/` =
`csi-spl-orc/src/bash/run/`. Every `file:line` below was read on
origin/master `7ca2732e9`.

## 1. The owner's asks, verbatim

| part | msg | 2026-10-21 (UTC) | text |
|---|---|---|---|
| 1 | `0c33bce8` | 12:49:20 | "on the same row as the channel name we should have a small forw with more icons ..." |
| - | `b489f912` | 12:49:26 | a screenshot, no text (g-002, msg `faf76aee`: it shows the three card-clip icons on the channel-name row) |
| 2 | `f2bb53c9` | 12:50:10 | "there should be the filter for new and all topics , there shuld be a sort-by time of last update , sort by amount of msgs sort by  sort by prio" |
| 3 | `465b73d7` | 12:52:16 | "where prio shoud be settable from the small control which will apear on ghe bottom or on the top depending on the pre-pending or appending settings for the user ... it should be a radio box chooser wit hthe values from 1..5" |
| 4 | `2a1c2d12` | 12:52:56 | "and accordingly the orchestrator should be able to queque and give priority to those discussions which priority is closer to 1 than 5" |

This spec cannot settle two readings on its own:

- "small forw": read here as "a small form" (a compact control). The
  screenshot puts it on the row that already holds the card-clip control.
- Part 2 names four sorts, but the third is blank ("sort by  sort by
  prio"). The lane brief and g-002 (msg `873f7602`) wrote "importance"
  there. This spec keeps the slot and asks the owner what goes in it
  (poll Q2).

## 2. What exists on origin/master today

### 2.1 The channel-name row (part 1)

- `wui/components/FeedHeader.vue:16-41` is the middle pane's header on the
  channel, DM and lobby pages (SPL-941). It holds:
  - the presence dot (DM, lobby);
  - the title `<h2>` (line 27);
  - the archived topic's name (lines 31-39);
  - `<CardClipControl />` at the right edge (line 40).
- `wui/components/CardClipControl.vue:9-20` is the only control on that
  row: three icon radios in one `role="radiogroup"` (titles, 5 rows,
  full). These are the three card-clip icons in the screenshot.
- The header is used by `wui/pages/channel/[name].vue:3`,
  `wui/pages/dm/[peer].vue:3` and `wui/pages/lobby.vue:3`.

### 2.2 The topic list, its order and filters (part 2)

- The channel feed is a list of topic cards.
  `wui/components/MessageFeed.vue:21-40` hands `channel.newestFirst` to
  `LiveFeed`.
- `wui/stores/channel.ts:122-123`: `view = channelView(messages, { search, visible })`.
- `wui/utils/channel-feed.mjs:739-756`: `channelView` keeps the cards that
  start a topic, applies the Omnibox `/search` text, and orders them
  **newest activity first** (`newestActivityFirst`, `wui/utils/feed.mjs:38`).
  A reply moves its topic's card up.
- `wui/components/LiveFeed.vue:299` then reorders with
  `useUnreadOrder` (`wui/composables/useUnreadOrder.ts:1-18`, SPL-2506).
  Cards with unread messages go to the edge where new posts appear: the top
  for newest first, the bottom for newest last.
- The rows come from the hub's topic list. `listMessages`
  (`wui/utils/spool-client.mjs:679-689`) calls `listTopics`, which is
  `GET /v1/view/topics` (`hub/view.go:54`): 20 topics a page, newest
  activity first, with the `before=` cursor for older pages.
- `store/view.go:34-66` `TopicQuery` filters by channel, agent, DM, roots,
  parent, viewer, NoIssues and the read door. It has **no sort** parameter
  and **no "new" filter**.
- `store/view.go:69-79` `TopicRow` carries `FirstAt`, `LastAt`, `Count`,
  kinds and parties. It has **no priority**.
- The list walks `topic_heads` (spec 099, `rdb/0144_topic_heads.sql:62-81`),
  keyed `(tenant_id, last_at DESC, task_id DESC)`.
  - The head row stores no message count and no priority.
  - Only the commit-time trigger writes it (spec 099 section 4.1), so
    nothing else may write it.
- No topic list in the WUI has a filter or a sort control today:
  `git grep -lE "unreadOnly|unread_only|sortBy" origin/master -- csi-spl-wui/src`
  lists only `workspace-docs/WorkspaceGridView.vue` and
  `monitoring/token-burn/AgentBurnTable.vue`.

### 2.3 The prepend / append setting (part 3)

- Settings -> Behaviour -> "Message order" is in
  `csi-spl-wui/i18n/locales/en.json:121-126` (`newest_first` "Newest at the
  top", `newest_last` "Newest at the bottom").
  - It is stored per person on the account, `humans.message_order`
    (rdb 0070).
  - The WUI reads it through `wui/utils/view-prefs.mjs:10-11` and
    `wui/composables/useViewPrefs.ts:18-20` (`newestLast`).
- A second setting, "Omnibox position" (`en.json:127-132`,
  `composer_position` top / bottom), moves the composer, not the messages.
  This spec reads the owner's "pre-pending or appending settings" as
  Message order, where prepend means newest first (section 3.3).
- There is a precedent for "top or bottom by that setting". `BornTopics` is
  drawn at the top when newest first and at the bottom when newest last:
  - `wui/components/TopicPane.vue:30` and `:61`;
  - `wui/components/LiveTopicPane.vue:30` and `:62`.
- The topic pane header (`wui/components/TopicPane.vue:17-27`) holds the
  close X, the title, the archived badge and the replies' card-clip control.

### 2.4 Priority today

- A discussion has no priority.
  - `store/store.go:114` `Message` has no priority field.
  - No rdb migration adds one to `messages`, `topic_heads` or any topic
    table. `grep -l priority rdb/*.sql` lists the issue migrations (0047,
    0054, 0055, 0181) and the issues sort setting in 0078, nothing else.
- Issues have a priority: `store/issues.go:60-66`, 1 the highest, 5 the
  lowest, default 5 (rdb 0054, 0055). An issue's priority is not its
  discussion's.

### 2.5 How the orchestrator orders work today (part 4)

- **The spawn queue** holds the lanes waiting for a box.
  - `store/fleet_ask.go:248-272` `askPositions` numbers each role's queued
    asks by class rank, then `EnqueuedAt`, then `AskID`.
  - The class rank is in `store/fleet_ask.go:172-191`: ci 0, a flagged row
    (urgent bug, owner bypass) 1, refactor 2, bug 3, feature 4.
  - `orc/spl-spawn-queue.func.sh:22`: "The order is the hub's (class, then
    time in line)".
- **The placer** may take a lower row to keep the class bands
  (`orc/spl-spawn-place.func.sh:36-41`). It takes a ci or flagged head as it
  is. Otherwise it takes the class furthest under its band; ties go refactor,
  then bug, then feature, then the queue's order.
- **An ask has no link to a discussion uuid.** `FleetAsk.Topic`
  (`store/fleet_ask.go:44`) is a free spool task id:
  `rdb/0097_fleet_asks.sql:46` checks `topic ~ '^([A-Za-z0-9_-]{1,64})?$'`.
  In practice it is `dispatch-<topic8>`.
- **Unanswered owner posts** reach the dispatcher oldest first:
  `store/fallback_postgres.go:126` `ORDER BY m.received_at, m.msg_id`.

## 3. Design

### 3.1 Part 1: the topic-list control on the channel-name row

- A new lazy component, `wui/components/TopicListControl.vue`, drawn in
  `FeedHeader.vue` just before `<CardClipControl />` (line 40), on the
  channel, DM and lobby pages.
- It has two icon buttons. Each opens a small popover of native radios in
  one named group, as CardClipControl does: Tab lands on the group and the
  arrow keys move.
  - **Filter** icon: New / All (part 2).
  - **Sort** icon: Last update / Messages / slot 3 (poll Q2) / Priority.
- An icon shows a dot when its choice is not the default (All, Last update),
  so a filtered list never looks like a short list.
- It loads lazily (`LazyTopicListControl`), so the shell's initial chunk
  does not grow (spec 027 `ci_initial_gzip_kb`). It sits in a fixed-size
  slot, as `TopicPane.vue:25` does for SPL-2807, so the title does not jump
  when it mounts.
- Where the choice is kept: poll Q6.

### 3.2 Part 2: filters and sorts

- **One pure function**, `topicListView(rows, { filter, sort, unreadOf, countOf, priorityOf, lastOf })`
  in `wui/utils/topic-list-order.mjs`.
  - `channelView` keeps its job: the topic cards and `/search`.
  - `MessageFeed` passes `channelView`'s output through `topicListView`
    before handing it to `LiveFeed`.
- **Filter New** keeps the cards whose `unreadOf` is above 0. It is the
  same count the card's unread badge and `useUnreadOrder` use. The meaning
  of "new" is poll Q1. The function takes the test as a parameter, so a
  different answer changes one line.
- **Sorts**: all descending. Ties go by last update, then by `task_id`, so
  the order is stable.
  - Last update: `last_ts` (today's order).
  - Messages: the topic's total count (`channel.repliesFor`, the hub's
    `count`).
  - Priority: 1 first, 5 last. A topic with no priority set sorts at the
    default of poll Q3.
  - Slot 3: per poll Q2.
- **Unread first: kept or dropped?** Today `useUnreadOrder` moves unread
  cards to the edge after the order is applied. Poll Q7 decides whether
  that still happens after a chosen sort.
- **Scope: the loaded topics first.**
  - The feed holds the newest pages (20 topics each, more on scroll). A
    client sort by messages or priority sorts what is loaded, not the whole
    channel.
  - v0.1 builds the client sort, with no API change. When an older page
    exists, a line under the control says "Sorted: the N topics loaded".
  - A server sort (`sort=` on `GET /v1/view/topics`) is panel question P1.
    `topic_heads` has no count key and no priority key, so a server sort by
    either would walk every topic of the channel. That walk is the cost
    spec 099 removed.

### 3.3 Part 3: a priority per discussion

**Data.**

- A new table, in migration `rdb/0214_topic_priorities.sql` (the next free
  number on `7ca2732e9`; check it again at build time).
- One row per topic that has a priority: tenant, task id, priority 1..5,
  who set it, when. A topic with no row has no priority set.
- RLS and roles as for `topic_heads` (spec 099 section 3.4).
- It is NOT a column on `topic_heads`, because only the head trigger writes
  that table (spec 099 4.1). It is NOT a column on `messages` either: a
  topic's priority is not one message's.

**Store.**

- New files: `store/topic_priority.go` (the interface and its validation:
  1..5, or clear), `store/topic_priority_postgres.go` and
  `store/topic_priority_memory.go`.
- Methods: `SetTopicPriority(tenant, taskID, prio, by, at)`,
  `ClearTopicPriority`, and `TopicPriorities(tenant, taskIDs) map[string]int`.
- The list reads priorities only for the topics on the page, the way
  spec 099 5.2 runs `summary()` for the page only.

**API.**

- `PUT /v1/view/topics/{task_id}/priority`, body `{"priority": 1..5}`, sets
  it. `DELETE` on the same path clears it.
  - 200 answers `{task_id, priority, set_by, set_at}`.
  - A reader the read door refuses gets 404, as on
    `GET /v1/view/topics/{task_id}`.
  - Who may set it: poll Q4.
- The rows of `GET /v1/view/topics` and `GET /v1/view/topics/{task_id}`
  carry `priority` (absent = not set).
- A live frame, `topic.priority` (task id and priority), updates every open
  view of the topic, and the list, without a refetch.
- `hub/openapi.json` documents both routes (spec 104).

**WUI.**

- `wui/components/TopicPriorityChooser.vue`: one row with a native radio
  group 1..5, plus "None" if poll Q3 picks C. The current value is checked.
  A click saves at once. A failed save puts the old value back and says
  why.
- It goes in `TopicPane.vue` and `LiveTopicPane.vue`, in the same place as
  `BornTopics` (`TopicPane.vue:30/61`, `LiveTopicPane.vue:30/62`):
  - at the top of the pane body when Message order is newest first;
  - at the bottom when it is newest last;
  - on phones too, by the same setting.
- `wui/utils/spool-client.mjs` gets `setTopicPriority(taskId, prio)` and
  `clearTopicPriority(taskId)`; `wui/utils/spool-client-mock.mjs` gets the
  mock versions.
- Whether the topic card shows the priority: poll Q8.

### 3.4 Part 4: the orchestrator serves priority 1 first

Two places decide what the orchestrator serves next. Both get the
discussion's priority.

1. **The spawn queue.**
   - A new column, `discussion`, on `fleet_asks` (migration
     `rdb/0215_fleet_ask_discussion.sql`) holds the full uuid of the owner
     topic the ask works for.
   - `do_spl_ask_put` and `do_spl_spawn_enqueue` set it from
     `ASK_DISCUSSION=<uuid>`. Without that, they look up a
     `dispatch-<topic8>` topic: exactly one tenant topic with that prefix
     sets the uuid. No match or two matches leave it empty; it is never
     guessed.
   - `askPositions` reads that topic's priority. Where priority goes in the
     order against the class rank: poll Q5.
   - An ask with no discussion, or whose discussion has no priority, ranks
     at the default (poll Q3). So today's order holds for every row nobody
     gave a priority.
2. **The unanswered owner posts.** `UnansweredPosts`
   (`store/fallback_postgres.go:111-126`) orders by the priority of the
   post's topic, then by `received_at`. The dispatcher and the sweep then
   take a priority 1 post first. The sweep's escalation timing does not
   change.
3. **The queue table and the placer.** `do_spl_spawn_queue` prints a `PRIO`
   column. The placer's band rule (`orc/spl-spawn-place.func.sh:36-41`) is
   unchanged, except that "the queue's order" now includes priority. The
   rule's one home stays `csi-spl-doc/doc/md/fleet-rules-index.md`; its row
   is updated in the same commit as the code.

### 3.5 i18n

- New keys go in `csi-spl-wui/i18n/locales/en.json`, and the same keys in
  the other 18 locale files: 19 in all (bg el en es et fi he lt lv mk nl pl
  ro ru sk sr sv tr uk).
- `i18n-parity.test.mjs` refuses a missing key, and the raw-text ratchet
  refuses a literal (developer guide 2.4).

| key | en |
|---|---|
| `feed.topic_list.label` | Topic list |
| `feed.topic_list.filter` | Filter |
| `feed.topic_list.filter_new` | New |
| `feed.topic_list.filter_all` | All |
| `feed.topic_list.sort` | Sort by |
| `feed.topic_list.sort_last` | Last update |
| `feed.topic_list.sort_count` | Number of messages |
| `feed.topic_list.sort_slot3` | (per poll Q2; dropped if Q2 is A) |
| `feed.topic_list.sort_prio` | Priority |
| `feed.topic_list.window` | Sorted: the {n} topics loaded |
| `feed.topic_list.empty_new` | No new topics. |
| `topic.priority.label` | Priority |
| `topic.priority.hint` | 1 is the most urgent, 5 the least. The orchestrator serves 1 first. |
| `topic.priority.none` | None |
| `topic.priority.saved` | Priority set to {n}. |
| `topic.priority.failed` | Could not save the priority ({token}). |

Before the text ships, agy reviews all 19 locales as the LAST step (the
language rule, global CLAUDE.md "Spawn an agent"). That is build row B9.

## 4. Case table

- Each case has a red control: a change to the code under test that must
  turn the case red, so no case can pass without testing anything.
- Spec 099's step-1 table ran against the live code. Nothing here is built
  yet, so every case is **planned, not run**.
- The "test" column names the file the build row writes.

| id | part | case | expected | red control | test (planned) |
|---|---|---|---|---|---|
| C101 | 1 | channel page header | `topic-list-control` is in `feed-header`, before `card-clip-control` | remove the component from FeedHeader | `csi-spl-wui/tests/e2e/topic-list-control.test.mjs` |
| C102 | 1 | DM and lobby headers | the same control on both | mount it on the channel page only | same |
| C103 | 1 | keyboard | Tab lands on the filter group, the arrows move, Escape closes | drop `role="radiogroup"` | same |
| C104 | 1 | initial chunk | `ci_initial_gzip_kb` stays within its budget | a static import of the control in FeedHeader | `cd csi-spl-orc && ./run -a do_spl_perf_budget` (spec 027 `perf-budgets.json`) |
| C201 | 2 | filter New | only cards with unread > 0 | the test always returns true | `csi-spl-wui/tests/unit/topic-list-order.test.mjs` |
| C202 | 2 | filter All | every card, in today's order | the New test applied under All | same |
| C203 | 2 | sort Last update | the same as `channelView` today | sort by first_ts | same |
| C204 | 2 | sort Messages | higher count first, ties by last update | ascending sort | same |
| C205 | 2 | sort Priority | 1 before 5; no priority sorts at the Q3 default | no priority sorts first | same |
| C206 | 2 | stable ties | equal keys keep last-update order, then task_id | drop the tie-break | same |
| C207 | 2 | the loaded-topics line | shows only when an older page exists | always shown | e2e as C101 |
| C208 | 2 | unread edge with a sort | per Q7 | the other Q7 answer | unit as C201 |
| C209 | 2 | the choice survives a reload | per Q6 | not stored | e2e as C101 |
| C301 | 3 | store set / read | `SetTopicPriority` 3, then read 3 | skip the write | `store/topic_priority_test.go` (Postgres + memory) |
| C302 | 3 | bounds | 0 and 6 refused, 1 and 5 accepted | widen the CHECK | same |
| C303 | 3 | clear | after DELETE, no priority | the delete does nothing | same |
| C304 | 3 | tenant isolation (RLS) | tenant B reads none of tenant A's rows | drop the RLS policy | same, as spec 099 7.4 |
| C305 | 3 | read door | a reader outside the channel gets 404 on PUT | skip the door check | `hub/topic_priority_test.go` |
| C306 | 3 | list rows carry it | a `GET /v1/view/topics` row has `priority` | drop the join | same |
| C307 | 3 | live frame | a second client sees the new value without a refetch | no frame | `csi-spl-wui/tests/e2e/topic-priority.test.mjs` |
| C308 | 3 | top / bottom | the chooser is above the root when newest first, below the last reply when newest last | always on top | same |
| C309 | 3 | failed save | the old value comes back and the error line shows | keep the clicked value | same |
| C310 | 3 | i18n parity + raw text | all 19 locales hold every new key; the raw-text count does not rise | a literal "Priority" in the template | `csi-spl-wui/tests/unit/i18n-parity.test.mjs`, `i18n-no-raw-text.test.mjs` |
| C401 | 4 | queue order | of two queued asks in one class, the priority 1 ask is position 1 even when queued later | the rank ignores priority | `store/fleet_ask_queue_test.go` |
| C402 | 4 | no priority = today | asks with no discussion keep the class, EnqueuedAt order | the default ranks first | same |
| C403 | 4 | class vs priority | per Q5 | the other Q5 answer | same |
| C404 | 4 | discussion lookup | `dispatch-<topic8>` with one match sets the uuid; two matches leave it empty | take the first match | `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` |
| C405 | 4 | queue table | the `PRIO` column shows 1..5 or `-` | the column dropped | same |
| C406 | 4 | unanswered posts | a priority 1 post comes before an older priority 5 post | ORDER BY received_at only | `store/unanswered_test.go`, `csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh` |

## 5. Build rows

Parts 1-3 come first (API, then WUI), part 4 last. Each row is one small
task, and no two rows share a file. A row lands green before any row that
depends on it starts.

| row | part | task | files (only these) | depends on |
|---|---|---|---|---|
| B1 | 3 | topic priority table and store; tests C301-C304 | `rdb/0214_topic_priorities.sql`, `store/topic_priority.go`, `store/topic_priority_postgres.go`, `store/topic_priority_memory.go`, `store/topic_priority_test.go` | - |
| B2 | 3 | hub routes PUT / DELETE, `priority` on list and topic rows, the live frame, route docs; tests C305-C306 | `hub/topic_priority.go`, `hub/topic_priority_test.go`, `hub/view.go` (the row field only), `hub/openapi.json` | B1 |
| B3 | 2-3 | the i18n keys of section 3.5 in all 19 locales, in one commit, so no two rows edit a locale file | `csi-spl-wui/i18n/locales/*.json` | Q2 answered |
| B4 | 2 | the `topicListView` pure function; tests C201-C206, C208 | `wui/utils/topic-list-order.mjs`, `wui/types/mjs-shims.d.ts` (its declaration), `csi-spl-wui/tests/unit/topic-list-order.test.mjs` | Q1, Q3, Q7 |
| B5 | 1-2 | `TopicListControl` in FeedHeader, the MessageFeed wiring, the stored choice; tests C101-C104, C207, C209 | `wui/components/TopicListControl.vue`, `wui/components/FeedHeader.vue`, `wui/components/MessageFeed.vue`, `csi-spl-wui/tests/e2e/topic-list-control.test.mjs` (and the file that stores the choice, per Q6) | B3, B4 |
| B6 | 3 | `TopicPriorityChooser` in both topic panes, the client calls and the mock; tests C307-C309 | `wui/components/TopicPriorityChooser.vue`, `wui/components/TopicPane.vue`, `wui/components/LiveTopicPane.vue`, `wui/utils/spool-client.mjs`, `wui/utils/spool-client-mock.mjs`, `csi-spl-wui/tests/e2e/topic-priority.test.mjs` | B2, B3 |
| B7 | 4 | `fleet_asks.discussion` and priority in `askPositions`; tests C401-C403 | `rdb/0215_fleet_ask_discussion.sql`, `store/fleet_ask.go` (it also holds the memory store), `store/fleet_ask_postgres.go`, `store/fleet_ask_queue_test.go` | B1, Q5 |
| B8 | 4 | enqueue and ask-put pass the discussion, the `PRIO` column, the rules-index row; tests C404-C405 | `orc/spl-spawn-enqueue.func.sh`, `orc/spl-ask-put.func.sh`, `orc/spl-spawn-queue.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`, `csi-spl-doc/doc/md/fleet-rules-index.md` | B7 |
| B9 | 2-3 | agy's language review of the 19 locales, the last step before the text ships | `csi-spl-wui/i18n/locales/*.json` (after B3, B5 and B6 have landed) | B5, B6 |
| B10 | 4 | unanswered posts by priority; test C406 | `store/fallback_postgres.go`, `store/fallback_memory.go`, `store/unanswered_test.go`, `csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh` | B1 |

- Every row runs the module gate of the repo CLAUDE.md before its push.
- B1, B7 and B10 touch the store or a migration, so they run
  `PRE_PUSH_TIER=full`.
- B2 and B7 ship the hub (run 20); B5, B6 and B9 ship the WUI (run 30). A
  row is done when it is served on dev and prd.

## 6. Panel questions (step 2, not for the owner)

- **P1** Server sort: is the client sort over the loaded topics (3.2) enough
  for v1? Or does `GET /v1/view/topics` need `sort=count|prio` now, and what
  would its walk cost against spec 099's numbers?
- **P2** Priority storage: a separate `topic_priorities` table (3.3), or a
  stored column the head trigger copies, so that a server sort by priority
  can use an index?
- **P3** `fleet_asks.discussion`: an explicit column (3.4), or a prefix
  lookup of `topic` at read time?
- **P4** Should a lane's issue (SPL-n) take the discussion's priority when
  it is filed, so the issue list and the queue agree?

## 7. Questions for the owner

- Each poll holds one question. The dispatch holder puts them to the owner,
  one form per post (`csi-spl-doc/doc/help/how-to-post.md` section 7).
- Section 5 shows which build rows wait on each question.

```poll
Q1. In the topic filter, what is a "new" topic?
(A) A topic with messages I have not read yet
(B) A topic started since my last visit to the channel
(C) A topic nobody has replied to yet
```

```poll
Q2. Your sort list reads "sort by time of last update, sort by amount of msgs, sort by ___, sort by prio". What is the third sort?
(A) There is no third sort: three sorts are enough
(B) Importance: topics that mention me or that I take part in first
(C) Kind: blockers and escalations first
```

```poll
Q3. A discussion nobody has given a priority yet: which priority does it have?
(A) 3, the middle
(B) 5, the lowest (as issues do)
(C) None: it sorts after 5, and the chooser has a "None" option
```

```poll
Q4. Who may set a discussion's priority?
(A) Any member who can read the discussion
(B) Humans only, not agents
(C) Workspace admins only
```

```poll
Q5. In the orchestrator's queue, how does priority combine with the work class (CI, refactor, bug, feature)?
(A) Priority first: a priority 1 feature goes before a priority 3 bug
(B) Class first: priority orders the rows inside each class
(C) CI-red first, then priority, then class
```

```poll
Q6. Where is your topic filter and sort choice kept?
(A) On your account: every device shows the same
(B) Per channel, on your account
(C) Not kept: each visit starts at All and Last update
```

```poll
Q7. When you pick a sort, do topics with unread messages still move to the edge?
(A) Yes: unread first, then the chosen sort
(B) No: the chosen sort only
```

```poll
Q8. Does the topic card in the list show its priority?
(A) Yes, a small badge when a priority is set
(B) No, only the chooser in the open topic shows it
```
