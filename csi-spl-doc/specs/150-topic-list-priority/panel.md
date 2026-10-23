# 150 panel record (step 2)

The panel that turns spec 150 v0.1 into v1.0 (the owner's big-change rule,
spec 099 header, step 2). Brief: `c002-s150-panel-editor`.

| seat | vendor | agent | brief slug |
|---|---|---|---|
| editor | claude | c-875 | `c002-s150-panel-editor` |
| seat | mistral | (see section 4) | `c002-s150-panel-seat-mistral` |
| seat | agy | (see section 4) | `c002-s150-panel-seat-agy` |

The panel works on ONE tree: origin/master `25e1686d6` (v0.1 itself; its only
change against `7ca2732e9`, the tree v0.1 cites, is the spec file:
`git diff --stat 7ca2732e9 25e1686d6` -> `spec.md | 441 +`). Every `file:line`
below is on `25e1686d6`, read with `git show 25e1686d6:<path> | grep -n`.

## 1. Editor re-check of v0.1 section 2

Every reference in section 2 was read again. All hold; the notes in
section 2 sharpen some of them.

| v0.1 claim | check | result |
|---|---|---|
| `FeedHeader.vue:16-41`, h2 at 27, archived 31-39, `<CardClipControl />` at 40 | `grep -nE '<header\|<h2\|CardClipControl'` -> 16, 27, 40 | holds |
| `CardClipControl.vue:9-20`, `role="radiogroup"` | -> `<template>` 9, `role="radiogroup"` 12 | holds |
| pages use FeedHeader at line 3 | `sed -n 3p` on the three pages -> `<FeedHeader` | holds |
| `MessageFeed.vue:21-40` hands `channel.newestFirst` | -> `<LiveFeed` 21, `:rows="channel.newestFirst"` 23 | holds |
| `stores/channel.ts:122-123` | -> `const view = computed(() => channelView(...))` 122 | holds |
| `channel-feed.mjs:739-756` `channelView` | -> the doc block starts 739, `export function channelView` 753 | holds (function at 753) |
| `feed.mjs:38` `newestActivityFirst` | -> 38 | holds |
| `LiveFeed.vue:299` `useUnreadOrder` | -> `const shown = computed(() => unreadOrder.order(...))` 299 | holds; see F4 |
| `useUnreadOrder.ts:1-18` | file is 18 lines | holds |
| `spool-client.mjs:679-689` | -> `async listMessages` 679, `api.listTopics` 690 | holds |
| `hub/view.go:54` | -> `GET /v1/view/topics` 54 | holds; see F1 |
| `store/view.go:34-66` `TopicQuery`, `:69-79` `TopicRow` | -> 34-66, 69-79; no sort, no priority field | holds |
| `rdb/0144_topic_heads.sql:62-81` | -> `CREATE TABLE topic_heads` 62, index `topic_heads_last` 78 | holds |
| `en.json:121-126`, `:127-132` | -> `message_order` 121, `composer_position` 127 | holds |
| `TopicPane.vue:30/:61`, `LiveTopicPane.vue:30/:62` (`BornTopics`) | -> 30, 61; 30, 62 | holds |
| `TopicPane.vue:17-27` header, `:25` clip slot | -> `<header>` 17, `clip-slot` 25, `</header>` 27 | holds |
| `store/store.go:114` `Message` | -> 114 | holds |
| `grep -l priority rdb/*.sql` | -> 0047, 0054, 0055, 0078, 0181 | holds |
| `store/issues.go:60-66` | -> `IssuePriorityMin 1`, `Max 5`, `Default 5` at 63-65 | holds |
| `store/fleet_ask.go:248-272` `askPositions`, `:172-191` class rank | -> comment 248, func 251-273; `askClassRank` 172-191 | holds |
| `store/fleet_ask.go:44` `Topic` | -> 44 | holds |
| `rdb/0097_fleet_asks.sql:46` topic CHECK | -> 46 | holds |
| `orc/spl-spawn-queue.func.sh:22` | -> 22 | holds |
| `orc/spl-spawn-place.func.sh:36-41` bands | -> 37-41 (3b. BANDS) | holds |
| `store/fallback_postgres.go:126` | -> `ORDER BY m.received_at, m.msg_id` 126, func 111 | holds |
| next free migration 0214 | `git ls-tree` rdb dir -> last is `0213_box_locks.sql` | holds today; re-check at build |
| 19 locales | `git ls-tree` locales -> 19 files | holds |
| every build-row file that exists today | `git cat-file -e` on each -> all present | holds |

## 2. Editor findings against the v0.1 design (section 3)

**F1. A priority write must move the tenant change stamp.** `GET
/v1/view/topics` and `GET /v1/view/topics/{task_id}` are stamped views
(`hub/view.go:53-55`, `s.stampedView`): a repeat read answers 304 from the
tenant change stamp (`hub/view_stamp.go:15-20`). The stamp moves only on a
write to a table that carries the `change_stamp` trigger
(`rdb/0103_tenant_change_stamps.sql:112-149`). `topic_priorities` would have
none, so after a priority change a repeat read answers 304 with the old
order until something else writes. Fix: 0214 adds the trigger, and B1 adds
the table to `stampTables` in `store/change_stamp_test.go:21-25`, whose
`TestChangeStampTriggerCatalogue` (`:43`) fails when the list and the
triggers part.

