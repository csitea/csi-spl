# 150 Topic-list controls and discussion priority

Version v1.8 (2026-11-25, SPL-6503): defines the operational meaning of
priorities 1..5 across the spawn queue, placer and running lanes (including
priority-1 preemption of running priority 3..5 lanes; section 3.4.1), drops
the free-text "prio" word rule of spec 157 section 4.1 while keeping the
explicit trailing `prio:N` token of v1.7 (section 3.4.2), adds a
workspace-owner-managed default priority per channel that new topics inherit
without changing existing topics (section 3.3.2), and specifies the v1.8
cases (C410-C419, with C414a/C414b) and build rows (B14-B21, with
B16a-B16c). Owner decisions (HUM-10,
2026-11-25): t1 `#spool-hub-biz` topic `c2838b08` msgs `ee20b1c9`,
`d744269f`, poll `32527755` answer msg `3ed8fd13` (Q1 = A, Q2 = B); topic
`b6c7b21c` msgs `c6438688`, `c4fbafb5`, poll `ab1b0c08` answer msg
`81cbf77e` (unset = 3, workspace owner only). Every v1.8 `file:line`
citation was verified on `origin/master` `7481e6cac`.

v1.7 (2026-11-21): a new topic's first post that ends with
`prio:N` (also `prio:0N`, `prio-N`, `prio-0N`, `prio N`; N 1..5) sets the
topic's priority, and the token is not stored (section 3.3.1; the owner, t1
0f457318 msg `c94e2d29`, SPL-6145). The default stays 3.

v1.6 (2026-11-18): only an owner of the operator workspace orders
the agents' work. An operator issue linking another workspace's topic
follows a set there only when its setter owns the operator workspace, as
the spawn queue does; that workspace's own owner sets its topic and its own
issues, never the operator's (section 3.4 item 4 "Across workspaces"; the
owner, t1 e1139a1e msg `41010d28`, poll `74ef368b` answer A, SPL-5933).

v1.5 (2026-11-12): two-row headers (option A of the mocks, the
owner's pick in poll `ba1b6b6f`, t1 2fafde5c msg `9e4cfb7d`, SPL-5349). The
topic list header shows the full channel name on row 1 and the filter + sort
(left) and card-size control (right) on row 2; the open topic shows the full
title on row 1 and the priority bar (left) and card-size control (right) on
row 2. The card-size control is 30% lower and narrower (cells 26 px wide
on the desktop, was 33; 35 on a phone, was 44), the filter and
sort buttons and the priority bar take its size, the label reads "prio:",
and a saved pick shows a "✓ N" right of the bar that fades out in under 1 s
(section 3.1, 3.3 WUI, key `topic.priority.short` in 3.5, C310, C314).

v1.4 (2026-11-11): the bar's label reads "Prio" at every width
(each locale its own short form), and only on a phone is the 1..5 bar drawn
70% smaller and centred, each value a 44 px tall target with near-square corners (section 3.3
WUI, key `topic.priority.short` in 3.5, case C314; the owner, t1 2fafde5c
msgs `b6a2468d` and `0b66d67c`, SPL-5288).

v1.3 (2026-11-10): the last prio change wins, both ways: an
issue's own change sets every discussion it links, their other issues and
their lanes follow, and the 5-min sweep never undoes a newer change
(section 3.4 item 4; the owner, t1 20da7236 msgs `76af2576` and
`01c1f25e`, SPL-5223).

v1.2 (2026-11-04): the discussion's priority is the source; an
issue follows the priority set on its discussions and a lane follows its
issues (section 3.4 item 4; the owner, csitea b0f50875 msgs `ee3d6efc` and
`f061e485`, SPL-4813). This replaces panel D4.

v1.1 (2026-10-30): a topic nobody set has priority 3, not 5 (the
owner, msg `f5ed1396`, section 1; SPL-4367); issues keep their default 5.
v1.0 (2026-10-23) is step 2 of the owner rule for a big change
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

| part | msg | when (UTC) | text |
|---|---|---|---|
| 1 | `0c33bce8` | 2026-10-21 12:49:20 | "on the same row as the channel name we should have a small forw with more icons ..." |
| - | `b489f912` | 2026-10-21 12:49:26 | a screenshot, no text (g-002, msg `faf76aee`: it shows the three card-clip icons on the channel-name row) |
| 2 | `f2bb53c9` | 2026-10-21 12:50:10 | "there should be the filter for new and all topics , there shuld be a sort-by time of last update , sort by amount of msgs sort by  sort by prio" |
| 3 | `465b73d7` | 2026-10-21 12:52:16 | "where prio shoud be settable from the small control which will apear on ghe bottom or on the top depending on the pre-pending or appending settings for the user ... it should be a radio box chooser wit hthe values from 1..5" |
| 4 | `2a1c2d12` | 2026-10-21 12:52:56 | "and accordingly the orchestrator should be able to queque and give priority to those discussions which priority is closer to 1 than 5" |
| D7 | `f5ed1396` | 2026-10-29 | "I would expect some kind of small row of 1..5 radio buttons whith default 3 and one would have to click on 1 to make the prio 1 - aka the most important one" |
| v1.8-1 | `ee20b1c9` | 2026-11-25 11:16:37 | "by now hopefully any change of the prio in the discussion results into an action of the agents regardless on which object the prio has been applied troughout the e2e software development lifecycle of the features of the spool-hub . Here with let's define the meaning of the different prio numbes ..." (topic `c2838b08`) |
| v1.8-2 | `d744269f` | 2026-11-25 11:19:38 | "prio-01 must mean - start now even if you would have to stop / pause prio-04 and prio-05 and even prio-03 lanes / prio-02 start asap - as soon as resources are available - bypass others in the quer / prio-03 start as long all there is free resources available do not bypass the queue / prio-04 start when there are resources and no prio-01,prio-02,prio-03 are queueing / prio-04 [read: 05] start when there are resources and no prio-01,prio-02,prio-03 and prio-04 are queueing" (topic `c2838b08`) |
| v1.8-3 | `3ed8fd13` | 2026-11-25 | Poll `32527755` answer: Q1 "Is your table, as read above, the definition to build?" = **A Yes**; Q2 the "prio" word rule = **B Drop the word rule** (topic `c2838b08`) |
| v1.8-4 | `c6438688`, `c4fbafb5` | 2026-11-25 | "each channel should have a default prio setable in the channels settings" / "create a new discussion about the last msg , as it seems to b e a new feature" (topic `b6c7b21c`) |
| v1.8-5 | `81cbf77e` | 2026-11-25 | Poll `ab1b0c08` answer: a channel with no default set gets **3**; only **the workspace owner** may change a channel's default (topic `b6c7b21c`) |

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
  **default 5** (rdb 0054, 0055, owner 2026-09-26). A topic's default is
  3, not the issues' 5 (D7, the owner's msg `f5ed1396`).

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

### 2.7 What a priority change does today (v1.8 baseline, on `7481e6cac`)

Every `file:line` in this subsection was read on `origin/master` `7481e6cac`:

- **Topic priority writes (three paths).**
  - `hub/topic_priority.go:52-88` (`handleTopicPriority`,
    `PUT /v1/topics/{task_id}/priority`): upserts `topic_priorities`,
    immediately calls `followTopicPriority` (`:83`) and `priorityToOperator`
    (`:84`, `:97-107`, copying to the operator workspace when the setter owns
    it), and fans out `topic_priority` (`:86`).
  - `hub/topic_create_prio.go:32-103` (`createPrioCut`, `createPrioSet`,
    wired from `hub/wui.go:626,666`): strips a trailing `prio:N` / `prio-N` /
    `prio N` token from a new topic's first browser post and stores N via the
    same follow + operator-copy + fanout path.
  - `hub/owner_prio_word.go:97-128` (`ownerPrioWord`, wired from
    `hub/wui.go:667` when `createPrioSet` returns false): scans any browser
    post by a workspace owner (`workspaceOwner`, `hub/blocker_issue.go:320-326`)
    or operator workspace owner (`operatorOwner`, `hub/owner_prio_word.go:91-93`)
    for any whole word in `SPOOL_HUB_OWNER_PRIO_WORDS`
    (`api/internal/config/config.go:394`, default `"prio,priority one,urgent"`).
    A hit forces the topic to priority 1 in that workspace and in the
    operator workspace (`setPrioWord`, `:132-144`) and logs moved queued asks
    (`logPrioWordAsks`, `:148-160`).
- **Propagation to issues and live lanes.**
  - `hub/topic_priority_follow.go:146-184` (`followDiscussionPriority`),
    `:192-223` (`linkedSetPriorities`), `:293-319` (`followTopicPriority`),
    `:344-370` (`agentPrioSync`): immediately on a topic priority write and
    every 5 minutes via `do_spl_topic_prio_sync`, open issues take the
    highest priority set on their linked discussions (operator issues only
    accept sets by an operator workspace owner, `:217`), while a newer direct
    issue priority change spreads back to its discussions
    (`hub/topic_priority_spread.go`).
  - `hub/fleet_lanes_view.go:158,172` (`lanePrio`): a live lane's priority is
    computed on read as the highest priority among its issues. **No code
    today pauses, stops or signals a running lane when a priority changes.**
- **Spawn queue ordering.**
  - `hub/fleet_ask_order.go:46-51,112-159,223-267`
    (`PUT /v1/operator/fleet-asks/{ask_id}/priority`,
    `PUT /v1/operator/fleet-asks/{ask_id}/position`, and box op
    `askPosition`): lets an operator admin set an ask's `OwnPriority` or drag
    its `QueueRank` (`rdb/0323_fleet_ask_queue_order.sql`), recording
    `queue.priority_set` / `queue.position_set` (`:42-43,205-210`).
  - `store/fleet_ask.go:274-282` (`askPrio`), `:292-310`
    (`askFillPriorities`), `:334-367` (`askPositions`, `askBefore`): computes
    effective priority (newer of `OwnPriority` vs its `Discussion`'s
    `topic_priorities` row, else `TopicPriorityDefault = 3`; a `ci` row
    always ranks as 1), then orders queued asks by
    `(askPrio, QueueRank, askQueueRank [class/flag], EnqueuedAt, AskID)`.
  - `orc/spl-spawn-queue.func.sh:56-61,123-132`: lists `acked` ("placing")
    rows first, then `queued` rows by hub `position`, printing `PRIO` (`:58`).
- **Placer room check and row selection (`orc/spl-spawn-place.func.sh`).**
  - Room check (`:294-298`, `spl_spawn_place_no_room` `:695-705`): checks the
    window ceiling (`SPOOL_AGENT_CEILING`, default 40, `:696-699`), launch
    gap (`spl_spawn_place_gap_hold`, `:713-727`), and fleet load target
    (`spl_spawn_place_pick`, `:803-805`). When there is no room, only a
    logged review seat past CPU overflow can launch
    (`spl_spawn_place_seat_take`, `:295,552-560`); **even a priority 1 ask
    holds and waits** (`:296-297`).
  - Row selection (`spl_spawn_place_band`, `:452-483`):
    1. any launchable `ci` row (`:454-459`);
    2. `HEAD` when `ci` or flagged (`urgent`/`bypass`) (`:460`);
    3. `HEAD` when `priority == 1` (`:461-464`, ahead of review seats and
       class bands);
    4. a logged review seat (`:465-469`);
    5. for **priorities 2, 3, 4 and 5**, `:472-482` sorts every queued row by
       class-band deficit `(_t, -_s, _o, .position)` **without checking
       `.priority`**. Consequently, today:
       - a priority 2 ask does **not** jump ahead of bands or lower-priority
         under-band rows;
       - a priority 4 or 5 ask in an under-band class (e.g. `refactor`) can
         launch ahead of a queued priority 2 or 3 ask;
       - priority 3 asks are reordered by class bands rather than running in
         queue order.
