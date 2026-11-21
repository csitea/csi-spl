# Spec 189: A new topic lands at the list end

Status: **v1.0** (2026-11-21): the owner's four answers folded (section
1.1), spec review PASS (section 8). Lane `c-601` (`claude`, backup for `specs_and_docs`: no agy
cli on this box).
Build: rows B1-B7 built by lane `c-760` on branch
`review/c002-s189-b1-b7-topic-list-end-build` (the `feat(wui, SPL-6143)` commit and
the help commit after it); its language check is Google Cloud Translation
(`do_spl_lang_review_gct`, run `20261121T105714Z-83125f6a`: 7 match, 11 differ
only in gender agreement with each locale's word for "topic", 0 placeholder);
not on master until the R7 code review passes. The fresh set and `pinEdge` share
`wui/utils/topic-list-order.mjs` (no new shim block: the shims cap is 102).
Epic: **SPL-2403**. Issue: **SPL-6143**. Class: `feature`. Kind: `specs_and_docs`.
Placement: `c002-s-new-topic-pinned-end-spec`.
Discussion: `topic:a48d75d6-0385-4cfe-9316-5a859a6184f8` (`t1`), task
`dispatch-a48d75d6`.
Builds on: [005 spool WUI](../005-spool-wui/spec.md) (the channel feed and
its topic cards) and [150 topic list priority](../150-topic-list-priority/spec.md)
(the topic list's filter, sort and default priority 3).

Number: the highest spec on `origin/master` `974d97031` is
`188-channel-rules-dialog`
(`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -2`); no
other worktree of this box (only this lane's own `c-601` worktree, which
holds this spec) and none of the 478 fetched `refs/remotes/origin/*` holds
a `189-` or `19x-` folder (`git ls-tree` of each -> none), so this is 189.

Paths below: `wui/` = `csi-spl-wui/src/`, `tests/` = `csi-spl-wui/tests/`.
Every line number is on `origin/master` `974d97031`.

## 0. The owner's ask (verbatim)

HUM-10, t1 topic `a48d75d6`, msg `b548992a-7ee1-4418-8c21-66dfba1cda35`:

> "regardless of the current sorting and filtering for the topics in a
> channel the new story , regardless of the default prio 3 should always
> appear on the top or bottom of the list depending on what kind of setting
> ( pre-pend or append the user has )"

Read as: a topic that was just created shows at the edge of the channel's
topic list where new posts go (the top for **Newest first**, the bottom for
**Newest last**), whatever the list's filter (New / All) and sort (Last
update / Number of messages / Priority) are, and even though its priority is
the default 3.

## 1. Owner questions (one form)

The form as posted (t1 `a48d75d6`, poll `7f51bc86`). My recommendation was
the first option of each question; the owner chose it on all four (1.1).

```poll
Q1 Whose new topic goes to the list end?
(OWN) Only a topic I created myself (others' new topics keep today's unread edge)
(ANY) Any new topic, mine or one arriving live from someone else
Q2 How long does it stay pinned at the end?
(RLD) Until I leave the channel or reload the page
(OPN) Until I open another topic
(SRT) Until I change the sort or the filter
(MIN) For 10 minutes
Q3 Does the New filter, which would hide my own topic, still show it?
(YES) Yes, it shows while it is pinned
(NO) No, the filter wins
Q4 Is the pinned card marked?
(BDG) Yes, a small "new" badge on the card while it is pinned
(NO) No mark
```

### 1.1 The owner's answers

HUM-10, t1 `a48d75d6`, msg `fa6d8718-dc40-4124-9602-00b13c446ab2`
(08:09:48Z), relayed verbatim by the dispatch holder c-002@sat (spool msg
`078d5ef8`):

The answer texts below are the owner's, verbatim.

| Q | answer | what it decides |
|---|---|---|
| Q1 | **OWN**: Only a topic I created myself (others' new topics keep today's unread edge) | D1, C5 |
| Q2 | **RLD**: Until I leave the channel or reload the page | D2, C6 |
| Q3 | **YES**: Yes, it shows while it is pinned | D3, C3 |
| Q4 | **BDG**: Yes, a small "new" badge on the card while it is pinned | D4, C7 |

### 1.2 Decisions

- **D1 whose.** Only a topic the viewer created in this tab is pinned. A
  new topic from someone else arriving live is not pinned; it keeps today's
  unread edge (2.4, last paragraph).
- **D2 how long.** The pin lasts until the viewer leaves the channel (opens
  another channel, a DM, Issues or any route off this channel) or reloads
  the page. Opening a topic, changing the sort or the filter, and time do
  not end it.
- **D3 the New filter.** A pinned card is shown under **New** although it
  is read.
- **D4 the badge.** A pinned card carries a small "new" badge.

## 2. What exists (measured on `origin/master` `974d97031`)

### 2.1 The "prepend / append" setting

- It is **Message order** in Settings -> Behaviour: **Newest first** (top,
  "prepend") or **Newest last** (bottom, "append"),
  `wui/public/help-md/user-settings.md:161-163` (section 5.3).
- It lives on the account, the hub's `humans.message_order` (rdb 0070), read
  from the session claim: `wui/composables/useViewPrefs.ts:18`
  (`messageOrder`), `:20` (`newestLast = messageOrder === 'newest-last'`).
- A feed's rows come newest first from every store; `displayOrder`
  reverses them for newest last (`wui/utils/view-prefs.mjs:94-97`).

### 2.2 Where the topic list is filtered and sorted

Two steps, both on every channel feed:

1. **Filter and sort**, `wui/components/MessageFeed.vue:106-116`
   (`listRows`): with the defaults (All, Last update) the rows pass
   untouched (`:108`); otherwise `topicListView`
   (`wui/utils/topic-list-order.mjs:85-104`) drops the read cards under
   **New** (`:100`) and sorts **unread group first**, then the chosen key,
   then last update, then `task_id` (`:102`). The choice is per browser,
   localStorage keys `spool-topic-list-filter` / `spool-topic-list-sort`
   (`wui/composables/useTopicListChoice.ts:19-20`).
2. **Unread edge**, `wui/components/LiveFeed.vue:292` and `:304`
   (`shown`): after `displayOrder`, `unreadFirst`
   (`wui/utils/unread-first.mjs:26-41`, SPL-2506) moves every card with
   unread to the edge new posts go to, the most unread at the very edge
   (`:38-40`). A card with 0 unread keeps the order step 1 gave it.

### 2.3 How a topic gets priority 3

- No `topic_priorities` row = the default (rdb `0214_topic_priorities.sql`;
  spec 150 v1.1 D7 moved it from 5 to 3). The hub reads
  `store.TopicPriorityDefault` (3) for an unset topic
  (`csi-spl-api/src/go/spool-hub-api/internal/hub/topic_priority.go:17`,
  `:203`), and omits the field on a list read when it is not set
  (`internal/hub/view.go:624`, `omitempty`).
- The WUI reads `undefined` as 3: `channel.priorityFor`
  (`wui/stores/channel.ts:756-758`) -> `topicPriority`
  (`wui/utils/topic-list-order.mjs:54-57`, `TOPIC_PRIORITY_DEFAULT = 3`
  at `:29`). A new topic therefore always starts at 3.

### 2.4 What happens today to a topic I just created

The new topic is a send with no `parentTaskId` (`wui/stores/channel.ts:540`,
`is_parent` 1 at `:547`); its card is drawn at once as a pending row
(`sendLive`, `:653-661`; the mock path `:575-578`). It is **my own**, so it
is never unread: `openerUnseen` returns false for the viewer's own message
(`wui/utils/read-cursor.mjs:187`, `isViewersOwn` in
`wui/utils/typed-by.mjs:60-66`), and its `cardNew.unseen` is 0.

| list state | where my new topic lands today (read from the code above; not yet run in Chrome) |
|---|---|
| All, Last update (defaults) | after every card with unread (step 2 moves them past it), then first among the read cards: **not at the edge** whenever any other card has unread |
| All, Priority | in the read group, after every read P1 and P2 card (`keyOf` `-priority`, `topic-list-order.mjs:68`): **sinks** |
| All, Number of messages | in the read group, after every read card with more messages: a 1-message topic **sinks to the far end** |
| New (any sort) | **vanishes**: `filter === 'new'` keeps only unread cards (`:100`), and my own card is never unread |

A new topic **from someone else** arriving live is unread (its opener
counts 1, `openerNew` in `wui/composables/useTopicCardNew.ts`), so step 2
already moves it to the edge, but behind any card with more unread
(`unread-first.mjs:38`), and under Priority behind every unread P1 / P2 card
(step 1).

### 2.5 Tests and help that cover the list today

- Unit: `tests/unit/topic-list-order.test.mjs`, `tests/unit/unread-first.test.mjs`.
- E2e: `tests/e2e/topic-list-control.test.mjs`.
- Help: no page describes the topic list's filter and sort
  (`grep -rniE "last update|most messages|topic list" csi-spl-wui/src/public/help-md/`
  -> only two `archive.md` lines about archiving); the i18n keys are
  `feed.topic_list.*` (`csi-spl-wui/i18n/locales/en.json:989-1001`).

## 3. The flow, end to end

1. I post a new topic in a channel (no parent task). The channel store
   records its `task_id` as **fresh** at the moment the pending row is drawn
   (D1). A topic from anyone else is never fresh.
2. Every redraw of the channel feed runs today's two steps (2.2), then a
   third: the fresh cards go to the very edge new posts go to (top for
   newest first, bottom for newest last), the newest fresh card outermost.
   The rest keep the order steps 1 and 2 gave them.
3. Under **New**, a fresh card is kept even though it is read (D3).
4. While pinned, the card shows a "new" badge (D4).
5. The pin ends when I leave the channel or reload the page (D2). The next
   time I open the channel the card takes its place by the chosen sort like
   any other.

The pin is view state only: no hub field, no rdb change, no change to the
topic's priority (it stays 3 until someone sets it).

### 3.1 Reused

- `newestLast` (`useViewPrefs.ts:20`) for the edge.
- `topicListView` and `unreadFirst` unchanged in what they already do; the
  pin is one more pure step after them.
- The pending-row path of `send` / `sendLive` as the moment a topic is born.
- The scroll anchor's own-send rule (`wui/utils/scroll-anchor.mjs`,
  `anchorAfterAppend` `own`) keeps a newest-last reader at the bottom where
  the card lands.

