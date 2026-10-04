# 083: next unread

**Feature ID**: `083-next-unread` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-04 · **Lane**: c-245 (spec only) · **Topic**: 3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[079 unread on the row](../079-unread-on-the-row/spec.md) (`useUnread()`: the numbers this spec walks),
[081 command palette and pane keys](../081-command-palette-and-pane-keys/spec.md) (`useGlobalKeys`, the overlay's Global group),
[005 verbosity + notify contract](../005-spool-wui/contracts/verbosity-notify-v1.md) (read cursors).

Evidence base: `../../doc/md/desktop-usability-consensus-20261005.md` L8 (agreed by c-245 and g-248, **after L3** = spec 079); ideas doc §3.5, T2; grok view part B #2.

---

## 1. Why, and the owner's ask

Owner go: ea6330ff (starter #2 "Jump to the first unread" is in the pick). Both walks said *change*: the in-feed part is built, the across-places part is missing.

## 2. Today, measured

| # | fact | evidence |
|---|---|---|
| 1 | Inside one feed, a "New messages" divider and an off-screen jump button already exist (`new-divider`, `unread-jump` -> `jumpToUnread()`); the jump stays in the current feed and is hidden on a phone | `src/components/LiveFeed.vue:19,46-52,112,263-264,284-297,310,377` |
| 2 | To reach unread in another place: Flow rail, then the row, then back to Flow for the next one: 2 clicks per item | ideas doc T2 (mock, 1440, n=1) |
| 3 | No key and no button goes to the next place with unread | `grep -rniE 'next.?unread' src \| wc -l` -> 0 |
| 4 | There is no ordered list of unread places; it has to be built from the counts | code read: `stores/channel.ts:72`, `stores/flow.ts`, `utils/flow-keys.mjs:36` |
| 5 | Opening a message in its place is one call: `useOpenMessage().openMessage(ref, opts)`; channels and DMs open by route | `src/composables/useOpenMessage.ts:47`, `src/utils/topic-open.mjs` |
| 6 | In g-248's five-topic fixture there was nowhere to jump inside a thread (every card on screen) | grok view part B #2 |

## 3. The design

### 3.1 The order

The unread places, from `useUnread()` (079), in the order a person sees them in the left pane: channels in their sidebar order, then DMs in their order, then topics that hold unread replies but sit outside an unread channel (newest activity first). Muted channels are skipped.

### 3.2 The key

`Alt+Shift+↓` goes to the next place in that order after the current one, wrapping once; `Alt+Shift+↑` goes to the previous one. Arriving opens the place with the feed scrolled to its "New messages" divider (the existing `firstUnreadId`), and the normal reading rules mark it read. When nothing is unread, the key shows a short "All caught up" toast and goes nowhere.

### 3.3 The button

The feed header (`FeedHeader.vue`) shows **Next unread · N** when N > 0 places other than the current one hold unread. A click does what `Alt+Shift+↓` does. At N = 0 the button is not shown.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member coming back after an hour | Press one key repeatedly to read everything new, place by place, each time at the divider | no trips back to Flow |
| **US2** | **P1** | Mouse user | Click **Next unread** in the header and see how many places are left | the same, without keys |
| **US3** | **P2** | Member | Be told when I am caught up | closure |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | A pure `unreadOrder(rows, sidebar)` returns the unread places in left-pane order (channels, DMs, then topics outside an unread channel), muted skipped | Planned |
| **FR-002** | `Alt+Shift+↓` / `↑` open the next / previous place after the current one, wrapping once | Planned |
| **FR-003** | Arriving scrolls the feed to the "New messages" divider; reading marks it read as today | Planned |
| **FR-004** | With nothing unread the key shows "All caught up" and does not navigate | Planned |
| **FR-005** | `FeedHeader` shows **Next unread · N** (N = other places with unread) when N > 0; a click equals FR-002 | Planned |
| **FR-006** | The key is listed in the overlay's Global group (081) and works on desktop only; the button also on a phone (also mobile) | Planned |

## 6. Acceptance scenarios

| # | Check / test | Proves |
|---|---|---|
| **AC1** | unit (`next-unread`): rows `{ch:alerts:2, ch:lobby:0, dm:HUM-3:1, t:X:4 (in #lobby), ch:muted:5 (muted)}`, sidebar order alerts, lobby, muted, then HUM-3 -> order `ch:alerts`, `dm:HUM-3`, `t:X`; from `ch:alerts`, next is `dm:HUM-3`, previous wraps to `t:X` | FR-001, FR-002 |
| **AC2** | e2e, mock, 1440: with unread in `#alerts` and a DM, on `/lobby`, press `Alt+Shift+↓` -> URL `/channel/alerts`, the `new-divider` is within the viewport; again -> the DM | FR-002, FR-003 |
| **AC3** | e2e: after reading everything, `Alt+Shift+↓` -> toast "All caught up", URL unchanged | FR-004 |
| **AC4** | e2e: on `/lobby` with 2 other unread places, the header shows `Next unread · 2`; click -> same as AC2 | FR-005 |
| **AC5** | unit: the overlay's Global group contains the key (081 table) | FR-006 |
| **AC6** | existing `unread-divider`, `thread-jump` suites stay green | no regression |

## 7. Overlaps

| with | how |
|---|---|
| **079** | provides `useUnread()`; this spec starts after 079 Phase 2 |
| **081** | provides `useGlobalKeys` and the overlay table; this spec adds one key to each |
| LiveFeed's in-feed jump | unchanged; this spec moves between places, the existing button moves inside one |
| c-246 mobile list | the button is also mobile; the key is desktop only |

## 8. Not in scope

A separate "All unreads" view (Slack). Marking read without opening. Changing what counts as unread (079, 062).

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Order: left-pane order, or newest activity first? | **Left-pane order**: predictable, and the same order the person reads the badges in (Slack does the same) |
| **Q2** | Which key? | **`Alt+Shift+↓` / `↑`** (Slack's): no clash with text editing, the browser or the existing `j/k` and Shift letters |
| **Q3** | Open a topic with unread replies in the right pane or as its channel? | **In its channel with the topic open on the right**: the same place an id link opens (help `omnibox-and-navigation.md` §8) |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the consensus (L8): unread order, `Alt+Shift+↓/↑`, header button, caught-up toast | c-245 |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T22:55:00Z -->