- **Channel settings today.**
  - `channels` (`store/channels.go:88-107`) has no `default_priority` column.
  - Per-channel settings live in `ChannelPropertiesDialog.vue:303-398`
    (Settings tab: open invite, AI agents switch via `hub/channel_ai_agents.go`,
    box pins via `hub/channel_box_pins.go`) and the workspace-wide table in
    `wui/pages/tenant-settings/channels.vue:13-65`
    (`GET /v1/tenant/channels`, `hub/tenant_settings.go:358-401`).
  - Workspace ownership is checked by `s.workspaceOwner(ctx, tenant, hum)`
    (`hub/blocker_issue.go:320-326`, reading `acc.TenantOwner`) on the hub
    and `ownerAllows(access.me)` (`wui/utils/access.mjs:108-111`, reading
    `me.tenantOwner`, normalized from `/v1/view/me`'s `tenant_owner` at `:42`;
    it fails open when `me` or `me.permissions` is missing, so the hub's 403
    is the real enforcement gate) in the WUI.

## 3. Design

### 3.1 Part 1: the topic-list control on the channel header

- A new lazy component, `wui/components/TopicListControl.vue`, drawn in
  `FeedHeader.vue` before `<CardClipControl />`, on the channel, DM and
  lobby pages.
- **Two rows (v1.5, SPL-5349).** Row 1 is the full channel name: it wraps,
  never cut. Row 2 (`.feed-header__row2`) holds the filter and sort at the
  left and the card-size control at the right; their popovers open toward
  the row's end.
- **Hidden while scrolling (SPL-5380, owner t1 56f50ebb msgs 859f9742,
  6b4f264b).** On a phone row 2 of this header and of the open topic's
  header (the priority bar and the card-size control) goes and comes with
  the section strip and the logo bar, on their one state
  (`data-mobile-strip-hidden`, `layouts/default.vue` `stripAway`), no
  listener of its own; a row holding the keyboard focus stays. A desktop
  hides nothing on a scroll, so the row stays there. Test:
  `csi-spl-wui/tests/e2e/prio-cardsize-scroll-hide.test.mjs`.
- **Sizes (v1.5).** The card-size control (`CardClipControl.vue`) is drawn
  30% lower and narrower than before, in this header and in the
  topic's: cells 26 x 16 px on the desktop (was 33 x 24), 35 x 30 on a phone
  (was 44 x 44), so the control is 80 x 18 and 107 x 32. The filter and sort
  buttons take the same size (26 x 18, 35 x 32). On a phone each still has
  a 44 px tall target that stands out of the drawn cell; the target is the
  cell's width (35 px, not 44 as SPL-989 had), so 44 px holds for height
  only. Under 360 px the card-size control's cells are 29 px wide (89 x 32),
  so the topic header's row 2 keeps one line (section 3.3).
- Two icon buttons; each opens a small popover of native radios in one named
  group, as CardClipControl does (Tab lands on the group, the arrows move,
  Escape closes).
  - **Filter**: New / All.
  - **Sort**: Last update / Messages / Priority (no third sort, D12).
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
  - Priority: 1 first, 5 last; a topic nobody set is 3, between a 2 and a
    4 (D7).
  - No third sort: poll Q2 was answered A (D12).
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
- No row = priority 3 (D7). There is no "clear": setting 3 is the
  default, so every change is an upsert and leaves a `set_at`. The default
  is not stored: changing it rewrote no row (v1.1).
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
  `TopicPriorities(tenant, taskIDs) map[string]int` (absent = 3).
- The list reads a topic's priority inside `summary()`, the row statement
  spec 099 5.2 runs for the page only: one primary-key probe of
  `topic_priorities` per row, into `TopicRow.Priority`. A topic read takes it
  in the topic door's batch (`TopicAccess.Priority`). Built so at B3: a
  separate `TopicPriorities` call per read was one more DB round trip and
  failed `TestRoundTripsPerRequest` (2/1, 3/2, 3/2 against the budgets;
  dispatch holder c-002, msg `b29b98fe`).
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
  carry `priority` (1..5; 3 when nobody set it).
- A live frame `topic_priority` (task id, priority), sent through
  `fanoutTopic` (`hub/topic_archive.go:348`) as `topic_archived` is, updates
  every open view of the topic and the list without a refetch.
- `hub/openapi.json` documents the route and the field (spec 104).

**WUI.**

- `wui/components/TopicPriorityChooser.vue`: one row, a native radio group
  1..5, the current value checked. A click saves at once; a failed save puts
  the old value back and says why (`topic.priority.failed`).
- **Where (v1.5, SPL-5349).** In `TopicPane.vue` and `LiveTopicPane.vue`
  the topic header has two rows: row 1 the full title (it wraps, never cut),
  row 2 (`.topic-head__row2`) the bar at the left and the replies'
  card-size control at the right, in both Message orders. (v1.0-v1.4 put
  the bar at the pane's newest end.) The whole title replaces spec 109
  FR-011's one-line cut title in the right pane and spec 078 T004b's
  four-line clamp (`topic-pane-title-fits.test.mjs` step 5 checks it).
- **Size (v1.5).** The bar is the card-size control's size (section 3.1):
  cells 26 x 16 px on the desktop, so 132 x 18; 35 x 30 on a phone, so
  177 x 32 (SPL-5288's phone bar was about 64 x 14, centred). Each value
  keeps a 44 px tall target on a phone, its invisible radio standing out of
  the drawn cell, near-square at the smallest token radius (a 50% round
  radio is hit-tested as an ellipse, only 4-6 px wide near its top and
  bottom); row 2 stays 44 px tall so nothing covers it. Where the row is
  short (a 320 px phone, or a long label such as el "προτερ:" or tr
  "öncelik:" at 360) the bar's cells narrow, down to 26 px, before the row
  would wrap: label, bar and card-size control stay one 44 px line in every
  locale (R7 c-235 N1).
- **The label** reads "prio:" (`topic.priority.short`): lower case, a colon
  after it (the owner wrote "semicolon"; ":" is how a label reads, a
  one-character change if ";" was meant). Each locale has its own short
  form, lower case where the script has case, a colon after it.
- **A saved pick** shows "✓ N" right of the bar for under 1 s (where it
  would meet another control of the row, e.g. the card-size control on a
  360 px phone, it is drawn in the label's place instead and the label
  steps aside while it shows; R7 c-235 W1): visible,
  then a CSS opacity fade, removed at 800 ms. It is out of the flow (no row
  height, nothing jumps). With `prefers-reduced-motion` it does not fade and
  is still removed at 800 ms. Screen readers hear "Priority set to N."
  (`topic.priority.saved`, a `role=status` line drawn for them only). A
  failed save keeps its visible error line.
- The note chooser (`NotePriorityChooser.vue`, spec 155) draws the same bar
  and the same "✓ N" and stays right of the note's title (room for the
  check is kept at its right); on a phone its label is kept for screen
  readers only (SPL-4893).
- `wui/utils/spool-client.mjs` gets `setTopicPriority(taskId, prio)`;
  `wui/utils/spool-client-mock.mjs` its mock.
- **The topic card shows a small badge** when a priority other than the
  default 3 is set (panel D11): `P1`, `P2`, `P4`, `P5`, so a list sorted by
  priority shows why. `wui/components/MessageCard.vue`.

#### 3.3.1 A priority typed with the new topic (v1.7, SPL-6145)

The owner (t1 0f457318, msg `c94e2d29`): "I should be able during the
creation of a topic to just write prio:01, prio:02, prio:3, prio-04, or prio
5 at the end which will override the default prio-03 for the new topic".

- **Where**: the hub's browser send (`hub/wui.go` `wuiSend`, code
  `hub/topic_create_prio.go`), before the envelope, so every WUI page that
  opens a topic is one place. A box or CLI post is signed by its box; the
  hub does not change its body, and it sets nothing.
- **The token**: at the very end of the post, after white space or a line
  break, any case: `prio:N`, `prio:0N`, `prio-N`, `prio-0N`, `prio N`, N
  1..5. Anything else is plain text and the default 3 stays: `prio:0`,
  `prio:6`, `prio:10`, `prio: 2`, the token mid-text or glued to a word, in
  a `> ` quote line or in code, or a post that is the token alone.
- **Only the topic's first post** (a resend of that same `msg_id` too); a
  reply never changes the priority, and keeps its text as typed.
- **Who**: as the PUT, the poster being the starter: a member session, not
  a demo visitor, and "Who can archive topics" (`mayArchiveByPolicy`). A
  poster who may not set it keeps the token as text.
- **Then**: the post is stored without the token, and the topic gets the
  priority as on the PUT: `followTopicPriority` (issues and lanes),
  `priorityToOperator`, the `topic_priority` frame. In v1.7 this also beat
  the owner's prio word; in v1.8 the prio word rule is retired (section
  3.4.2) and this trailing token overrides the channel's default priority
  (section 3.3.2).
- Tests: `hub/topic_create_prio_internal_test.go` (the parser, every form
  and the rejects), `hub/topic_create_prio_test.go` (a browser send: the
  stored body, the priority, a reply, the policy).

#### 3.3.2 Default priority per channel (v1.8, topic `b6c7b21c`, SPL-6503)

Owner HUM-10 (`#spool-hub-biz` topic `b6c7b21c`, msgs `c6438688`, `c4fbafb5`;
poll `ab1b0c08` answer msg `81cbf77e`): every channel has a default priority
configurable in channel settings; an unset channel defaults to **3**; only
**the workspace owner** may change it.

**Semantics and precedence.**

- Each live channel (created channels and default channels `#lobby`, `#alerts`,
  `#feedback`, `#public`) has an optional `default_priority` (`1..5`, `NULL`
  when unset). Unset reads as `3` (`store.TopicPriorityDefault`).
- **New topics inherit it at creation.** When a new topic's first message is
  stored in a channel (`inserted == true`, `is_parent == 1`, not the legacy
  lobby task, not a DM, not a note to self):
  1. An explicit trailing `prio:N` token on a browser opening post (section
     3.3.1, `hub/topic_create_prio.go`) wins when present and allowed.
  2. Otherwise, if the channel has a non-null `default_priority`, the hub
     writes a `topic_priorities` row for `(tenant_id, task_id)` with
     `priority = channel.default_priority`, `set_by = channel.default_priority_by`,
     `set_at = now` — **only if no row already exists** for `(tenant_id, task_id)`
     (idempotent on resend). It then runs `followTopicPriority`,
     `priorityToOperator` (checked against `channel.default_priority_by`, so
     v1.6 holds: a channel default configured by a non-operator workspace
     owner never reorders the operator queue), and fans out `topic_priority`.
  3. Otherwise (`default_priority IS NULL`), nothing is written: the topic
     reads `3` (`TopicPriorityDefault`), identical to today, so SPL-4725
     issue class defaults (`bug`/`refactor` = 2, `alert` = 1;
     `hub/issue_prio_default.go:18-38`) on unset channels are preserved.