### 3.2 Gaps

- G1: no store keeps "topics born in this view"; the pending row is merged
  and forgotten (`channel.ts:661`).
- G2: `topicListView` has no way to keep a read card under **New**.
- G3: `unreadFirst` and `topicListView` both move cards; neither knows a
  card that must beat them. The pin has to run last, in `LiveFeed.vue`
  `shown` (`:304`), or the unread step moves other cards past it.
- G4: no help page describes the topic list's filter and sort (2.5).
- G5 (open, not measured): whether a newest-first reader scrolled down is
  brought to the top on their own new topic. Row B3 measures it in Chrome
  before it changes anything.

## 4. Build order (rows a later lane can take in parallel)

| row | what | files | depends on | done test | red control |
|---|---|---|---|---|---|
| B1 | pure pin step `pinEdge(rows, freshIds, {atEnd})` and a `keep` set for `topicListView` under New (D3) | `wui/utils/topic-list-order.mjs`, `wui/types/mjs-shims.d.ts`, `tests/unit/topic-list-order.test.mjs` | none | unit: C1..C4 of 7.1 on fixed rows, both orders, all 3 sorts x 2 filters | drop the pin step: the fresh P3 card under Priority is not at index 0 (newest first) / last (newest last) |
| B2 | the fresh set, per channel, filled on the viewer's own new-topic send (D1), cleared when the open channel changes (D2); a reload clears it by being in memory | `wui/stores/channel.ts` (or a new `wui/composables/useFreshTopics.ts` if a clean-code ceiling in `channel.ts` is hit) | none | unit: a send with no parent adds its `task_id`; a reply adds none; a live topic root from another sender adds none; switching to another channel empties it; opening a topic or changing sort / filter keeps it | send a reply: the set must stay empty; a test that expects it filled fails |
| B3 | wire B1 + B2 into the feed: `MessageFeed.vue` passes the fresh ids and the keep set; `LiveFeed.vue` `shown` runs `pinEdge` last, channel feed only (not a thread) | `wui/components/MessageFeed.vue`, `wui/components/LiveFeed.vue` | B1, B2 | e2e B5 | e2e B5 with B3 reverted is red |
| B4 | the "new" badge (D4) | `wui/components/MessageCard.vue`, `csi-spl-wui/i18n/locales/*.json` (key `feed.topic_list.pinned_new`) | B3 | e2e B5 sees `[data-test="topic-pinned-new"]` on the fresh card only | the badge on a non-fresh card fails B5 |
| B5 | e2e: create a topic in a mock channel that holds unread P1 cards, under each sort and both filters, in both message orders; the new card is first / last; it stays there after opening another topic and after changing the sort; after leaving the channel and coming back it sits by the sort, without the badge | `tests/e2e/topic-list-new-end.test.mjs` (new); mock rows in `wui/utils/spool-client-mock.mjs` only if the mock lacks a P1 unread card | B3 | `BASE_URL=<generated bundle> pnpm run test:e2e` green | run without B3: red on Priority and New |
| B6 | help: a "Topic list" section (filter, sort, the pin) in `message-levels-and-topics.md`; one line in `user-settings.md` 5.3 that the edge follows Message order | `csi-spl-wui/src/public/help-md/message-levels-and-topics.md`, `csi-spl-wui/src/public/help-md/user-settings.md` | B3 | the help text states each of C1..C4 | n/a (docs) |
| B7 | i18n: B4's key in every locale; agy reviews the text as the last step (language rule) | `csi-spl-wui/i18n/locales/*.json` | B4 | `tests/unit/i18n-parity.test.mjs`, `i18n-untranslated.test.mjs` green | a missing locale key: parity red |

