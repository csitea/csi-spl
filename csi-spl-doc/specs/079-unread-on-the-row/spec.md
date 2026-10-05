# 079: one unread model, shown on the row

**Feature ID**: `079-unread-on-the-row` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-04 · **Lane**: c-245 (spec only) · **Topic**: 3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[062 flow per-user counts](../062-flow-per-user-counts/spec.md) (the hub's Flow counts and row keys; FR-005 badge meaning),
[005 verbosity + notify contract](../005-spool-wui/contracts/verbosity-notify-v1.md) (read cursors),
[078 desktop layout](../078-desktop-wide-thread-layout/spec.md) (Topics rows move to one list).

Evidence base: `../../doc/md/desktop-usability-consensus-20261005.md` L3 (agreed by c-245 and g-248), `../../doc/md/desktop-usability-grok-view-20261005.md` A6.

**Running lane first: c-253** (topic new/total) restores the vanished `<new>/<total>` on topic cards. This spec does not repeat that fix; it unifies the sources once c-253 has landed (tasks Phase 1 waits for it).

---

## 1. Why, and the owner's ask

Owner go: ea6330ff (spec, then build). Owner posts, verbatim (relayed by c-002, msg 7f75f5e5):

- `92c4b3e8`: "the feature fpor showing how many new msgs our of total msgs in a topic iin the first topic msg has disappeared"
- `da315c54`: "both in the channel view and in the topics view and in the flows view"

## 2. Today, measured

| # | fact | evidence |
|---|---|---|
| 1 | The tab title is the hub's Flow total (unseen + unread), not a sum of rows: `flowBadge >= 0 ? flowBadge : unreadTotal(...)` | `src/app.vue:71-75`, `src/stores/flow.ts:163-177`, `src/utils/flow-badge.mjs:48` |
| 2 | Sidebar rows read the hub's row keys (`ch:`, `dm:`, `t:`) via `rowUnread` / `sectionTotal`; the rail falls back to `railFromUnread` when keys are absent | `src/utils/flow-keys.mjs:22,36`, `src/components/ChannelSidebar.vue:1000-1033,455` |
| 3 | DM badges also come from a second store: `notification.unread`, `dmTotal`, `dmBadge` | `src/stores/notification.ts:77-79,359-399` |
| 4 | A topic card's `<new>/<total>` is computed locally (`channel.unreadFor` = replies − seen, from `t:` cursors), not from the hub keys | `src/stores/channel.ts:499-502`, `src/components/MessageCard.vue:150,573`, `src/components/LiveFeed.vue:87` |
| 5 | The Topics middle list has no unread at all | `grep -c unread src/pages/index.vue` -> 0 |
| 6 | g-248 walk (mock, n=1, fresh profile): title `(1)`, DM rail `1`, Flow rail `1`, yet the Topics row holding that item had no mark and 0 channel/topic marks anywhere | grok view A6 |
| 7 | c-245 walk (mock, n=1): opening the item cleared title, DM rail and Flow rail together | ideas doc T2 |

So five places compute "unread" from three inputs (hub Flow counts, hub row keys, local cursors), and the list a person scans is the one that may show nothing.

## 3. The design

### 3.1 One model

One pure function, `unreadModel(inputs)`, turns the inputs (hub row keys when present, else local cursors + channel/DM unread from the hub) into a map `place key -> n` (`ch:<name>`, `dm:<peer>`, `t:<task_id>`) and the sums per section. One composable, `useUnread()`, holds it reactively. Every surface reads from it; none computes its own.

### 3.2 The row wears the number

Every row that can hold unread shows its own number: channel and DM rows (as today), **topic rows in the Topics list** (sidebar and, until 078 Phase 2 ships, the middle list), and the topic card's `<new>/<total>` (whose `<new>` stays the local `t:` cursor count, FR-005).

### 3.3 The title is the sum of the rows

The tab title shows `(<n>)` where n is the sum of the row numbers the person can see (muted channels excluded, as `unreadTotal` does today). It no longer shows the Flow total.

### 3.4 Flow keeps its own meaning, with its own name

The Flow rail badge keeps 062 FR-005's meaning (unseen + unread, cleared when Flow opens). Its tooltip and `aria-label` say "new in Flow", and it keeps the theme-grey colour, so it is not read as a second unread total.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member | See on the topic row itself how many messages I have not read | the row that opens the unread item is marked (A6) |
| **US2** | **P1** | Member | Trust that the title, the rail and the rows give the same total | owner 92c4b3e8, da315c54 |
| **US3** | **P2** | Member | Tell Flow's "new" from the unread total at a glance | no second, competing number |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | A pure `unreadModel` returns `place -> n` and section sums from hub row keys when present, else from local cursors and the hub channel/DM unread | Planned |
| **FR-002** | A composable `useUnread()` is the only reader of those inputs in components and pages | Planned |
| **FR-003** | Channel, DM and topic rows in the sidebar show the model's number for their key | Planned |
| **FR-004** | Topic rows in the Topics middle list show it too (until 078 Phase 2 removes that list) | Planned |
| **FR-005** | A topic card's `<new>` keeps the local `t:` cursor count (`channel.unreadFor`), not the model's `t:` row: the hub `keys` let a `ch:` mark cover a topic's replies (062 FR-006), so opening the channel would zero the card and undo CLE-77930 (owner, t1 bf737f3f) | Done (T006) |
| **FR-006** | The tab title's `(n)` is the sum of visible row numbers, muted excluded | Planned |
| **FR-007** | The rail section badges are the section sums from the same model | Planned |
| **FR-008** | The Flow badge keeps 062 FR-005's number; its label says "new in Flow" in all 19 locales | Planned |
| **FR-009** | Reading a message lowers every surface in the same reactive tick | Planned |
| **FR-010** | Help `channels-and-direct-messages.md` and `interface-overview.md` §3.1 describe one number per row and the title as their sum | Planned |

## 6. Acceptance scenarios

| # | Check / test | Proves |
|---|---|---|
| **AC1** | unit (`unread-model`): for a fixed input with 2 unread in `t:A`, 1 in `dm:B`, 3 in muted `ch:C` -> rows A=2, B=1, C=3; title sum 3; channels section 3 (muted shown on its row, left out of the title) | FR-001, FR-006, FR-007 |
| **AC2** | unit: the same input given as hub keys and as local cursors yields the same map | FR-001 |
| **AC3** | unit (grep gate in the test): no file under `src/components` or `src/pages` imports `flow-keys.mjs`, `tab-title.mjs` `unreadTotal`, or `channel.unreadFor` directly; only `useUnread` does | FR-002 |
| **AC4** | e2e, mock, 1440: with one unread reply in a topic, the sidebar Topics row and the middle Topics row show `1`, the card shows `1/<total>`, and the title is `(1)` | FR-003..006 |
| **AC5** | e2e: open that topic -> row, card, rail and title all drop to 0 before the next frame is checked (one `requestAnimationFrame`) | FR-009 |
| **AC6** | e2e: the Flow rail badge's `aria-label` reads "new in Flow" (en) | FR-008 |
| **AC7** | existing e2e `unread-sum`, `topic-unread-count`, `channel-thread-unread`, `dm-badge-total`, `unread-drops-on-read` stay green (updated only where the title rule changes) | no regression |

## 7. Overlaps

| with | how |
|---|---|
| **c-253** (topic new/total, running) | restores `<new>/<total>` on cards. Phase 1 here starts after c-253 lands and rebases on it; its `<new>` stays on the local `t:` cursor (FR-005, CLE-77930) |
| 062 | the hub's counts and keys are inputs, unchanged; no hub change in this spec |
| 078 Phase 2 | removes the Topics middle list; FR-004 then has nothing to mark. Whichever lands second drops or keeps FR-004 accordingly |
| next-unread spec (consensus L8) | reads `useUnread()` for its target; build after this |

## 8. Not in scope

New hub counters or endpoints. Changing what Flow counts (062). Mobile-only presentation (the phone uses the same model and gets the same numbers; also mobile).

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Title = sum of rows, or keep the Flow total? | **Sum of rows** (consensus L3): the number in the title should match the rows a person can click |
| **Q2** | Do muted channels count in the title? | **No**, as `unreadTotal` does today; they still show their own row number |
| **Q3** | When hub keys and local cursors disagree, which wins? | **Hub keys**, then advance the local cursor to match; local cursors are only the offline / no-keys fallback |
| **Q4** | Should the Flow badge simply become the same sum? | **No**: 062 FR-005 gave it a meaning (unseen + unread, cleared on open) the owner accepted; rename it rather than redefine it |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the consensus (L3): one model, row numbers, title = row sum, Flow labelled | c-245 |

<!-- version: 0.1.1 · updated: 2026-10-05 · last-edit: 2026-10-05T02:50:31Z -->