- **Interaction with issue class defaults (`hub/issue_prio_default.go:18-38`).**
  Under existing `defaultIssuePriority`, any stored `topic_priorities` row
  (step 2, `SetTopicPriorities`, including an explicit `3`) takes precedence
  over step 3's issue class defaults (`bug`/`refactor` = 2, `alert` = 1).
  Therefore, when the workspace owner explicitly sets a channel's
  `default_priority` (1..5), new topics in that channel write a
  `topic_priorities` row and **intentionally override** the issue class
  default for issues born from those topics (e.g. a low-priority channel set
  to 4 or 5 starts its bugs at 4 or 5; clearing the channel back to `null`
  restores unset behaviour and the SPL-4725 class defaults).
- **Changing it later never touches existing topics.** Updating a channel's
  `default_priority` writes only the channel row; it runs no backfill and
  modifies no existing `topic_priorities`, `issues`, or `fleet_asks` rows.
  Because new topics snapshot the channel default into `topic_priorities` at
  creation, existing topics keep the priority they were born with (or later
  set to).
- **Applies to all channel topic-creation doors**: browser sends (`hub/wui.go`
  `wuiAfterStore` when `!createPrioSet`) and box/agent/embed channel topic
  opens (`hub/ws.go` `commitRowTyped` when `inserted && isParent == 1 && channel != ""`),
  guarded by "no existing `topic_priorities` row" and "opening row only".

**Data (`rdb/`).**

- Forward-only migration `rdb/<NNNN>_channel_default_priority.sql` (next free
  number claimed via `do_rdb_migration_next`; last on `7481e6cac` is
  `0323_fleet_ask_queue_order.sql`):
  - `ALTER TABLE channels ADD COLUMN IF NOT EXISTS default_priority smallint CHECK (default_priority BETWEEN 1 AND 5);`
  - `ALTER TABLE channels ADD COLUMN IF NOT EXISTS default_priority_by text NOT NULL DEFAULT '';`
  - `ALTER TABLE channels ADD COLUMN IF NOT EXISTS default_priority_at timestamptz;`
- `channels` already carries RLS and the `change_stamp` trigger
  (`store/change_stamp_test.go:22`), so no new table, RLS policy or trigger
  is required.

**Store (`store/channel_default_priority.go`).**

- Interface `ChannelDefaultPriority` implemented by both `*Memory` and
  `*Postgres`, following `store/channel_ai_agents.go`:
  - `ChannelDefaultPriority(ctx, tenantID, channelID) (ChannelDefaultPrio, error)`
    returning `{Priority *int, SetBy string, SetAt time.Time}` (`Priority == nil`
    when unset or for an unseeded default channel).
  - `SetChannelDefaultPriority(ctx, tenantID, channelID string, prio *int, by string, at time.Time) error`
    validating `prio == nil || 1..5` (`ErrBadTopicPriority` outside `1..5`,
    `ErrNotFound` when absent or archived; upserts an unseeded default
    channel row as `SetChannelAIAgents` does; `nil` clears back to unset / 3).
  - Extend `store.ChannelSetting` (`store.SetReads.ChannelSettings`) with
    `DefaultPriority *int` so `GET /v1/tenant/channels` stays O(1) database
    round trips (`hub/n_plus_1_rt_test.go`).

**Hub API (`hub/channel_default_priority.go`, `hub/channel_members.go`, `hub/tenant_settings.go`, `hub/openapi.json`).**

- `PUT /v1/channels/{channel}/default-priority`, body
  `{"default_priority": 1..5 | null}` (with CORS `OPTIONS`):
  - Requires a signed-in member session, write-enabled billing, and not a
    demo visitor.
  - **Workspace owner only**: checks `s.workspaceOwner(ctx, t.ID, hum)`
    (`hub/blocker_issue.go:320-326`, `acc.TenantOwner == true`). Any other
    caller (including a workspace admin, developer, channel creator who is
    not the workspace owner, or an agent) gets `403 forbidden`
    (`permTenantOwner`, `"only the workspace owner can change a channel's default priority"`),
    matching `hub/embed_admin.go:92-93`.
  - Channel lookup via `s.tenantChannel(w, r, t.ID)` (`hub/tenant_settings.go:435-450`):
    covers created, private and default channels; unknown or archived ->
    `404 unknown_channel`.
  - Value outside `1..5` (and not `null`) or malformed body -> `400 bad_json`.
  - `200 OK` answers
    `{channel, default_priority: <1..5|null>, effective_priority: <1..5>, set_by, set_at}`
    and writes a workspace log event `channel.default_priority_set`.
- **Read surfaces (zero extra round trips)**:
  - `GET /v1/channels/{channel}/members` (`hub/channel_members.go:192`) adds
    `default_priority` (`1..5 | null`) and `effective_default_priority` (`1..5`).
  - `GET /v1/tenant/channels` (`hub/tenant_settings.go:358-401`) adds
    `default_priority` (`1..5 | null`) and `effective_default_priority` (`1..5`)
    per channel row.
- `hub/openapi.json` documents the route and the new response fields.

**WUI (`csi-spl-wui/src/`).**

- **Channel Properties -> Settings tab** (`wui/components/ChannelPropertiesDialog.vue:303-398`):
  - Adds a `<fieldset data-testid="channel-default-priority">` below the AI
    agents switch (and above Boxes) holding a 1..5 native radio group showing
    the channel's effective default (`3` checked when unset), plus a
    "Reset to default (3)" button when explicitly set.
  - Shown editable when `ownerAllows(access.me)` (`wui/utils/access.mjs:108-111`,
    reading `me.tenantOwner`, normalized from `tenant_owner` at `:42`; fails
    open when `me` or `me.permissions` is absent, so the hub's 403
    `tenant.owner` is the real gate). Known non-owners see the current value
    read-only with the owner-only hint.
  - Saves immediately on selection via `api.setChannelDefaultPriority(channelId, prio)`;
    rolls back and displays an alert on failure.
- **Workspace Settings -> Channels table** (`wui/pages/tenant-settings/channels.vue:13-65`):
  - Adds a `Default priority` column (`col_default_priority`): the workspace
    owner gets an inline 1..5 selector (calling the same PUT); non-owner
    admins see the read-only value (`P1..P5`, or muted `3 (default)` when unset).
- Client helpers in `wui/utils/spool-client-lazy.mjs`, `spool-client.mjs`,
  `spool-client-mock.mjs`, `tenant-settings.mjs`, `tenant-settings-mock.mjs`,
  and `types/mjs-shims.d.ts`.

### 3.4 Part 4: the orchestrator serves priority 1 first