B1 and B2 are independent; B3 joins them; B4..B7 follow B3. One WUI lane
can take B1..B5 as a unit; B6 and B7 are docs and i18n lanes.

## 5. Gates for the build

- `pnpm run typecheck`, the unit tests, and `BASE_URL=<generated bundle>
  pnpm run test:e2e` for B1..B5 (repo CLAUDE.md, cheap gate table).
- Clean-code limits (75 lines, depth 4, 5 params:
  `tests/unit/cleancode.test.mjs`); `pinEdge` takes an options object.
- No hub, rdb or terraform change: the pin is view state.

## 6. Language

B4's one string and B6's help text are user-facing. Per the language rule,
claude drafts, agy reviews last (`LANE_MIX_KIND=i18n`); the text waits for
that review and never ships unreviewed.

## 7. Contracts

### 7.1 Binding contracts

- **C1 the edge.** A fresh card is drawn at the very edge new posts go to:
  index 0 of the drawn rows for **Newest first**, the last index for
  **Newest last** (`newestLast`). It beats the unread edge (SPL-2506): every
  card with unread sits next to it, on the inner side.
- **C2 sort and priority do not move it.** Under every sort in
  `TOPIC_LIST_SORTS` (`last`, `messages`, `priority`) the fresh card's place
  is C1, whatever its priority (3 by default) and message count. The other
  cards keep exactly the order they have today (steps 1 and 2 of 2.2), so a
  list with no fresh card is unchanged.
