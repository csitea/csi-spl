# 150 Topic-list controls and discussion priority

Version v1.0 (2026-10-23). This is step 2 of the owner rule for a big change
(HUM-10, quoted in the spec 099 header: "1. The written spec and the run
tests. 2. The proper spec with the panel discussion. 3. The actual
implementation."). v0.1 (SPL-3027, `25e1686d6`) was step 1. A panel
(claude editor, mistral seat) re-checked it against the code and decided the
questions the code could answer. The agy seat was dropped by the dispatch
lease holder (c-002, msg `35e9ac0b`: agy out of quota for ~11 h); agy still
reviews every UI text before it ships, at build row B11 (the language rule). The panel's record, with
each check and vote, is [panel.md](panel.md); the signatures are section 8.

Source: prd t1 topic `/t/0344254d-90fa-4341-989e-ec3675da374d`. Issues:
SPL-3027 (v0.1), SPL-3029 (this v1.0), epic SPL-3028. The owner's go to
build is msg `ab0fae01` (2026-10-23): "start implmentation".

Paths: `wui/` = `csi-spl-wui/src/`, `api/` = `csi-spl-api/src/go/spool-hub-api/`,
`store/` = `api/internal/store/`, `hub/` = `api/internal/hub/`,
`rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `orc/` =
`csi-spl-orc/src/bash/run/`. Every `file:line` below was read on
origin/master `25e1686d6`; its code is that of `7ca2732e9`, which v0.1 cites
(`git diff --stat 7ca2732e9 25e1686d6` -> only this spec).

## 1. The owner's asks, verbatim

| part | msg | 2026-10-21 (UTC) | text |
|---|---|---|---|
| 1 | `0c33bce8` | 12:49:20 | "on the same row as the channel name we should have a small forw with more icons ..." |
| - | `b489f912` | 12:49:26 | a screenshot, no text (g-002, msg `faf76aee`: it shows the three card-clip icons on the channel-name row) |
| 2 | `f2bb53c9` | 12:50:10 | "there should be the filter for new and all topics , there shuld be a sort-by time of last update , sort by amount of msgs sort by  sort by prio" |
| 3 | `465b73d7` | 12:52:16 | "where prio shoud be settable from the small control which will apear on ghe bottom or on the top depending on the pre-pending or appending settings for the user ... it should be a radio box chooser wit hthe values from 1..5" |
| 4 | `2a1c2d12` | 12:52:56 | "and accordingly the orchestrator should be able to queque and give priority to those discussions which priority is closer to 1 than 5" |

Two readings the text alone cannot settle:

- "small forw": read as "a small form" (a compact control). The screenshot
  puts it on the row that already holds the card-clip control.
- Part 2 names four sorts, but the third is blank ("sort by  sort by
  prio"). The lane brief and g-002 (msg `873f7602`) wrote "importance"
  there. Only the owner knows: poll Q2 (section 7).

## 2. What exists on origin/master today

The panel re-read every reference of this section on `25e1686d6`; each
holds (panel.md section 1, one row per claim with its command).

### 2.1 The channel-name row (part 1)

- `wui/components/FeedHeader.vue:16-41` is the middle pane's header on the
  channel, DM and lobby pages (SPL-941). It holds:
  - the presence dot (DM, lobby);
  - the title `<h2>` (line 27);
  - the archived topic's name (lines 31-39);
  - `<CardClipControl />` at the right edge (line 40).
- `wui/components/CardClipControl.vue:9-20` is the only control on that
  row: three icon radios in one `role="radiogroup"` (line 12): titles,
  5 rows, full. Its mode is kept per browser (line 5, `useCardClip`).
- The header is used by `wui/pages/channel/[name].vue:3`,
  `wui/pages/dm/[peer].vue:3` and `wui/pages/lobby.vue:3`.

### 2.2 The topic list, its order and filters (part 2)

- The channel feed is a list of topic cards.
  `wui/components/MessageFeed.vue:21-40` hands `channel.newestFirst` to
  `LiveFeed` (line 23) and `channel.unreadFor` as `unread-for` (line 30).
- `wui/stores/channel.ts:122`: `view = channelView(messages, { search, visible })`.
- `wui/utils/channel-feed.mjs:753-756`: `channelView` keeps the cards that
  start a topic, applies the Omnibox `/search` text, and orders them
  **newest activity first** (`newestActivityFirst`, `wui/utils/feed.mjs:38`).
- `wui/components/LiveFeed.vue:299` then reorders with `useUnreadOrder`
  (`wui/composables/useUnreadOrder.ts:1-18`, SPL-2506), ranking each card by
  `cardNew.unseen` (line 295). Cards with unread go to the edge where new
  posts appear: the top for newest first, the bottom for newest last.
- Two unread counts exist: `cardNew.unseen` (the order, above) and
  `channel.unreadFor` (`wui/stores/channel.ts:725-727`, CLE-77804, the card's
  reply badge).
- The rows come from the hub's topic list. `listMessages`
  (`wui/utils/spool-client.mjs:679-690`) calls `listTopics`, which is
  `GET /v1/view/topics` (`hub/view.go:54`): 20 topics a page, newest
  activity first, with the `before=` cursor for older pages.
- That route is a **stamped view** (`hub/view.go:53-55`,
  `hub/view_stamp.go:15-20`): a repeat read answers 304 from the tenant's
  change stamp, which moves only on a write to a table carrying the
  `change_stamp` trigger (`rdb/0103_tenant_change_stamps.sql:112-149`).
- A reconnecting tab reads it with `since=` (`hub/view_delta.go:13-34`): only
  the topics changed after its cursor, from the change sources in
  `store/view_changes.go`.
- `store/view.go:34-66` `TopicQuery` has **no sort** parameter and **no
  "new" filter**; `store/view.go:69-79` `TopicRow` has **no priority**.
- The list walks `topic_heads` (spec 099, `rdb/0144_topic_heads.sql:62-81`),
  indexed `(tenant_id, last_at DESC, task_id DESC)` (line 78). Only the
  commit-time trigger writes it (spec 099 section 4.1).
- No topic list in the WUI has a filter or a sort control today:
  `git grep -lE "unreadOnly|unread_only|sortBy" origin/master -- csi-spl-wui/src`
  lists only `workspace-docs/WorkspaceGridView.vue` and
  `monitoring/token-burn/AgentBurnTable.vue`.

### 2.3 The prepend / append setting (part 3)

- Settings -> Behaviour -> "Message order", `csi-spl-wui/i18n/locales/en.json:121-126`
  (`newest_first` "Newest at the top", `newest_last` "Newest at the
  bottom"), kept on the account (`humans.message_order`, rdb 0070), read
  through `wui/utils/view-prefs.mjs:10-11` and
  `wui/composables/useViewPrefs.ts:20` (`newestLast`).
- "Omnibox position" (`en.json:127-132`) moves the composer, not the
  messages. The owner's "pre-pending or appending settings" is Message
  order: prepend = newest first.
- The precedent for "top or bottom by that setting": `BornTopics` at
  `wui/components/TopicPane.vue:30` / `:61` and
  `wui/components/LiveTopicPane.vue:30` / `:62`.
- The topic pane header (`wui/components/TopicPane.vue:17-27`) holds the
  close X, the title, the archived badge and the replies' card-clip control
  in a fixed slot (line 25, SPL-2807).

### 2.4 Priority today

- A discussion has no priority: `store/store.go:114` `Message` has none, and
  `grep -l priority rdb/*.sql` lists only the issue migrations (0047, 0054,
  0055, 0181) and the issues sort setting in 0078.
- Issues have one: `store/issues.go:60-66`, 1 the highest, 5 the lowest,
  **default 5** (rdb 0054, 0055, owner 2026-09-26).

### 2.5 Topic writes, their policy and their live frame

- The nearest topic write is the archive:
  `PUT|DELETE /v1/messages/{msg_id}/archive` (`hub/server.go:433-434`). No
  route is under `/v1/topics` today, and every `/v1/view/` route reads
  (`hub/view.go:48-62`).
- Who may archive is the workspace policy "Who can archive topics"
  (`hub/topic_archive.go:147-152`, `mayArchiveByPolicy`, CLE-77819,
  `tenants.topic_archive_policy`, default everyone).
- The archive tells every open view by a live frame `topic_archived`
  (`hub/topic_archive.go:38`) through `fanoutTopic` (line 348).

### 2.6 How the orchestrator orders work today (part 4)

- **The spawn queue.** `store/fleet_ask.go:248-273` `askPositions` numbers
  each role's queued asks by class rank (`askClassRank`, lines 172-191:
  ci 0, a flagged row 1, refactor 2, bug 3, feature 4), then `EnqueuedAt`,
  then `AskID`. `orc/spl-spawn-queue.func.sh:22`: "The order is the hub's
  (class, then time in line)".
- **The placer** may take a lower row to keep the class bands
  (`orc/spl-spawn-place.func.sh:37-41`); ties go refactor, bug, feature,
  then the queue's order.
- **An ask has no link to a discussion uuid.** `FleetAsk.Topic`
  (`store/fleet_ask.go:44`) is a free spool task id
  (`rdb/0097_fleet_asks.sql:46`), in practice `dispatch-<topic8>`. The hub
  writes asks in `hub/box_ask.go:259` (`PutFleetAsk`).
- **The hub already resolves a short topic id**:
  `store/issue_discussions.go:102-104` `TopicsByPrefix(tenant, prefix, limit)`,
  called with limit 2 by `hub/issue_discussions.go:65` so a tie is seen.
- **Unanswered owner posts** reach the dispatcher oldest first:
  `store/fallback_postgres.go:126` `ORDER BY m.received_at, m.msg_id`
  (memory twin `store/fallback_memory.go:129`).

## 3. Design

### 3.1 Part 1: the topic-list control on the channel-name row

- A new lazy component, `wui/components/TopicListControl.vue`, drawn in
  `FeedHeader.vue` just before `<CardClipControl />` (line 40), on the
  channel, DM and lobby pages.
- Two icon buttons; each opens a small popover of native radios in one named
  group, as CardClipControl does (Tab lands on the group, the arrows move,
  Escape closes).
  - **Filter**: New / All.
  - **Sort**: Last update / Messages / slot 3 (poll Q2) / Priority.
- An icon shows a dot when its choice is not the default (All, Last update),
  so a filtered list never looks like a short list.
- It loads lazily (`LazyTopicListControl`) in a fixed-size slot, as
  `TopicPane.vue:25` does, so the shell's initial chunk does not grow
  (spec 027 `ci_initial_gzip_kb`) and the title does not jump.
- **The choice is kept per browser**, like the card-clip control beside it
  (panel D6): no account field, no API, no migration.

### 3.2 Part 2: filters and sorts

- **One pure function**, `topicListView(rows, { filter, sort, unreadOf, countOf, priorityOf, lastOf })`
  in `wui/utils/topic-list-order.mjs`. `channelView` keeps its job (the
  cards and `/search`); `MessageFeed` passes its output through
  `topicListView` before `LiveFeed`.
- **Filter New** keeps the cards with unread messages (panel D5). `unreadOf`
  is the function `useUnreadOrder` ranks by (`cardNew.unseen`,
  `LiveFeed.vue:295`), so a card at the unread edge is always a card New
  keeps.
- **Sorts**, all descending; ties go by last update, then `task_id`, so the
  order is stable.
  - Last update: `last_ts` (today's order).
  - Messages: the topic's total count (`channel.repliesFor`, the hub's
    `count`).
  - Priority: 1 first, 5 last; a topic nobody set is 5 (panel D7).
  - Slot 3: per poll Q2; dropped if Q2 is A.
- **Unread stays at the edge after any sort** (panel D9): owner rule
  SPL-2506, "every listing puts the items with unread at the edge"
  (`useUnreadOrder.ts:2-5`). The chosen sort orders the unread group and the
  read group each.
- **Scope: the loaded pages** (panel D1). The feed holds the newest pages
  (20 topics each, more on scroll). A sort or the New filter covers what is
  loaded. When an older page exists, a line under the control says "Sorted:
  the N topics loaded"; under New it says "Showing new among the N topics
  loaded". No API change for part 2.

### 3.3 Part 3: a priority per discussion

**Data** (panel D2).

- Migration `rdb/0214_topic_priorities.sql` (next free on `25e1686d6`, last
  is `0213_box_locks.sql`; check again at build): table `topic_priorities`,
  one row per topic someone set: `tenant_id`, `task_id`, `priority`
  (`CHECK (priority BETWEEN 1 AND 5)`), `set_by`, `set_at`; primary key
  `(tenant_id, task_id)`.
- No row = priority 5 (panel D7). There is no "clear": setting 5 is the
  default. So every change is an upsert and leaves a `set_at`.
- RLS and roles as for `topic_heads` (spec 099 section 3.4).
- **The `change_stamp` trigger** (`rdb/0103:112-149`) goes on the table, so
  a set moves the tenant stamp and a stamped repeat read does not answer 304
  with the old order (panel F1).
- Not a column on `topic_heads` (only the head trigger writes it, spec 099
  4.1) and not on `messages` (a topic's priority is not one message's).

**Store.**

- `store/topic_priority.go` (interface, validation 1..5),
  `store/topic_priority_postgres.go`, `store/topic_priority_memory.go`.
- `SetTopicPriority(tenant, taskID, prio, by, at)` and
  `TopicPriorities(tenant, taskIDs) map[string]int` (absent = 5). The list
  reads priorities only for the topics on the page (`task_id = ANY($ids)` on
  the primary key), as spec 099 5.2 runs `summary()` for the page only.
- `store/change_stamp_test.go:21-25` `stampTables` gains `topic_priorities`;
  its `TestChangeStampTriggerCatalogue` (line 43) fails when the trigger and
  the list part.
- `store/view_changes.go` and `view_changes_postgres.go` gain a change kind:
  a `set_at` after the cursor lists the topic in a `since=` delta (panel F2).

**API** (panel D10).

- `PUT /v1/topics/{task_id}/priority`, body `{"priority": 1..5}`. 200
  answers `{task_id, priority, set_by, set_at}`. 400 outside 1..5.
- The read door first: a caller who cannot read the topic gets 404, as on
  `GET /v1/view/topics/{task_id}`.
- Then the workspace policy "Who can archive topics"
  (`mayArchiveByPolicy`, `hub/topic_archive.go:147-152`) decides who may
  set it: 403 `not_allowed` otherwise (panel D8). No new setting.
- The rows of `GET /v1/view/topics` and `GET /v1/view/topics/{task_id}`
  carry `priority` (1..5; 5 when nobody set it).
- A live frame `topic_priority` (task id, priority), sent through
  `fanoutTopic` (`hub/topic_archive.go:348`) as `topic_archived` is, updates
  every open view of the topic and the list without a refetch.
- `hub/openapi.json` documents the route and the field (spec 104).

**WUI.**

- `wui/components/TopicPriorityChooser.vue`: one row, a native radio group
  1..5, the current value checked. A click saves at once; a failed save puts
  the old value back and says why (`topic.priority.failed`).
- In `TopicPane.vue` and `LiveTopicPane.vue`, where `BornTopics` is
  (`TopicPane.vue:30/61`, `LiveTopicPane.vue:30/62`): at the top of the pane
  body when Message order is newest first, at the bottom when newest last,
  on phones too.
- `wui/utils/spool-client.mjs` gets `setTopicPriority(taskId, prio)`;
  `wui/utils/spool-client-mock.mjs` its mock.
- **The topic card shows a small badge** `P1`..`P4` when a priority other
  than the default 5 is set (panel D11), so a list sorted by priority shows
  why. `wui/components/MessageCard.vue`.

### 3.4 Part 4: the orchestrator serves priority 1 first

1. **The spawn queue.**
   - Migration `rdb/0215_fleet_ask_discussion.sql`: column `discussion`
     (uuid, NULL) on `fleet_asks`, the owner topic the ask works for
     (panel D3).
   - The hub sets it when it writes the ask (`hub/box_ask.go:259`):
     `ASK_DISCUSSION=<uuid>` when the caller sends one; else a `topic` of
     the form `dispatch-<topic8>` is resolved with
     `TopicsByPrefix(tenant, topic8, 2)`: one match sets it, none or two
     leave it NULL, never guessed (panel F3).
   - `askPositions` reads each queued ask's discussion priority (absent =
     5). Where it goes against the class rank: **poll Q5**.
   - Every ask nobody gave a priority ranks at 5, so today's order holds for
     every row until someone sets one.
2. **The unanswered owner posts.** `UnansweredPosts`
   (`store/fallback_postgres.go:111-126`, memory `fallback_memory.go:129`)
   orders by the priority of the post's topic, then `received_at`. The
   dispatcher and the sweep take a priority 1 post first; the escalation
   timing does not change.
3. **The queue table and the placer.** `do_spl_spawn_queue` prints a `PRIO`
   column. The placer's band rule (`orc/spl-spawn-place.func.sh:37-41`) is
   unchanged except that "the queue's order" now includes priority. Its one
   home stays `csi-spl-doc/doc/md/fleet-rules-index.md`, updated in the
   same commit.
4. **An issue keeps its own priority** (panel D4): the queue reads the
   discussion's through `fleet_asks.discussion`; nothing copies it.

### 3.5 i18n

- New keys in `csi-spl-wui/i18n/locales/en.json` and the same keys in the
  other 18 locale files (19: bg el en es et fi he lt lv mk nl pl ro ru sk sr
  sv tr uk). `i18n-parity.test.mjs` refuses a missing key; the raw-text
  ratchet refuses a literal (developer guide 2.4).

| key | en |
|---|---|
| `feed.topic_list.label` | Topic list |
| `feed.topic_list.filter` | Filter |
| `feed.topic_list.filter_new` | New |
| `feed.topic_list.filter_all` | All |
| `feed.topic_list.sort` | Sort by |
| `feed.topic_list.sort_last` | Last update |
| `feed.topic_list.sort_count` | Number of messages |
| `feed.topic_list.sort_slot3` | (per poll Q2; no key if Q2 is A) |
| `feed.topic_list.sort_prio` | Priority |
| `feed.topic_list.window` | Sorted: the {n} topics loaded |
| `feed.topic_list.window_new` | Showing new among the {n} topics loaded |
| `feed.topic_list.empty_new` | No new topics. |
| `topic.priority.label` | Priority |
| `topic.priority.hint` | 1 is the most urgent, 5 the least. The orchestrator serves 1 first. |
| `topic.priority.badge` | P{n} |
| `topic.priority.saved` | Priority set to {n}. |
| `topic.priority.failed` | Could not save the priority ({token}). |

agy reviews all 19 locales as the LAST step before the text ships (the
language rule, global CLAUDE.md "Spawn an agent"): build row B11.

## 4. Case table

- Each case has a red control: a change to the code under test that must
  turn the case red, so no case passes without testing anything.
- Nothing is built yet, so every case is **planned, not run**. On
  `25e1686d6` each case is red because its code or test file does not
  exist, except the guards C104, C202, C203 and C402, which hold today's
  behaviour and are green by design; their red control is the planted
  change in the table.
- The "test" column names the file the build row writes.

| id | part | case | expected | red control | test (planned) |
|---|---|---|---|---|---|
| C101 | 1 | channel page header | `topic-list-control` is in `feed-header`, before `card-clip-control` | remove the component from FeedHeader | `csi-spl-wui/tests/e2e/topic-list-control.test.mjs` |
| C102 | 1 | DM and lobby headers | the same control on both | mount it on the channel page only | same |
| C103 | 1 | keyboard | Tab lands on the filter group, the arrows move, Escape closes | drop `role="radiogroup"` | same |
| C104 | 1 | initial chunk | `ci_initial_gzip_kb` stays within its budget | a static import of the control in FeedHeader | `cd csi-spl-orc && ./run -a do_spl_perf_budget` (spec 027 `perf-budgets.json`) |
| C201 | 2 | filter New | only cards with `unreadOf` > 0 | the test always returns true | `csi-spl-wui/tests/unit/topic-list-order.test.mjs` |
| C202 | 2 | filter All | every card, in today's order | the New test applied under All | same |
| C203 | 2 | sort Last update | the same as `channelView` today | sort by first_ts | same |
| C204 | 2 | sort Messages | higher count first, ties by last update | ascending sort | same |
| C205 | 2 | sort Priority | 1 before 5; a topic with no priority sorts as 5 | no priority sorts first | same |
| C206 | 2 | stable ties | equal keys keep last-update order, then task_id | drop the tie-break | same |
| C207 | 2 | the loaded-topics line | shows under a sort and under New only when an older page exists | always shown | e2e as C101 |
| C208 | 2 | unread edge with a sort | unread cards stay at the edge; each group in the chosen sort | apply the sort after the unread move | unit as C201 |
| C209 | 2 | the choice survives a reload | same filter and sort after a reload in the same browser | not stored | e2e as C101 |
| C210 | 2 | New and the unread edge agree | every card `useUnreadOrder` puts at the edge is kept by New | pass `channel.unreadFor` as `unreadOf` | unit as C201 |
| C301 | 3 | store set / read | `SetTopicPriority` 3, then read 3; an unset topic reads 5 | skip the write | `store/topic_priority_test.go` (Postgres + memory) |
| C302 | 3 | bounds | 0 and 6 refused, 1 and 5 accepted | widen the CHECK | same |
| C303 | 3 | change stamp | a set moves the tenant stamp; `TestChangeStampTriggerCatalogue` lists the table | drop the trigger | `store/change_stamp_test.go` |
| C304 | 3 | tenant isolation (RLS) | tenant B reads none of tenant A's rows | drop the RLS policy | `store/topic_priority_test.go`, as spec 099 7.4 |
| C305 | 3 | read door | a reader outside the channel gets 404 on PUT | skip the door check | `hub/topic_priority_test.go` |
| C306 | 3 | policy | with "Who can archive topics" = admins, a member gets 403 | skip `mayArchiveByPolicy` | same |
| C307 | 3 | list rows carry it | a `GET /v1/view/topics` row has `priority` | drop the join | same |
| C308 | 3 | delta | a set after the cursor lists the topic in a `since=` answer | no change kind | `hub/view_delta_test.go` (the delta has no test file of its own in `store/`) |
| C309 | 3 | live frame | a second client sees the new value without a refetch | no frame | `csi-spl-wui/tests/e2e/topic-priority.test.mjs` |
| C310 | 3 | top / bottom | the chooser is above the root when newest first, below the last reply when newest last | always on top | same |
| C311 | 3 | failed save | the old value comes back and the error line shows | keep the clicked value | same |
| C312 | 3 | card badge | `P2` on a card set to 2; no badge at 5 | badge at 5 too | `csi-spl-wui/tests/e2e/topic-priority-badge.test.mjs` |
| C313 | 3 | i18n parity + raw text | all 19 locales hold every new key; the raw-text count does not rise | a literal "Priority" in the template | `csi-spl-wui/tests/unit/i18n-parity.test.mjs`, `i18n-no-raw-text.test.mjs` |
| C401 | 4 | queue order | of two queued asks in one class, the priority 1 ask is position 1 even when queued later | the rank ignores priority | `store/fleet_ask_queue_test.go` |
| C402 | 4 | no priority = today | asks with no discussion keep the class, EnqueuedAt order | the default ranks first | same |
| C403 | 4 | class vs priority | per poll Q5 | the other Q5 answer | same |
| C404 | 4 | discussion resolve | `dispatch-<topic8>` with one match sets `discussion`; two matches leave it NULL | take the first match | `hub/box_ask_test.go` |
| C405 | 4 | queue table | the `PRIO` column shows 1..5 | the column dropped | `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` |
| C406 | 4 | unanswered posts | a priority 1 post comes before an older priority 5 post | ORDER BY received_at only | `store/unanswered_test.go`, `csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh` |

## 5. Build rows

Parts 1-3 first (API, then WUI), part 4 last. Each row is one small task,
no two rows share a file, and a row lands green (served on dev and prd)
before a row that depends on it starts.

| row | part | task | files (only these) | depends on |
|---|---|---|---|---|
| B1 (Implemented, a63179997) | 3 | `topic_priorities` table with RLS and the change_stamp trigger, the store; C301-C304 | `rdb/0214_topic_priorities.sql`, `store/topic_priority.go`, `store/topic_priority_postgres.go`, `store/topic_priority_memory.go`, `store/topic_priority_test.go`, `store/change_stamp_test.go` | - |
| B2 | 3 | the delta change kind; C308 | `store/view_changes.go`, `store/view_changes_postgres.go`, `hub/view_delta_test.go` | B1 |
| B3 | 3 | `PUT /v1/topics/{task_id}/priority` (door, policy), `priority` on the view rows, the `topic_priority` frame, openapi; C305-C307 | `hub/topic_priority.go`, `hub/topic_priority_test.go`, `hub/view.go` (the row field only), `hub/openapi.json` | B1 |
| B4 | 2-3 | the i18n keys of 3.5 in all 19 locales, one commit | `csi-spl-wui/i18n/locales/*.json` | Q2 answered |
| B5 (Implemented, d7e5d1ae8) | 2 | the `topicListView` pure function; C201-C206, C208, C210 | `wui/utils/topic-list-order.mjs`, `wui/types/mjs-shims.d.ts` (its declaration), `csi-spl-wui/tests/unit/topic-list-order.test.mjs` | Q2 answered |
| B6 | 1-2 | `TopicListControl` in FeedHeader, the MessageFeed wiring, the per-browser choice; C101-C104, C207, C209 | `wui/components/TopicListControl.vue`, `wui/components/FeedHeader.vue`, `wui/components/MessageFeed.vue`, `wui/composables/useTopicListChoice.ts`, `csi-spl-wui/tests/e2e/topic-list-control.test.mjs` | B4, B5 |
| B7 | 3 | `TopicPriorityChooser` in both topic panes, the client call and the mock; C309-C311 | `wui/components/TopicPriorityChooser.vue`, `wui/components/TopicPane.vue`, `wui/components/LiveTopicPane.vue`, `wui/utils/spool-client.mjs`, `wui/utils/spool-client-mock.mjs`, `csi-spl-wui/tests/e2e/topic-priority.test.mjs` | B3, B4 |
| B8 | 3 | the card badge; C312 | `wui/components/MessageCard.vue`, `csi-spl-wui/tests/e2e/topic-priority-badge.test.mjs` | B3, B4 |
| B9 | 4 | `fleet_asks.discussion`, the hub resolve, priority in `askPositions`; C401-C404 | `rdb/0215_fleet_ask_discussion.sql`, `store/fleet_ask.go` (it also holds the memory store), `store/fleet_ask_postgres.go`, `store/fleet_ask_queue_test.go`, `hub/box_ask.go`, `hub/box_ask_test.go` | B1, Q5 answered |
| B10 | 4 | ask-put and enqueue pass `ASK_DISCUSSION`, the `PRIO` column, the rules-index row; C405 | `orc/spl-spawn-enqueue.func.sh`, `orc/spl-ask-put.func.sh`, `orc/spl-spawn-queue.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`, `csi-spl-doc/doc/md/fleet-rules-index.md` | B9 |
| B11 | 2-3 | agy's language review of the 19 locales, the last step before the text ships | `csi-spl-wui/i18n/locales/*.json` (after B4, B6, B7 and B8 have landed) | B6, B7, B8 |
| B12 (Implemented, store half) | 4 | unanswered posts by priority; C406 | `store/fallback_postgres.go`, `store/fallback_memory.go`, `store/unanswered_test.go`, `csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh` | B1 |

- Every row runs the module gate of the repo CLAUDE.md before its push.
- B1, B2, B9 and B12 touch the store or a migration: `PRE_PUSH_TIER=full`.
- B12 landed the store half: `UnansweredPosts` (Postgres and memory) orders
  by the topic's priority, then `received_at`, so the hub's escalation
  (`hub/relay.go` `escalateUnanswered`) takes a priority 1 post first; C406 is
  `TestUnansweredPostsByTopicPriority` in `store/unanswered_test.go`. The
  sweep half is not built: `do_spl_unanswered_sweep` reads its own SQL
  (`orc/spl-unanswered-sweep.func.sh`) and sorts in
  `csi-spl-orc/src/bash/scripts/unanswered-sweep-classify.py`, neither in
  B12's file list, and its row format is read by 7 orc tests and the delta
  and measure actions. It needs its own row (the `PRIO` column, the delta on
  `topic_priorities.set_at`, the classifier sort, C406 in
  `unanswered-sweep-pg.tst.sh`).
- B3 and B9 ship the hub (run 20); B6, B7, B8 and B11 ship the WUI (run
  30). A row is done when it is served on dev and prd.
- B4 and B11 both edit the locale files, never at the same time: B11 starts
  only after B4, B6, B7 and B8 have landed.
- B6, B7 and B8 run the WUI e2e on the generated bundle (repo CLAUDE.md),
  not only `pnpm run typecheck`.

## 6. Panel decisions

The questions of v0.1 section 6 (P1-P4) and the section 7 polls the panel
could settle on evidence. Each seat's vote and any dissent, with its msg id,
is in panel.md section 3.

| id | question | decision | reason (evidence on `25e1686d6`) |
|---|---|---|---|
| D1 (P1) | server sort or client sort | client sort and filter over the loaded pages for v1, with the "N topics loaded" line; no `sort=` on the API now | `topic_heads` has one index, `(tenant_id, last_at DESC, task_id DESC)` (`rdb/0144:78`); a sort by count or priority would read every topic of the channel, the walk spec 099 removed. A server sort is a later spec that starts with a measurement |
| D2 (P2) | where priority is stored | own table `topic_priorities` (0214), read for the page's task ids only | only the head trigger writes `topic_heads` (spec 099 4.1); a page read on the primary key costs one index probe per page |
| D3 (P3) | how an ask links its discussion | explicit `fleet_asks.discussion` (0215), set by the hub at write | a read-time prefix lookup would run per queued row on every queue read; `TopicsByPrefix` (`store/issue_discussions.go:102-104`) already does the one lookup at write |
| D4 (P4) | issue priority vs discussion priority | separate; nothing copies | two copies of one value drift; the queue reads the discussion's through D3 |
| D5 (Q1) | what "new" means in the filter | a topic with unread messages | the WUI's existing "new" is unread: `cardNew.unseen` / `openerNew` (`LiveFeed.vue:91-92, 295`) |
| D6 (Q6) | where the filter / sort choice is kept | per browser | the card-clip control beside it is kept per browser (`CardClipControl.vue:5`); no API, no migration |
| D7 (Q3) | a discussion nobody set | priority 5, as an issue; no "None", no clear | issues default to 5 (`store/issues.go:63-65`, owner 2026-09-26); every existing row keeps today's order |
| D8 (Q4) | who may set it | the read door, then the workspace's "Who can archive topics" policy | one existing policy for topic changes (`hub/topic_archive.go:147-152`, CLE-77819); no new setting |
| D9 (Q7) | unread at the edge after a sort | yes | owner rule SPL-2506: "every listing puts the items with unread at the edge" (`useUnreadOrder.ts:2-5`) |
| D10 (F5) | where the write route lives | `PUT /v1/topics/{task_id}/priority` | every `/v1/view/` route reads (`hub/view.go:48-62`) |
| D11 (Q8) | does the card show the priority | a small badge when not 5 | a list sorted by priority with no visible value cannot be read |
| D12 (Q2) | the third sort | none: three sorts (last update, messages, priority) | the owner, poll `b4e82851` msg `f6350266`: "Answer: A — There is no third sort: three sorts are enough"; then msg `603d2f64`: "can you proceed now" |

## 7. Questions for the owner

Only what the code cannot answer. Each poll holds one question; the dispatch
holder puts them to the owner, one form per post
(`csi-spl-doc/doc/help/how-to-post.md` section 7). Section 5 shows which
rows wait on each: Q2 holds B4 and B5 (and so B6, B7, B8); Q5 holds B9.

```poll
Q2. Your sort list reads "sort by time of last update, sort by amount of msgs, sort by ___, sort by prio". What is the third sort?
(A) There is no third sort: three sorts are enough
(B) Importance: topics that mention me or that I take part in first
(C) Kind: blockers and escalations first
```

```poll
Q5. In the orchestrator's queue, how does a discussion's priority combine with the work class (CI, refactor, bug, feature)?
(A) Priority first: a priority 1 feature goes before a priority 3 bug
(B) Class first: priority orders the rows inside each class
(C) CI-red first, then priority, then class
```

## 8. Signatures

v1.0 is signed when each seat has signed it by its own spool message.
The mistral seat signed this text as the local blob `3c3fab2b` (msg
`00f3e913`), before this section was written; it signs the landed commit
again by its own message, recorded in panel.md section 4.

| seat | vendor | agent | signed (msg id) |
|---|---|---|---|
| editor | claude | c-875 | the v1.0 commit |
| seat | mistral | m-876 | blob `3c3fab2b`: `00f3e913`; the landed sha: panel.md section 4 |
| seat | agy | - | dropped (c-002 msg `35e9ac0b`); agy reviews the UI text at B11 |