1. **The spawn queue.**
   - Migration `rdb/0241_fleet_ask_discussion.sql` (planned as 0215; 0215
     to 0240 were taken when row B9 was built): column `discussion` (uuid,
     NULL) on `fleet_asks`, the owner topic the ask works for (panel D3).
   - The hub sets it when it writes the ask (`hub/box_ask.go:259`):
     `ASK_DISCUSSION=<uuid>` when the caller sends one; else a `topic` of
     the form `dispatch-<topic8>` is resolved with
     `TopicsByPrefix(tenant, topic8, 2)`: one match sets it, none or two
     leave it NULL, never guessed (panel F3).
   - `askPositions` reads each queued ask's discussion priority (absent =
     3). Poll Q5 (`0709b075`) was answered **A, priority first**: the queue
     ranks by priority, then the class rank, then `EnqueuedAt`, so a
     priority 1 feature goes before a priority 3 bug. Each ask in the hub's
     list carries its `priority`.
   - Every ask nobody gave a priority ranks at 3: after a set 1 or 2, before
     a set 4 or 5. With no priority set, today's order holds for every row.
   - **A discussion of another workspace** (SPL-5905: a t1 ask working for
     a csitea topic the owner set to 1 listed at 3). The queue lives in the
     operator workspace and reads its own `topic_priorities` row for the
     discussion. A set on another workspace's topic by an owner of the
     operator workspace is copied there: the prio word
     (`hub/owner_prio_word.go`, SPL-5524) and the chooser
     `PUT /v1/topics/{task_id}/priority` (`hub/topic_priority.go`
     `priorityToOperator`). The topic workspace's own owner who does not own
     the operator workspace sets the topic there and never reorders the
     queue (R7 W1, `prioWordOwners`). The operator issues linking the
     topic follow the same rule (item 4, "Across workspaces"). Tests:
     `TestOwnerPrioWordOperatorQueue`, `TestTopicPriorityOperatorQueue`.
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
4. **The discussion's priority is the source** (v1.2, SPL-4813; owner
   HUM-10, csitea b0f50875, 2026-11-04: msg `ee3d6efc` "the lanes of the
   discussions and the issues and the lanes must be the same", msg
   `f061e485` "a cron check every 5 min that the prio is applied from the
   discussions to the born by them issues and than to the lanes, because I
   want as the user to be able to triage mostly based on discussions").
   It replaces panel D4 ("an issue keeps its own priority"), which let a
   priority 1 discussion show its lane at 5: a lane's prio is the highest
   of its issues (`hub/fleet_lanes_view.go` `lanePrio`, spec 153 3.14), and
   an issue kept the 5 it was created with.
   - **The rule.** An open issue (not `done` or `diss`) takes the highest
     (lowest number) priority SET on its linked discussions
     (`issue_discussions`): a stored `topic_priorities` row, a set 3 too.
     The workspace's default discussion (`issue_discussion_default`, rdb
     0194) does not count: an issue linked there was not born of it. An
     issue with no set discussion keeps its own priority, and its create
     rule stays SPL-4725's (lane-issue-and-docs.md section 1.1b).
   - **Across workspaces.** A topic lives in one workspace, but the fleet
     files every lane's issue in the operator workspace, linking the owner's
     topic of his own workspace (prd 2026-11-04: csitea's `269d405d`, set to
     1, is linked by t1's SPL-4637 at 5; t1 holds 2 relay posts of that task,
     so the link is accepted). So the operator workspace's issues also read
     the priority set in the other workspaces; every other workspace reads
     its own only.
   - **Only an owner of the operator workspace orders the agents' work**
     (v1.6, SPL-5933; owner HUM-10, t1 e1139a1e, msg `41010d28`: "Only t1
     owners order the agents' work: the issue keeps the t1 owner's
     priority, like the queue does"). This is the one home of the rule for
     issues; the queue's is item 1. A set row of another workspace orders
     an operator issue only when its setter owns the operator workspace
     (`hub/owner_prio_word.go` `operatorOwner`, the test `prioWordOwners`
     uses for the queue); the operator workspace's own rows always count
     (`hub/topic_priority_follow.go` `linkedSetPriorities`). So when the
     operator's owner sets a csitea topic to 1 and then a csitea owner who
     does not own the operator workspace sets it to 5, the topic shows 5
     in csitea, csitea's own issues follow 5, and the operator issue and
     the queued ask keep 1, by the PUT and by the sweep alike. The other
     set rows still count as "newer" against an issue's own change for
     the spread (the last change wins, below), never for the follow: an
     operator issue weighs its own change only against the rows that may
     order it (`ownNewerThan`), so a rejected set never reopens an older
     operator owner's row over the issue's newer own change (R7 W1). A
     set by an agent in another workspace (inherit-priority, the spread of
     an agent's change) has no operator owner as its setter either, so it
     orders no operator issue: intended, only t1 owners order the agents'
     work. At create, an operator issue reads its own workspace's rows only
     (`hub/issue_prio_default.go`), which agrees. Rows set before this rule
     are not re-applied. Tests: `TestTopicPriorityIssueKeepsOperatorOwner`,
     `TestTopicPriorityRejectedSetKeepsOwnChange`.
   - **The lane** shows the highest of its issues, so it follows with them;
     nothing is stored on the lane row. A lane with no issue shows none. A
     **queued ask** already reads its discussion's priority at every read
     (`askPositions`, item 1), so the spawn queue's `PRIO` follows too.
   - **At once**: `PUT /v1/topics/{task_id}/priority` applies it to the
     issues linking that topic, after the set (`hub/topic_priority_follow.go`
     `followTopicPriority`), in the setter's workspace and in the operator
     workspace, whose run reads every workspace's topics as the sweep's does
     (else an operator issue on a far and an own topic flips every 5 min);
     each change is an issue update by the setter (its
     history names who) and an `issue` frame to the open tabs. A failed apply
     is logged, never the PUT's error.
   - **The last prio change wins, both ways** (v1.3, SPL-5223; owner
     HUM-10, t1 20da7236, msg `76af2576`: "I should be able to control the
     priority of the stuff which is getting built by just changing either
     the priority of the discussions or by changing the priority of the
     actual tasks. These should propagate"; msg `01c1f25e`: an issue
     linked to two discussions sets both).
     - A person's or an agent's change of an issue's priority (the issue
       update path, `PATCH /v1/issues/{ref}` and the agent op `update`)
       stamps `issues.priority_set_at` (rdb 0273). A change the issue takes
       from its discussions does not: its time is the discussion's
       `topic_priorities.set_at`.
     - **Issue -> discussions.** The change sets EVERY discussion the issue
       links, the workspace's default discussion and a link to another
       workspace's topic (`origin_tenant`, SPL-5126) left out, at the
       issue's own time and by whoever changed it (the sweep's seat when the
       sweep spreads it)
       (`hub/topic_priority_spread.go`). Each set discussion then applies
       as a PUT does: its other open issues follow it (the rule above),
       their lanes follow them, and the open views get the
       `topic_priority` frame. The issue's history names who changed it;
       each issue that follows gets an update by the same person.
     - **Discussion -> issues** works as before: an open issue takes the
       highest priority set on its discussions.
     - **The newest change wins.** An issue whose own change is as new as
       the set row of every discussion it links, or newer, is never moved
       by them; it sets them instead. Where one topic has a set row in two
       workspaces the newer row counts, among the rows that may order the
       issue ("Only an owner of the operator workspace", above). Two issues set one after the other
       on one discussion: the second wins, the first follows it. Every change
       is stamped to the microsecond, so a PUT in the same second as an
       issue change is still the newer.
     - **Across workspaces.** From the operator workspace a change writes
       the topic in the workspace that holds it (`topicWorkspace`: the
       fleet's lane issue on the owner's t1 topic sets t1's row). From any
       other workspace it writes that workspace's own rows only.
     - **No loop.** Only the update path and the sweep spread; the follow
       a spread starts never spreads again. A failed spread is logged,
       never the update's error: the sweep spreads it.
     - Existing issues have no stamp, so their discussions win, as in v1.2.
   - **Every 5 minutes, the safety net**: the agent issue op `prio-sync`
     (`spool issue prio-sync [--apply]`, a dry run without `--apply`) applies
     it to every issue of the caller's workspace, and from the operator
     workspace to every workspace of the hub: each takes only its own
     discussions' priorities. It first spreads every newer issue change
     (oldest first, so the newest is written last; the answer's `spread`
     list: topic workspace, topic, issue, old -> new), then the other
     issues follow. A dry run lists the spreads but not the follows they
     would start. `cd csi-spl-orc && ./run -a do_spl_topic_prio_sync`
     calls it as the dispatch lease holder's desk, on that holder's box only,
     dry run unless `DRY_RUN=0`, one log line per issue (workspace, key,
     old -> new, topic) and the count of open issues with no set discussion.
     The box cron row `topic-prio-sync` (`csi-spl-orc/cnf/box-crons/box-crons.manifest`)
     runs it with `DRY_RUN=0` every 5 minutes.

#### 3.4.1 Meaning of priorities 1..5 and fleet execution (v1.8, topic `c2838b08`, SPL-6503)

Confirmed by the owner (HUM-10, `c2838b08` msgs `ee20b1c9`, `d744269f`, poll
`32527755` Q1 = A answer msg `3ed8fd13`):

| prio | meaning |
|---|---|
| 1 | start now, even if lanes at 3, 4 or 5 must be paused or stopped |
| 2 | start as soon as resources free up, ahead of the rest of the queue |
| 3 | start while there are free resources, in queue order (no jumping) |
| 4 | start when there are resources and nothing at 1-3 is queued |
| 5 | start when there are resources and nothing at 1-4 is queued |

**Hard priority barrier across the queue and the placer.**

Every queued ask's effective priority is computed by `store/fleet_ask.go:274-310`
(`askFillPriorities`, `askPrio`: newer of `OwnPriority` vs its `Discussion`'s
`topic_priorities` row, else `3`; a `ci` class row remains pinned at priority
1 so trunk red never waits behind a priority 1 feature). The placer
(`orc/spl-spawn-place.func.sh`) filters out non-launchable held rows first
(steps `:284-290`: agy out, brief on another box, pinned box full, dark box,
unmet `After:`). Among the remaining **launchable** line, a row at priority
`P` is **never** taken while any launchable row at priority `< P` is queued.
*Tentative reading (not yet owner-decided; B15 holds on confirmation before
landing)*: a higher-priority row that is held (`After:` prerequisite,
cordoned/full pinned box, or exhausted vendor quota) is treated as
non-launchable so it does not starve launchable prio 4–5 rows; if the owner
instead wants strict blocking on any queued prio 1–3 row (held or not),
B15 checks the unfiltered queue before filtering holds.

**Fleet behaviour per priority:**

| prio | queue order (`store/fleet_ask.go`) | placer when resources are free (`spl_spawn_place_band`) | placer when no resources are free (`spl_spawn_place_no_room`) |
|---|---|---|---|
| **1** | Leads all rows (`ci` first among 1, then dragged `QueueRank`, class/flag, `EnqueuedAt`, `AskID`). | Taken immediately ahead of review seats, class bands, and prio 2..5. | On a capacity hold (window ceiling or fleet load/overflow hold), triggers **preemption** (below) to pause a running prio 5, 4, or 3 lane and launches immediately once a slot frees (skipping `SPAWN_PLACE_GAP_MIN`). Never preempts for non-capacity holds (quota, missing CLI, `After:`, cordoned box). |
| **2** | After 1, ahead of 3..5 (`QueueRank`, class/flag, `EnqueuedAt`, `AskID`). | Taken immediately ahead of class bands and ahead of every prio 3..5 row ("bypass others in the queue"). Logged review seats on the owner's review-seat GO (`spl_spawn_place_seat`, `spl-spawn-place.func.sh:465-469`) keep their existing place ahead of prio 2..5 (yielding only to `ci`, flagged, and prio 1, as today). | Waits at the head behind any prio 1 row until resources free up. Never preempts running lanes. |
| **3** | After 1..2, ahead of 4..5. Strict queue order: dragged `QueueRank` (if explicitly dragged by an admin/owner), then `EnqueuedAt`, then `AskID` — **no class-rank jumping** (pending poll Q6; class-band supply blockers and `do_spl_spawn_fill` still supply refactor/bug rows). | Taken only when zero launchable prio 1..2 rows are queued, strictly in queue `Position` order (no class-band jumping; if poll Q6 picks B, class bands apply only *within* prio 3 and never across priority tiers). | Waits in line. |
| **4** | After 1..3, ahead of 5 (`QueueRank`, class/flag, `EnqueuedAt`, `AskID`). | Taken **only** when resources are free AND zero launchable prio 1..3 rows are queued (`min_prio == 4`). Class bands never pull a prio 4 row ahead of any queued prio 1..3 row. | Waits in line. |
| **5** | Last (`QueueRank`, class/flag, `EnqueuedAt`, `AskID`). | Taken **only** when resources are free AND zero launchable prio 1..4 rows are queued (`min_prio == 5`). Class bands never pull a prio 5 row ahead of any queued prio 1..4 row. | Waits in line. |

Idle filler (`orc/spl-spawn-fill.func.sh`) already runs only when the queue
has 0 queued and 0 placing rows and queues open issues priority 1 first, so
it naturally honours 1..5.

**Priority-1 preemption: pausing, resuming, and notifying (`do_spl_lane_preempt`).**

1. **Trigger & thrash guard.**
   - Fires inside `do_spl_spawn_place` (`orc/spl-spawn-place.func.sh:294-298`)
     only when the launchable head has `priority == 1` (or `class == "ci"`)
     and `spl_spawn_place_no_room` holds on a **capacity** limit (window
     ceiling `SPOOL_AGENT_CEILING` or fleet load/overflow hold).
   - At most `SPAWN_PREEMPT_MAX_PER_TICK` (default `1`) lane is preempted per
     tick; at most one preemption per prio-1 ask; a resumed lane is immune
     for `SPAWN_PREEMPT_COOLDOWN_MIN` (default `5` min) after resume to
     prevent oscillation.
2. **Which running lanes are eligible vs protected.**
   - Live lanes and their priorities come from `GET /v1/operator/fleet-lanes`
     (`hub/fleet_lanes_view.go:158` `lanePrio`; a live worker lane whose
     issue has no priority counts as `3`).
   - **Eligible**: live worker lanes with effective priority **5, 4, or 3**.
   - **Protected (never preempted)**:
     - Priority **1** or **2** lanes (`ci` lanes count as 1).
     - Role seats (`RoleSeat == true`: orchestrator, dispatcher, failover, OD
       pool seats).
     - Lanes under a human hold (`$SPOOL_ROOT/<id>/.human-hold`,
       `do_spl_wd_hold`).
     - Lanes mid-push or mid-pre-push gate (`ROTATE_LANE_GATE_RE`, SPL-4820)
       or running a terraform/apply step.
     - Lanes whose work was already `ACCEPTED` (already closing).
   - **Victim selection order**:
     1. Lowest priority first: **5**, then **4**, then **3**.
     2. On the box that needs room (for a per-box ceiling/load hold, that
        box; for global overflow, the box with the highest load holding an
        eligible victim).
     3. Coding/doc lanes before review seats (`-reviewer`, `Kind: review`) at
        the same priority (pending poll Q8).
     4. Idle/waiting panes before active mid-turn panes; among equals,
        youngest (`AgeS` ascending) to minimize lost context.
   - **No eligible victim** (every running lane is prio 1..2 or protected):
     preempt nothing, log `INFO prio-1 preemption: no eligible prio 3..5 victim`,
     and send ONE rate-limited `blocker` to the dispatch lease holder naming
     the prio-1 ask and why no slot could be freed.
3. **How a victim lane is paused safely (zero lost WIP, pending poll Q7).**
   - Named action `orc/spl-lane-preempt.func.sh` (`do_spl_lane_preempt`, dry
     run unless `DRY_RUN=0`):
     1. Sends the victim a spool `note` (on its own `--task`) + pane poke:
        `PAUSED for priority-1 ask <ask8> (topic <topic8>): finish current command, do not start new edits; pausing in <grace>s.`
     2. Waits up to `SPAWN_PREEMPT_GRACE_SEC` (default `60` s, event-driven
        poll for idle prompt / no active push or pre-push gate; never a blind
        `sleep`). If a push/gate starts during grace, aborts preempting that
        lane and picks the next victim.
     3. Saves unfinished work via `do_spl_lane_wip_push`
        (`orc/spl-lane-wip-push.func.sh`, spec 102 section 5.4) to
        `refs/heads/wip/<lane-branch>`. A secret-scan hit (exit 3) aborts
        preempting that victim, notifies the holder, and moves to the next
        victim.
     4. Writes `$SPOOL_ROOT/<id>/lifetime/paused.json` (`paused_at`,
        `paused_by`, `preempted_by_ask`, `preempted_by_topic`,
        `original_priority`, `original_issue`, `worktree`, `branch`,
        `wip_ref`, `session_id`, `vendor`, `box`, `resume_ask_id`). Keeps the
        worktree, branch, and `$SPOOL_ROOT/<id>` intact: does **not** run
        `agent-id-retire.sh`, and `csi-spl-utl/src/bash/scripts/workdir-sweep.sh`
        adds a `KEEP paused` rule while `paused.json` exists.
     5. Closes the tmux window cleanly via `tmux-close-window.sh --agent <id>`
        (no `SIGKILL`), freeing its window slot and CPU/RAM.
     6. Re-checks room and launches the prio-1 ask immediately (bypassing
        `SPAWN_PLACE_GAP_MIN`).
4. **How a paused lane resumes.**
   - Step 3.4 automatically re-enqueues a resume ask in `fleet_asks` carrying
     the victim's original `discussion`, `class`, `priority` (3/4/5),
     original `enqueued_at` (so it sits at the **front** of its priority
     tier), and `Resume-Lane: <id>` in its brief. The lane's issue stays
     `wip` (never `diss` or closed) so `lanePrio` and `/exit-clean` keep
     working unchanged.
   - When resources free up and the placer reaches the resume ask under the
     1..5 rules:
     - On the original box: restores the lane in its preserved worktree and
       branch (`restore-<vendor>.sh`, reusing `session_id` if present, else a
       fresh session on the same worktree with a resume prompt referencing
       `paused.json` and `wip_ref`), deletes `paused.json`, and sends a
       resume `note`.
     - If the original box is unavailable: falls back to `do_spl_lane_handover`
       Mode B from `wip_ref`.
5. **Who is told.**
   - **Preempted lane**: spool `note` before window close (why paused, WIP
     preserved, resume ask id) and on resume.
   - **Dispatch lease holder** (`spl_spawn_place_dispatch`): one spool `note`
     on `spawn-queue` naming the preempting prio-1 ask + topic, paused lane
     `<id>@<box>` + priority + issue key, WIP ref (if pushed), and resume ask
     id (and one `note` on resume).
   - **Paused lane's issue**: one `do_spl_issue_comment` on pause and one on
     resume (never posting directly into a customer/owner topic).
   - **Audit / `#alerts`**: structured workspace log events
     `queue.lane_preempted` and `queue.lane_resumed`; `#alerts` only on
     preemption failure (no eligible victim or secret-scan abort), never
     routine pauses.

#### 3.4.2 Retiring the "prio" word rule (v1.8, poll `32527755` Q2 = B)

Owner HUM-10 (`c2838b08`, poll `32527755` Q2 answered **B Drop the word rule**,
msg `3ed8fd13`).

- **Where it lives today (`7481e6cac`)**:
  - Spec & active docs updated by B14:
    - `csi-spl-doc/specs/157-dispatch-automation/spec.md` **section 4.1**
      ("The owner's prio word puts its ask at the head of the queue (v0.7,
      SPL-5524)", lines 631-640) -> mark retired in B14;
    - `csi-spl-doc/doc/md/fleet-rules-index.md:56` -> remove prio word
      sentence and `owner_prio_word` code/test refs in B14;
    - `csi-spl-doc/doc/md/rounds-rulebook.md:320` -> remove "by the owner's
      prio word" (via its source Qto doc `e621cc32-df7f-49e9-a33c-6d1f872e985c`
      and `do_spl_doctree_export_md`) in B14;
    - `csi-spl-doc/specs/153-monitoring-lanes-tab/spec.md:2603` -> update
      C153's test citation from `TestOwnerPrioWordOperatorQueue` in
      `hub/owner_prio_word_test.go` to `TestTopicPriorityOperatorQueue` in
      `hub/topic_priority_test.go` in B14;
    - `csi-spl-doc/specs/177-reporter-role/checklist.md:151` -> remove
      "`1` on owner prio word, `SPL-5524`" in B14.
    - Historical references left unchanged as pre-v1.8 design context:
      `csi-spl-doc/specs/182-topic-loop-prompt/spec.md:334` and
      `csi-spl-doc/specs/185-message-forward/spec.md:321,406` (both explain
      why those features skipped `ownerPrioWord` at the time they were
      written; they describe no live trigger once `ownerPrioWord` is deleted).
  - Code & config: `hub/owner_prio_word.go` (`prioWordIn`, `ownerPrioWord`,
    `setPrioWord`, `logPrioWordAsks`), `hub/owner_prio_word_test.go`,
    `hub/wui.go:667` (`s.ownerPrioWord(...)`), `hub/server.go:116-118`
    (`Options.OwnerPrioWords`), `api/cmd/spool/hub.go:426`,
    `api/internal/config/config.go:391-394,788-796,808`
    (`SPOOL_HUB_OWNER_PRIO_WORDS`, `ownerPrioWordsOff`),
    `api/internal/config/owner_prio_words_test.go`, and `example.env.yaml:256`.