- **C3 the filter.** Under **New** a fresh card is kept although it is
  read (D3), so C1 holds under both filters.
- **C4 several fresh cards.** They form the outer group in send order, the
  newest outermost (index 0 / last).
- **C5 whose.** Only a topic the viewer created in this tab (a send with no
  parent task) is fresh (D1). A new topic root from anyone else, live or on a
  loaded page, is never fresh; it keeps today's unread edge (SPL-2506).
- **C6 how long.** The fresh set is per tab, in memory, never stored (no
  localStorage, no hub field). It ends when the open channel changes (any
  route that is not this channel's feed or one of its topics) or on a reload
  (D2). Opening a topic of the same channel, changing the sort or the
  filter, and elapsed time keep it.
- **C7 the badge.** (D4) The card carries
  `data-test="topic-pinned-new"` and the text of key
  `feed.topic_list.pinned_new` while it is fresh, and loses both when the
  pin ends.
- **C8 scope.** Only a channel's topic list (the middle pane,
  `MessageFeed.vue`). A thread's replies, the sidebar, DMs and Issues are
  unchanged.

### 7.2 Not in this spec

- No change to the default priority 3, the sorts, the filters or the unread
  edge rule themselves.
- No per-account setting for the pin: it follows Message order.

## 8. Review

v0.1 was for the owner's form (section 1). v0.2 folded the four answers
(1.1, D1..D4) and dropped the losing branch of each question.

Spec review of v0.2 `3cfb45fd6`: **PASS** by m-717 (`mistral`, brief
`c002-s189-v02-mistral-spec-reviewer`, spool msg `cee8494f`), no blocker;
it re-measured every cited line on `origin/master` `a83052abd` (none of the
18 cited files moved since `974d97031`). Its notes: N1 the 1.1 table
lowercased the answers, N2 the spec-number line missed this lane's own
worktree (both fixed in v1.0), N3 `c-002@sat` passes the hygiene gate (no
change). GO to land: the dispatch holder c-002@sat, spool msgs `83a3d4b3`
and `202b36a2`.

| version | change |
|---|---|
| v0.1 | the ask, what exists, the flow, build rows, contracts, the owner form |
| v0.2 | owner answers OWN / RLD / YES / BDG folded: 1.1, 1.2 D1..D4; section 3; rows B2, B4, B5; C3, C5, C6, C7 |
| v1.0 | review PASS recorded; N1 answers verbatim in 1.1; N2 spec-number line names this lane's own worktree |