**F2. A reconnect delta does not carry a priority change.** The `since=`
catch-up (`hub/view_delta.go:13-34`) lists only the topics that changed after
the cursor, from the change sources in `store/view_changes.go`. A priority
set while a tab was offline is in none of them, so that tab keeps the old
value until a full read. Fix: `topic_priorities.set_at` becomes a change
source. A clear that deletes the row leaves no trace, the same case as an
unarchive (`view_changes.go:21-22`), so a clear is stored as the row with
`priority NULL`, which keeps a `set_at`.

**F3. Reuse the hub's short-id resolver; do not resolve in bash.**
`store/issue_discussions.go:102-104` `TopicsByPrefix(tenant, prefix, limit)`
already resolves an 8-hex short id inside a tenant; the issue route calls it
with limit 2 to see a tie (`hub/issue_discussions.go:65`). v0.1 had
`do_spl_ask_put` / `do_spl_spawn_enqueue` look the topic up. Fix: the hub's
ask write resolves `dispatch-<topic8>` with `TopicsByPrefix(..., 2)` (one
match sets `discussion`, none or two leave it empty), and the orc actions
pass `ASK_DISCUSSION` only when they hold the full uuid.

**F4. Name the one unread count.** v0.1 says Filter New uses "the same count
the card's unread badge and `useUnreadOrder` use". They are two counts:
`LiveFeed.vue:295` ranks by `cardNew.unseen(m)` for `useUnreadOrder`, while
`MessageFeed.vue:30` passes `channel.unreadFor` (`stores/channel.ts:725-727`,
CLE-77804) to the card. Fix: `topicListView` takes `unreadOf` from its
caller, and the caller passes the function `useUnreadOrder` ranks by, so a
card at the unread edge is a card the filter keeps.

**F5. The write route belongs outside `/v1/view/`.** Every route under
`/v1/view/` reads (`hub/view.go:48-62`: GETs, plus two POSTs that read by a
body list). The nearest write, the topic archive, is
`PUT|DELETE /v1/messages/{msg_id}/archive` (`hub/server.go:433-434`). Fix:
the read field stays on the view rows; the write moves to
`PUT|DELETE /v1/topics/{task_id}/priority` (no `/v1/topics` route exists
today: `git grep -nE 'HandleFunc\("[A-Z]+ /v1/topics'` -> none), with the
same read door.

**F6. "New" sees the loaded pages only.** A client filter sees the loaded
pages (20 topics each). An unread topic on an older page is not listed under
New until the reader scrolls to it. Fix: the "the N topics loaded" line
shows under New too, as under a sort.

**F7. Name the live frame as the hub names them.** v0.1 called it
`topic.priority`. The archive's frame is `topic_archived`
(`hub/topic_archive.go:38`), sent through `fanoutTopic` (line 348), which
reaches the topic's readers. Fix: `topic_priority`, through `fanoutTopic`.

**F8. The delta's test lives in the hub.** No `store/` test calls
`ViewChanges` (`git grep -lE 'ViewChanges|ChangeQuery' 25e1686d6 -- csi-spl-api`
-> `hub/view_delta.go`, `store/view_changes.go`,
`store/view_changes_postgres.go`); the delta is tested in
`hub/view_delta_test.go`. The F2 row writes its case there.

## 3. Seat votes

### 3.1 mistral seat, m-876

- **Votes** (msg `a88a3228`): AGREE on F1-F6, on P1-P4 as the editor put
  them (spec section 6, D1-D4), and on every section 7 trim: Q1 -> A, Q3 -> B,
  Q4 -> the archive policy, Q6 -> per browser, Q7 -> A, Q8 -> A. "No disputed
  claims"; build rows "correct and disjoint". No dissent.
- **Its own checks** (msg `00f3e913`, after the editor asked for them in
  `36f4b025`): it ran three commands on `25e1686d6` and pasted their output:
  `store/change_stamp_test.go | sed -n 21,25p` (F1), `store/issues.go |
  sed -n 60,66p` (Q3) and `store/fleet_ask.go | sed -n 251,273p` (P3, Q5).
  The editor re-ran all three and diffed them: every pasted line matches,
  and the F1 paste leaves off line 25 (`"rbac_roles", ... "tenant_memberships",`).
- **How far it reaches:** the seat's votes on the other points restate the
  editor's evidence and add no command of their own, so they are its
  agreement, not an independent re-check. Its earlier "attached file"
  (msg `7c24ae60`) holds the same text as `a88a3228`; a sign message with
  empty output blocks (`e4d73540`) was followed by `00f3e913`.

### 3.2 agy seat

(Pending: the agy seat is held in the spawn queue while agy is out of quota.)

## 4. Signatures

| seat | agent | signed | msg id |
|---|---|---|---|
| editor | c-875 | spec 150 v1.0 | the v1.0 commit |
| mistral | m-876 | "SIGN spec 150 v1.0 blob 3c3fab2be6ee973b2ae6f9c0c29bc86719ddd3bb" | `00f3e913` |
| agy | (pending) | | |