- **Shared helpers and tests to keep and relocate (do NOT delete)**:
  - `operatorOwner` (`hub/owner_prio_word.go:91-93`) and `prioWordOwners`
    (`:75-85`, renamed to `priorityOperatorTenant`) are still called by
    `hub/topic_priority.go:98` (`priorityToOperator`) and
    `hub/topic_priority_follow.go:237` (`opOwnerCached`) for the v1.6
    cross-workspace operator-owner rule -> relocate to `hub/topic_priority.go`.
  - `TestTopicPriorityOperatorQueue` (`hub/owner_prio_word_test.go:234`)
    proves `priorityToOperator` on `PUT /v1/topics/{task_id}/priority` ->
    **move into `hub/topic_priority_test.go`** in B14 before deleting
    `hub/owner_prio_word_test.go`.
  - `prioOwnText` and `prioFenceRe` / `prioCodeRe` / `prioQuoteRe`
    (`hub/owner_prio_word.go:34-45`) are still called by
    `hub/topic_create_prio.go:40` (`createPrioSuffix`) -> relocate to
    `hub/topic_create_prio.go`.
  - `csi-spl-orc/src/bash/tests/spl-spawn-place-owner-prio.tst.sh` tests the
    placer's priority-1 head selection (not word scanning) and stays: B14
    updates its header comment (`:3-6`, removing the deleted
    `TestOwnerPrioWordMovesAskToHead` reference), and B15 flips its case 3
    (`:12,72-76`, where priority 2 previously went through the bands).
- **What replaces it and why**:
  - **No automatic free-text word scanner replaces it.** Priority is set only
    through explicit controls:
    1. the **1..5 priority chooser** in the topic header (`PUT /v1/topics/{task_id}/priority`, section 3.3);
    2. the **explicit trailing `prio:N` token** of v1.7 on a new topic's
       first post (`prio:N`, `prio:0N`, `prio-N`, `prio-0N`, `prio N`,
       section 3.3.1, `hub/topic_create_prio.go`);
    3. the **channel default priority** for new topics (section 3.3.2);
    4. the issue priority field (bidirectional sync, section 3.4 item 4) and
       the operator queue priority/drag controls (`hub/fleet_ask_order.go`).
  - **Why**: under v1.8, priority 1 triggers preemption of running priority
    3..5 lanes. Scanning ordinary prose for words like `"prio"` or `"urgent"`
    causes false-positive escalations whenever the owner discusses priority
    rules or mentions urgency in passing. Keeping the trailing `prio:N` token
    of v1.7 gives fast keyboard entry with an unambiguous explicit digit
    `1..5` at the end of an opening post, stripped on store.

### 3.5 i18n

- New keys in `csi-spl-wui/i18n/locales/en.json` and the same keys in the
  other 18 locale files (19: bg el en es et fi he lt lv mk nl pl ro ru sk sr
  sv tr uk). `i18n-parity.test.mjs` refuses a missing key; the raw-text
  ratchet refuses a literal (developer guide 2.4). Row B4 landed them; the
  16 keys below, no slot-3 key (D12).

| key | en |
|---|---|
| `feed.topic_list.label` | Topic list |
| `feed.topic_list.filter` | Filter |
| `feed.topic_list.filter_new` | New |
| `feed.topic_list.filter_all` | All |
| `feed.topic_list.sort` | Sort by |
| `feed.topic_list.sort_last` | Last update |
| `feed.topic_list.sort_count` | Number of messages |
| `feed.topic_list.sort_prio` | Priority |
| `feed.topic_list.window` | Sorted: the {n} topics loaded |
| `feed.topic_list.window_new` | Showing new among the {n} topics loaded |
| `feed.topic_list.empty_new` | No new topics. |
| `topic.priority.label` | Priority |
| `topic.priority.short` | prio: (v1.5: lower case and a colon in every locale, e.g. fi "prior:"; v1.4: the chooser's label; `label` stays the badge's title) |
| `topic.priority.hint` | 1 is the most urgent, 5 the least. The orchestrator serves 1 first. (v1.8: "1 starts now (may pause 3–5), 2 next, 3 in queue order, 4 after 1–3, 5 after 1–4.") |
| `topic.priority.badge` | P{n} |
| `topic.priority.saved` | Priority set to {n}. |
| `topic.priority.failed` | Could not save the priority ({token}). |

**v1.8 channel default priority keys** (added in build row B19 across all 19 locales, reviewed via `do_spl_lang_review_gct` / agy at B21):

| key | en |
|---|---|
| `channels.properties.default_priority_label` | Default priority |
| `channels.properties.default_priority_hint` | New topics in this channel start at this priority (3 when unset). Changing it does not affect existing topics. |
| `channels.properties.default_priority_owner_only` | Only the workspace owner can change the default priority. |
| `channels.properties.default_priority_reset` | Reset to default (3) |
| `channels.properties.default_priority_saved` | Default priority saved. |
| `channels.properties.default_priority_failed` | Could not save the default priority ({token}). |
| `tenant_settings.col_default_priority` | Default priority |
| `tenant_settings.default_priority_unset` | 3 (default) |

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
| C205 | 2 | sort Priority | 1 before 5; a topic with no priority sorts as 3, between a 2 and a 4 | no priority sorts first | same |
| C206 | 2 | stable ties | equal keys keep last-update order, then task_id | drop the tie-break | same |
| C207 | 2 | the loaded-topics line | shows under a sort and under New only when an older page exists | always shown | e2e as C101 |
| C208 | 2 | unread edge with a sort | unread cards stay at the edge; each group in the chosen sort | apply the sort after the unread move | unit as C201 |
| C209 | 2 | the choice survives a reload | same filter and sort after a reload in the same browser | not stored | e2e as C101 |
| C210 | 2 | New and the unread edge agree | every card `useUnreadOrder` puts at the edge is kept by New | pass `channel.unreadFor` as `unreadOf` | unit as C201 |
| C301 | 3 | store set / read | `SetTopicPriority` 4, then read 4; an unset topic reads 3 | skip the write | `store/topic_priority_test.go` (Postgres + memory) |
| C302 | 3 | bounds | 0 and 6 refused, 1 and 5 accepted | widen the CHECK | same |
| C303 | 3 | change stamp | a set moves the tenant stamp; `TestChangeStampTriggerCatalogue` lists the table | drop the trigger | `store/change_stamp_test.go` |
| C304 | 3 | tenant isolation (RLS) | tenant B reads none of tenant A's rows | drop the RLS policy | `store/topic_priority_test.go`, as spec 099 7.4 |
| C305 | 3 | read door | a reader outside the channel gets 404 on PUT | skip the door check | `hub/topic_priority_test.go` |
| C306 | 3 | policy | with "Who can archive topics" = admins, a member gets 403 | skip `mayArchiveByPolicy` | same |
| C307 | 3 | list rows carry it | a `GET /v1/view/topics` row has `priority` | drop the join | same |
| C308 | 3 | delta | a set after the cursor lists the topic in a `since=` answer | no change kind | `hub/view_delta_test.go` (the delta has no test file of its own in `store/`) |
| C309 | 3 | live frame | a second client sees the new value without a refetch | no frame | `csi-spl-wui/tests/e2e/topic-priority.test.mjs` |
| C310 | 3 | header row 2 (v1.5) | the chooser is on the topic header's row 2, above the root, in both Message orders, one per pane | at the newest end | same |
| C311 | 3 | failed save | the old value comes back and the error line shows | keep the clicked value | same |
| C312 | 3 | card badge | `P2` on a card set to 2, `P5` at 5; no badge at 3 | badge at 3 too | `csi-spl-wui/tests/e2e/topic-priority-badge.test.mjs` |
| C314 | 3 | the bar on row 2 (v1.5) | at 360 and 390 px the bar is 177 x 32 px (+-3%; >= 1.5x the v1.4 height, >= 1.8x its width), at 1440 px 132 x 18, as tall as the card-size control (80 x 18 at 1440), bar left and control right on row 2 under the whole title, labelled "prio:"; every value taps and saves, also 15 px above its cell; after a pick "✓ N" is on the bar's line and on neither the bar nor the card-size control, adds no height and is gone by 1000 ms, reduced motion too; at 320 px and for el and he at 320/360 row 2 stays one 44 px line | the v1.4 centred 64 x 14 bar | `csi-spl-wui/tests/e2e/topic-priority-phone.test.mjs` |
| C313 | 3 | i18n parity + raw text | all 19 locales hold every new key; the raw-text count does not rise | a literal "Priority" in the template | `csi-spl-wui/tests/unit/i18n-parity.test.mjs`, `i18n-no-raw-text.test.mjs` |
| C401 | 4 | queue order | of two queued asks in one class, the priority 1 ask is position 1 even when queued later | the rank ignores priority | `store/fleet_ask_queue_test.go` |
| C402 | 4 | no priority = today | asks with no discussion keep the class, EnqueuedAt order | the default ranks first | same |
| C403 | 4 | class vs priority | priority first (Q5 A): a priority 1 feature before a priority 3 bug and before a ci row with no priority | class first (Q5 B) | same |
| C404 | 4 | discussion resolve | `dispatch-<topic8>` with one match sets `discussion`; two matches leave it NULL | take the first match | `hub/box_ask_test.go` |
| C405 | 4 | queue table | the `PRIO` column shows 1..5 | the column dropped | `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh` |
| C406 | 4 | unanswered posts | a priority 1 post comes before an older priority 5 post | ORDER BY received_at only | `store/unanswered_test.go`, `csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh` |
| C407 | 4 | lane follows its discussion (v1.2) | a priority set to 1 after the lane and its issue exist: the issue and the lane show 1; a later 3 follows; an issue on the default discussion only keeps 5 | the lane stays at 5 (master 77463637a) | `hub/topic_priority_follow_test.go` `TestTopicPriorityFollowsToIssuesAndLanes` (Memory + Postgres) |
| C408 | 4 | the 5-min sweep (v1.2) | `prio-sync` dry run lists the change and writes nothing; `--apply` writes it, counts the unset issues, walks every workspace from the operator one; a second run changes nothing | the op does not exist | `hub/topic_priority_follow_test.go` `TestTopicPrioritySyncOp`, `csi-spl-orc/src/bash/tests/spl-topic-prio-sync.tst.sh` |
| C409 | 4 | the PUT agrees with the sweep (v1.2, R7 W1) | an operator issue on a far priority 1 topic and an own topic: the own topic's PUT to 3 leaves it at 1, the next sweep changes nothing | the PUT's operator run reads its own workspace only: prio 3 (ca1176c0f) | `hub/topic_priority_follow_test.go` `TestTopicPriorityPutAgreesWithSync` |
| C410 | 4 | prio word rule retired (v1.8) | an owner browser post containing "prio", "priority one" or "urgent" leaves its topic at 3; a new topic ending with `prio:1` still sets 1; `priorityToOperator` still copies an operator owner's PUT across workspaces | restore `s.ownerPrioWord` call in `hub/wui.go` | `hub/topic_create_prio_test.go` `TestOwnerPrioWordRemoved`, `hub/topic_priority_test.go` `TestTopicPriorityOperatorQueue` (moved from `hub/owner_prio_word_test.go:234`) |
| C411 | 4 | prio 2 jumps bands and 3..5; review-seat GO preserved (v1.8) | a queued prio 2 feature launches ahead of a queued prio 3 or 4 under-band refactor without preempting running lanes (`spl-spawn-place-owner-prio.tst.sh` case 3 flips from "goes through bands" to "launches ahead of bands"); a logged review seat on an owner GO keeps its existing place ahead of prio 2..5 | keep `7481e6cac` `spl_spawn_place_band` (ignores `.priority` for prio 2..5) | `csi-spl-orc/src/bash/tests/spl-spawn-place-prio-tiers.tst.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-place-owner-prio.tst.sh` |
| C412 | 4 | prio 3 queue order; prio 4 & 5 strict barrier (v1.8) | prio 3 rows launch in `EnqueuedAt` order with no class-band jump (per Q6); a prio 4 row launches only when zero launchable prio 1..3 rows are queued; a prio 5 row launches only when zero launchable prio 1..4 rows are queued; tentative held-row reading (pending confirmation before B15 lands): a held (`After:`) prio 2 row does not block a launchable prio 4 row | drop priority filter before band sort in `spl_spawn_place_band` or keep class rank ahead of `EnqueuedAt` inside prio 3 | `store/fleet_ask_queue_test.go` `TestFleetAskQueuePrio3NoClassJump`, `csi-spl-orc/src/bash/tests/spl-spawn-place-prio-tiers.tst.sh` |
| C413 | 4 | prio 1 preemption victim order & protections, dry run (v1.8) | on a capacity hold with a launchable prio 1 head, `do_spl_lane_preempt` (dry run) selects a live prio 5 lane before 4 before 3; never picks prio 1, prio 2, role seat, `.human-hold`, or mid-push/gate lane; respects Q8 on review seats; when none is eligible, picks nothing and alerts the dispatch holder once | remove priority filter or protection guard in victim picker | `csi-spl-orc/src/bash/tests/spl-lane-preempt.tst.sh` |
| C414a | 4 | prio 1 preemption WIP-safe pause & sweep guard (v1.8) | under `DRY_RUN=0`, preempted lane receives a spool note, WIP is pushed to `refs/heads/wip/<branch>` (secret-scan hit aborts and tries next victim), `paused.json` is written, worktree is kept and protected by `workdir-sweep.sh` (`KEEP paused`), tmux window closes cleanly, holder + issue are notified, `queue.lane_preempted` is logged, and the prio 1 ask launches skipping `SPAWN_PLACE_GAP_MIN` | skip `do_spl_lane_wip_push`, skip `paused.json`, or let `workdir-sweep.sh` delete a paused worktree | `csi-spl-orc/src/bash/tests/spl-lane-preempt.tst.sh`, `csi-spl-orc/src/bash/tests/workdir-sweep.tst.sh` |
| C414b | 4 | prio 1 preemption resume ask & restore (v1.8, when Q7 = A) | pause enqueues a resume ask (`Resume-Lane: <id>`) preserving original priority and `enqueued_at`; when room returns, placer restores the lane in its worktree via `restore-<vendor>.sh` (or `do_spl_lane_handover` Mode B from `wip_ref` if box unavailable), removes `paused.json`, notifies lane/holder/issue, and logs `queue.lane_resumed` | drop `Resume-Lane:` handling in `spawn-window.sh` or leave `paused.json` stale after restore | `csi-spl-orc/src/bash/tests/spl-lane-preempt.tst.sh` |
| C415 | 3 | channel default priority store & RLS (v1.8) | unset channel returns `nil` (effective 3); set 1..5 round-trips on Memory and Postgres (including unseeded default channel); 0 and 6 refused; `nil` clears back to unset; tenant B reads none of tenant A's rows | widen `CHECK` or drop tenant scope | `store/channel_default_priority_test.go` (Memory + Postgres) |
| C416 | 3 | channel default priority API & owner-only gate (v1.8) | `PUT /v1/channels/{ch}/default-priority` succeeds for workspace owner (`TenantOwner`); returns 403 `tenant.owner` for admin, member, channel creator (non-owner), and demo visitor; 404 for unknown/archived; `GET /v1/channels/{ch}/members` and `GET /v1/tenant/channels` expose it with constant DB round trips | check `rbac.TenantSettings` instead of `s.workspaceOwner` | `hub/channel_default_priority_test.go`, `hub/n_plus_1_rt_test.go` |
| C417 | 3 | new topic inherits channel default; existing topics untouched (v1.8) | a new topic (browser or box send) in a channel with `default_priority = 2` starts at 2 and propagates to linked issues; a channel set explicitly to `4` (or `3`) writes a `topic_priorities` row that intentionally overrides SPL-4725's `bug`/`refactor` = 2 class default on issues born from it; a trailing `prio:4` token overrides the channel default; changing the channel's default later to 5 leaves previously created topics at 2; an unset channel (`null`) writes no `topic_priorities` row so SPL-4725 class defaults survive; a non-operator workspace owner's channel default never reorders the operator queue | skip the new-topic hook, backfill existing topics on PUT, or copy non-operator owner's default to op | `hub/channel_default_priority_test.go` |
| C418 | 3 | channel default priority WUI (v1.8) | workspace owner sets and resets default priority in Channel Properties -> Settings and Workspace Settings -> Channels; known non-owner admin sees read-only with owner-only hint; when `access.me` is not yet loaded (fail-open), a non-owner's PUT receives 403, rolls back, and shows the owner-only error; failed 500 PUT rolls back and shows error | enable the control for a known non-owner or skip rollback on 403/500 | `csi-spl-wui/tests/e2e/channel-default-priority.test.mjs` |
| C419 | 3 | v1.8 i18n parity, raw text & translation (v1.8) | all 19 locales hold all 8 new keys and updated `topic.priority.hint`; raw-text and untranslated ratchets do not rise; `do_spl_lang_review_gct` passes | drop a key from one locale or put a literal label in a `.vue` template | `csi-spl-wui/tests/unit/i18n-parity.test.mjs`, `i18n-no-raw-text.test.mjs`, `i18n-untranslated.test.mjs`, `do_spl_lang_review_gct` |

## 5. Build rows

Parts 1-3 first (API, then WUI), part 4 last. Each row is one small task,
no two rows share a file, and a row lands green (served on dev and prd)
before a row that depends on it starts.

| row | part | task | files (only these) | depends on |
|---|---|---|---|---|
| B1 (Implemented, a63179997) | 3 | `topic_priorities` table with RLS and the change_stamp trigger, the store; C301-C304 | `rdb/0214_topic_priorities.sql`, `store/topic_priority.go`, `store/topic_priority_postgres.go`, `store/topic_priority_memory.go`, `store/topic_priority_test.go`, `store/change_stamp_test.go` | - |
| B2 (Implemented, 3267decb0) | 3 | the delta change kind; C308 | `store/view_changes.go`, `store/view_changes_postgres.go`, `hub/view_delta_test.go` | B1 |
| B3 (Implemented, e0ca5a3c4) | 3 | `PUT /v1/topics/{task_id}/priority` (door, policy), `priority` on the view rows, the `topic_priority` frame, openapi; C305-C307 | `hub/topic_priority.go`, `hub/topic_priority_test.go`, `hub/view.go` (the row field only), `hub/openapi.json`; widened by the dispatch holder (c-002 msg `b29b98fe`) so the priority rides the reads it is on with no round trip of its own (`TestRoundTripsPerRequest` budgets unchanged): `store/view.go` (`TopicRow.Priority`, the memory twin), `store/view_postgres.go` (`summary()`), `store/channel_humans.go` (`TopicAccess.Priority`), `store/channels_postgres.go` (the topic door read) | B1 |
| B4 (Implemented, SPL-4203) | 2-3 | the i18n keys of 3.5 in all 19 locales, one commit | `csi-spl-wui/i18n/locales/*.json` | Q2 answered |
| B5 (Implemented, d7e5d1ae8) | 2 | the `topicListView` pure function; C201-C206, C208, C210 | `wui/utils/topic-list-order.mjs`, `wui/types/mjs-shims.d.ts` (its declaration), `csi-spl-wui/tests/unit/topic-list-order.test.mjs` | Q2 answered |
| B6 (Implemented, 14fbb2b7b) | 1-2 | `TopicListControl` in FeedHeader, the MessageFeed wiring, the per-browser choice; C101-C104, C207, C209 | `wui/components/TopicListControl.vue`, `wui/components/FeedHeader.vue`, `wui/components/MessageFeed.vue`, `wui/composables/useTopicListChoice.ts`, `csi-spl-wui/tests/e2e/topic-list-control.test.mjs`; widened by the dispatch holder (c-002, msgs 6888e9b6, 11df38b3) so the hub's priority reaches the sort: `wui/utils/channel-feed-core.mjs` (`mergeTopicTotals` keeps it, `e6dbae4f9`, its case in `tests/unit/reply-counts.test.mjs`), `wui/stores/channel.ts` (`priorityFor`, `7b76e5aca`) | B4, B5 |
| B7 (Implemented, 1cb90a7bf) | 3 | `TopicPriorityChooser` in both topic panes, the client call and the mock; C309-C311 | `wui/components/TopicPriorityChooser.vue`, `wui/components/TopicPane.vue`, `wui/components/LiveTopicPane.vue`, `wui/utils/spool-client.mjs`, `wui/utils/spool-client-mock.mjs`, `csi-spl-wui/tests/e2e/topic-priority.test.mjs`; at build also `wui/utils/live-ws.mjs` (the `topic_priority` frame reached no listener, 4be2503fd), `wui/types/mjs-shims.d.ts` (the client's declarations) and `csi-spl-wui/tests/unit/spool-client.test.mjs`. The client keeps one priority per topic from every source (`topicPriorityOf`); `listMessages` `totals[id].priority` carries the hub's value for B6 (holder c-002 msg `b51d924f`) | B3, B4 |
| B8 (Implemented, e0f2a6ff5) | 3 | the card badge; C312 | `wui/components/MessageCard.vue`, `csi-spl-wui/tests/e2e/topic-priority-badge.test.mjs`. The card reads `topicPriorityOf` (B7), else `channel.priorityFor` (B6), and re-reads on `onTopicPriority` | B3, B4 |
| B9 (Implemented, 2ab66feb2) | 4 | `fleet_asks.discussion`, the hub resolve, priority in `askPositions`; C401-C404 | `rdb/0241_fleet_ask_discussion.sql` (planned as 0215), `store/fleet_ask.go` (it also holds the memory store), `store/fleet_ask_postgres.go`, `store/fleet_ask_queue_test.go`, `hub/box_ask.go`, `hub/box_ask_test.go` | B1, Q5 answered |
| B10 (Implemented, 758cd4114, without the `ASK_DISCUSSION` pass-through: B10b) | 4 | the `PRIO` column, the rules-index row; C405 | `orc/spl-spawn-queue.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh`, `csi-spl-doc/doc/md/fleet-rules-index.md` | B9 |
| B10b | 4 | `ASK_DISCUSSION` from `do_spl_ask_put` and `do_spl_spawn_enqueue` through the journal and its sync to `spool ask put --discussion` | `api/cmd/spool/ask.go`, `api/internal/action/ask.go`, `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-asks.inc.sh`, `orc/spl-asks-open.func.sh`, `orc/spl-ask-put.func.sh`, `orc/spl-spawn-enqueue.func.sh`, and their tests; widened by the dispatch holder (c-002 msg `e9ef352f`) so enqueue reaches an ask already on the hub: `store/fleet_ask.go`, `store/fleet_ask_postgres.go`, `store/fleet_ask_queue_test.go`. A put on an existing row fills `discussion` only while it is NULL, never overwrites, `created` stays false | B10 |
| B11 | 2-3 | agy's language review of the 19 locales, the last step before the text ships | `csi-spl-wui/i18n/locales/*.json` (after B4, B6, B7 and B8 have landed) | B6, B7, B8 |
| B12 (Implemented, store half, bfc006e10) | 4 | unanswered posts by priority; C406 | `store/fallback_postgres.go`, `store/fallback_memory.go`, `store/unanswered_test.go`, `csi-spl-orc/src/bash/tests/unanswered-sweep-pg.tst.sh` | B1 |
| B13 (v1.2, SPL-4813) | 4 | issues and lanes follow the discussion's priority: at the PUT and by the 5-min `prio-sync` sweep; C407, C408 | `hub/topic_priority_follow.go`, `hub/topic_priority.go`, `hub/issues_agent.go`, `api/cmd/spool/issue.go`, `api/internal/action/issue.go`, `orc/spl-topic-prio-sync.func.sh`, `csi-spl-orc/src/bash/scripts/topic-prio-sync-cron.sh`, `csi-spl-orc/cnf/box-crons/box-crons.manifest`, and their tests | B1, B9 |
| B14 (v1.8) | 4 | retire the "prio" word rule: relocate `operatorOwner` / `priorityOperatorTenant` to `topic_priority.go`, move `TestTopicPriorityOperatorQueue` (`owner_prio_word_test.go:234`) into `topic_priority_test.go`, relocate `prioOwnText` to `topic_create_prio.go`, delete `owner_prio_word.go` / `owner_prio_word_test.go` / `SPOOL_HUB_OWNER_PRIO_WORDS`, update `spl-spawn-place-owner-prio.tst.sh` header, update spec 157 §4.1, `fleet-rules-index.md:56`, `rounds-rulebook.md:320` (via Qto doc `e621cc32` + `do_spl_doctree_export_md`), `spec 153:2603`, and `spec 177 checklist.md:151`; C410 | `hub/owner_prio_word.go` (delete), `hub/owner_prio_word_test.go` (delete), `hub/topic_priority.go`, `hub/topic_priority_test.go`, `hub/topic_create_prio.go`, `hub/topic_create_prio_test.go`, `hub/topic_priority_follow.go`, `hub/wui.go`, `hub/server.go`, `api/cmd/spool/hub.go`, `api/internal/config/config.go`, `api/internal/config/owner_prio_words_test.go` (delete), `example.env.yaml`, `csi-spl-orc/src/bash/tests/spl-spawn-place-owner-prio.tst.sh` (header only), `csi-spl-doc/specs/157-dispatch-automation/spec.md`, `csi-spl-doc/doc/md/fleet-rules-index.md`, `csi-spl-doc/doc/md/rounds-rulebook.md`, `csi-spl-doc/specs/153-monitoring-lanes-tab/spec.md`, `csi-spl-doc/specs/177-reporter-role/checklist.md` | - |
| B15 (v1.8) | 4 | enforce 1..5 priority barrier and tier rules in queue & placer (prio 2 jumps bands/3..5 while preserving logged review-seat GO order; flip `spl-spawn-place-owner-prio.tst.sh` case 3; prio 3 queue order per Q6; prio 4 after 1..3; prio 5 after 1..4); C411, C412 | `store/fleet_ask.go`, `store/fleet_ask_queue_test.go`, `orc/spl-spawn-place.func.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-place-owner-prio.tst.sh`, `csi-spl-orc/src/bash/tests/spl-spawn-place-prio-tiers.tst.sh`, `csi-spl-doc/doc/md/fleet-rules-index.md` | B14, Q6 answered (and W2a held-row reading confirmed) |
| B16a (v1.8) | 4 | priority-1 preemption victim picker & protections (`do_spl_lane_preempt` dry-run log only: reads `GET /v1/operator/fleet-lanes`, orders 5 -> 4 -> 3, protects prio 1–2 / role seats / `.human-hold` / mid-gate / `ACCEPTED`, applies Q8 on review seats, alerts holder when no victim exists); C413 | `orc/spl-lane-preempt.func.sh`, `csi-spl-orc/src/bash/tests/spl-lane-preempt.tst.sh` | B15, Q8 answered |
| B16b (v1.8) | 4 | priority-1 live pause protocol (`DRY_RUN=0`): spool notice, event-driven grace poll, WIP push (calling `orc/spl-lane-wip-push.func.sh`), `paused.json`, clean window close (calling `tmux-close-window.sh`), disk-sweep `KEEP paused` rule, placer capacity-hold trigger skipping `SPAWN_PLACE_GAP_MIN`, holder/issue notifications & `queue.lane_preempted` event; C414a | `orc/spl-lane-preempt.func.sh`, `orc/spl-spawn-place.func.sh`, `csi-spl-utl/src/bash/scripts/workdir-sweep.sh`, `csi-spl-orc/src/bash/tests/spl-lane-preempt.tst.sh`, `csi-spl-orc/src/bash/tests/workdir-sweep.tst.sh` (calls existing `orc/spl-lane-wip-push.func.sh` and `spawn-agents/scripts/tmux-close-window.sh`, unmodified) | B16a, Q7 answered |
| B16c (v1.8) | 4 | priority-1 auto-resume ask & lane restore (when Q7 = A): enqueue resume ask (`Resume-Lane: <id>` preserving priority and `enqueued_at`), restore in preserved worktree via `restore-<vendor>.sh` or handover Mode B fallback from `wip_ref`, clear `paused.json`, resume notifications & `queue.lane_resumed` event; C414b | `orc/spl-lane-preempt.func.sh`, `orc/spl-spawn-place.func.sh`, `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`, `csi-spl-orc/src/bash/tests/spl-lane-preempt.tst.sh` (calls existing `spawn-agents/scripts/restore-{agy,claude,codex,grok,mistral,qwen}.sh`, `restore-core.inc.sh`, and `orc/spl-lane-handover{,-agy,-mistral,-wip}.func.sh`) | B16b, Q7 = A |
| B17 (v1.8) | 3 | channel `default_priority` migration (`rdb/<NNNN>_channel_default_priority.sql`) and store (`ChannelDefaultPriority`, batch read in `SetReads`); C415 (`PRE_PUSH_TIER=full`) | `rdb/<NNNN>_channel_default_priority.sql`, `store/channel_default_priority.go`, `store/channel_default_priority_test.go`, `store/channels.go`, `store/channels_memory.go`, `store/channels_postgres.go` | - |
| B18 (v1.8) | 3 | `PUT /v1/channels/{channel}/default-priority` (workspace owner only), read fields on channel members & tenant channels, new-topic inherit hook (browser & box), OpenAPI; C416, C417 | `hub/channel_default_priority.go`, `hub/channel_default_priority_test.go`, `hub/channel_members.go`, `hub/tenant_settings.go`, `hub/wui.go`, `hub/ws.go`, `hub/server.go`, `hub/openapi.json` | B14, B17 |
| B19 (v1.8) | 3 | v1.8 i18n keys (8 channel-default keys + updated `topic.priority.hint`) in all 19 locales; C419 | `csi-spl-wui/i18n/locales/*.json` | - |
| B20 (v1.8) | 3 | WUI channel default priority control in Channel Properties -> Settings and Workspace Settings -> Channels, client & mock helpers; C418 | `wui/components/ChannelPropertiesDialog.vue`, `wui/pages/tenant-settings/channels.vue`, `wui/utils/spool-client-lazy.mjs`, `wui/utils/spool-client.mjs`, `wui/utils/spool-client-mock.mjs`, `wui/utils/tenant-settings.mjs`, `wui/utils/tenant-settings-mock.mjs`, `wui/types/mjs-shims.d.ts`, `csi-spl-wui/tests/e2e/channel-default-priority.test.mjs` | B18 (live on dev & prd), B19 |
| B21 (v1.8) | 3 | language review of the v1.8 keys across all 19 locales (`do_spl_lang_review_gct` / agy); C419 | `csi-spl-wui/i18n/locales/*.json` | B20 |

**v1.8 build order and gates.**

- Three independent tracks can start immediately in parallel: **B14** (drop prio word), **B17** (channel default rdb + store), and **B19** (i18n keys).
- Track A (priority semantics): `B14 -> B15 -> B16a -> B16b -> B16c` (skip `B16c` if Q7 is answered B). B15 touches `store/fleet_ask.go`, so run `PRE_PUSH_TIER=full`. B14 and B18 both touch `hub/wui.go` and `hub/server.go`, so B18 runs after B14 lands.
- Track B (channel default priority): `B17 (+ B14) -> B18 -> (wait for dev & prd deploy) -> B20 (+ B19) -> B21`. B17 touches a migration and store (`PRE_PUSH_TIER=full`, claim migration number via `do_rdb_migration_next`); B20 runs WUI e2e on the generated bundle (`pnpm run test:e2e`); B21 runs `do_spl_lang_review_gct` last.

- Every row runs the module gate of the repo CLAUDE.md before its push.
- The default 3 (v1.1, SPL-4367) is one constant per side:
  `store.TopicPriorityDefault` (B1; B3, B9 and B12 read it) and
  `TOPIC_PRIORITY_DEFAULT` in `wui/utils/topic-list-order.mjs` (B5).
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
- B10 as built (dispatch holder c-002 msg `38d0b1fc`): `do_spl_spawn_queue`
  prints `PRIO`, the hub's priority of each ask (`-` from a hub that sends
  none), and C405 is section 20 of `spl-spawn-queue.tst.sh`. The
  `ASK_DISCUSSION` pass-through could not be built in B10's files: the
  `spool ask` CLI has no `--discussion` flag (`grep -c discussion` on
  `cmd/spool/ask.go` and `internal/action/ask.go` -> 0 and 0), and the ask
  reaches the hub through the journal (`spool-asks.inc.sh`) and its sync
  (`spl-asks-open.func.sh`); it is row B10b. Until then an ask whose topic is
  `dispatch-<topic8>` already gets its discussion, and so its priority, from
  the hub's resolve (B9, C404); an ask with any other topic ranks at 3.
- B10b as built (SPL-4654): `ASK_DISCUSSION` on `do_spl_ask_put` goes into the
  journal record and, through the sync, to `spool ask put --discussion`; no
  discussion sends no flag, so a box with an older spool binary keeps syncing.
  `do_spl_spawn_enqueue` runs a direct put of the journal record, not the
  sync's replay, because a queued ask has no op to replay; a failed put or a
  discussion already set is one WARN and the ask still queues. The journal
  mirror carries `discussion`. The group path (`spl-spawn-group-put.func.sh`)
  is not in the row and takes no `ASK_DISCUSSION`. Tests:
  `TestFleetAskPutFillsDiscussion` (Memory and Postgres), `TestAsk`,
  `TestAskVerbDiscussion`, section 17 of `asks.tst.sh`, section 21 of
  `spl-spawn-queue.tst.sh`.
  Since the fill does not move `updated_at`, a discussion filled after
  another machine mirrored the ask reaches it only through the mirror's change
  key, which carries `discussion` (section 17 of `asks.tst.sh` fills one after
  the mirror). The hub's `dispatch-<topic8>` resolve runs on every put, so a
  re-put of a row whose discussion is still NULL (the sync puts each ask
  before it replays its ops) now stores the resolve too: an ask whose topic
  becomes resolvable after its first put gets its discussion, and its
  priority, then. The header of rdb `0241_fleet_ask_discussion.sql` ("the hub
  sets it once, when it writes the ask") predates this; the migration is
  forward-only, so this note is the record. Deploy order: the hub and the box
  spool binary ship before an orc that passes `ASK_DISCUSSION`. A spool binary
  without `--discussion` refuses the flag on every tick, so that ask stays
  `synced:false` and its later ops do not replay. An enqueue whose hub answer
  has no discussion logs "the hub did not store the discussion".
- B3 and B9 ship the hub (run 20); B6, B7, B8 and B11 ship the WUI (run
  30). A row is done when it is served on dev and prd.
- B4 and B11 both edit the locale files, never at the same time: B11 starts
  only after B4, B6, B7 and B8 have landed.
- B6, B7 and B8 run the WUI e2e on the generated bundle (repo CLAUDE.md),
  not only `pnpm run typecheck`.
- B6 as built: the priority sort reads `channel.priorityFor`, the hub's
  value on the topic totals, which B7's `listMessages` copies onto
  `totals[id].priority` (`spool-client.mjs`); a topic with none reads 3. LiveFeed still orders the unread group by its unread
  count (`useUnreadOrder`, SPL-2506), so under a sort the unread cards stay
  at the edge most unread first and the read group follows the sort. C104's
  planted control (a static import in FeedHeader) did not move
  `ci_initial_gzip_kb` (153.8 KB both, n=1): FeedHeader is in the channel
  route's chunk, so that budget cannot see this defect.

## 6. Panel decisions

The questions of v0.1 section 6 (P1-P4) and the section 7 polls the panel
could settle on evidence. Each seat's vote and any dissent, with its msg id,
is in panel.md section 3.

| id | question | decision | reason (evidence on `25e1686d6`) |
|---|---|---|---|
| D1 (P1) | server sort or client sort | client sort and filter over the loaded pages for v1, with the "N topics loaded" line; no `sort=` on the API now | `topic_heads` has one index, `(tenant_id, last_at DESC, task_id DESC)` (`rdb/0144:78`); a sort by count or priority would read every topic of the channel, the walk spec 099 removed. A server sort is a later spec that starts with a measurement |
| D2 (P2) | where priority is stored | own table `topic_priorities` (0214), read for the page's task ids only | only the head trigger writes `topic_heads` (spec 099 4.1); a page read on the primary key costs one index probe per page |
| D3 (P3) | how an ask links its discussion | explicit `fleet_asks.discussion` (rdb 0241, planned as 0215), set by the hub at write | a read-time prefix lookup would run per queued row on every queue read; `TopicsByPrefix` (`store/issue_discussions.go:102-104`) already does the one lookup at write |
| D4 (P4) | issue priority vs discussion priority | separate; nothing copies (replaced in v1.2 by the owner, msgs `ee3d6efc`, `f061e485`: the issue follows its discussion, section 3.4 item 4) | two copies of one value drift; the queue reads the discussion's through D3 |
| D5 (Q1) | what "new" means in the filter | a topic with unread messages | the WUI's existing "new" is unread: `cardNew.unseen` / `openerNew` (`LiveFeed.vue:91-92, 295`) |
| D6 (Q6) | where the filter / sort choice is kept | per browser | the card-clip control beside it is kept per browser (`CardClipControl.vue:5`); no API, no migration |
| D7 (Q3) | a discussion nobody set | priority 3; no "None", no clear (v1.1; v1.0 had 5, as an issue) | the owner, msg `f5ed1396` (2026-10-29): "radio buttons whith default 3" (section 1). Issues keep 5 (`store/issues.go:63-65`, owner 2026-09-26) |
| D8 (Q4) | who may set it | the read door, then the workspace's "Who can archive topics" policy | one existing policy for topic changes (`hub/topic_archive.go:147-152`, CLE-77819); no new setting |
| D9 (Q7) | unread at the edge after a sort | yes | owner rule SPL-2506: "every listing puts the items with unread at the edge" (`useUnreadOrder.ts:2-5`) |
| D10 (F5) | where the write route lives | `PUT /v1/topics/{task_id}/priority` | every `/v1/view/` route reads (`hub/view.go:48-62`) |
| D11 (Q8) | does the card show the priority | a small badge when not 3 | a list sorted by priority with no visible value cannot be read |
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

Q2 answered **A** (msg `f6350266`): decision D12.

```poll
Q5. In the orchestrator's queue, how does a discussion's priority combine with the work class (CI, refactor, bug, feature)?
(A) Priority first: a priority 1 feature goes before a priority 3 bug
(B) Class first: priority orders the rows inside each class
(C) CI-red first, then priority, then class
```

Q5 answered **A** (poll `0709b075`).

### v1.8 open questions (holding B15 / B16a–B16c nuances; defaults noted in section 3.4.1)

```poll
Q6. Inside priority 3 ("in queue order, no jumping"), how should the 20–30% refactor/bug class bands behave?
(A) Strict FIFO inside priority 3 (no class-band jumping; bands remain in supply blockers and idle filler only)
(B) Class bands still reorder within priority 3 (never across priorities 1, 2, 4 or 5)
```

```poll
Q7. When a priority 1 ask needs a slot and pauses/stops a running priority 3–5 lane, how should it resume?
(A) Pause and auto-resume: push WIP to a wip/ ref, close the window, keep the worktree, and re-queue at the front of its priority
(B) Stop only: push WIP to a wip/ ref, close the window, and let the orchestrator decide later whether to restart
```

```poll
Q8. May priority-1 preemption pause a running priority 3–5 review seat (-reviewer)?
(A) Only as a last resort, after all non-review priority 5, 4 and 3 lanes
(B) Never preempt review seats (they finish already-written work)
(C) Treat review seats the same as any other priority 3–5 lane
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
