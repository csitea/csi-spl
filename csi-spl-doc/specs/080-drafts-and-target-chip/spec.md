# 080: drafts per place, and a composer chip that names the target

**Feature ID**: `080-drafts-and-target-chip` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-04 · **Lane**: c-245 (spec only) · **Topic**: 3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[022 top-bar search](../022-spool-wui-top-bar-search/spec.md) (the omnibox and its search mode),
[033 message levels](../033-spool-message-levels/spec.md) (pane-focus routing: where a send goes),
[078 desktop layout](../078-desktop-wide-thread-layout/spec.md).

Evidence base: `../../doc/md/desktop-usability-consensus-20261005.md` L4 (agreed by c-245 and g-248), `../../doc/md/desktop-usability-ideas-20261004.md` §3.3 (T10), `../../doc/md/desktop-usability-grok-view-20261005.md` A3, A4, and the mobile list `../../doc/md/mobile-usability-ideas-20261004.md` §3.3 (drafts + offline send queue; **also mobile**).

---

## 1. Why, and the owner's ask

Owner go: ea6330ff (starter #7 "Drafts that survive" is in the pick). DoD: ready specs (44ff08f3). Both walks found the two ways a reply goes wrong: the text is lost, or it goes to the wrong place.

## 2. Today, measured

| # | fact | evidence |
|---|---|---|
| 1 | A draft typed in `#feedback` is still in the box after a sidebar click to `#alerts`: one Enter posts it to the wrong channel | c-245 T10 (mock, 1440, n=1) |
| 2 | A full reload empties the box (`""`), in a channel and in a topic reply | c-245 T10; g-248 A4 (n=1 each) |
| 3 | One composer serves every place: `TopBar.vue` mounts it once (Teleport to the bottom dock when that position is set); its text is `const text = ref('')` | `src/components/TopBar.vue:47-82`, `src/components/MessageComposer.vue:375` |
| 4 | No draft persistence exists | `grep -ciE 'draft\|localStorage' src/components/MessageComposer.vue` -> 0 for storage |
| 5 | The only name of the destination is the placeholder, which typing erases; the `.composer-target` line renders only with the box at the bottom, not docked, not searching, and with a page `dock()` hint, so with the default top position it is never shown | `MessageComposer.vue:24-33`, `src/utils/omnibox-dock.mjs:13` (`DEFAULT_POSITION='top'`); g-248 A3: empty in every view |
| 6 | Where a send goes is decided per page: `useOmniboxTarget({placeholder, send, dock})`, and on `/` by `omniboxReplyTaskId` with pane focus | `src/stores/omnibox.ts:8-40`, `src/utils/omnibox-topic.mjs:59,83,119,136`, `src/utils/pane-focus.mjs:88` |
| 7 | Browser keys are flat `spool.<name>`; tenants are kept apart by origin, users are not | `src/utils/prefs.mjs:13-54`, `src/utils/tenant-host-core.mjs` |
| 8 | Sign-out (`logout()`) clears only the card-clip session | `src/stores/session.ts:182-196` |
| 9 | A send that fails is resent once with the same `msg_id` (hub de-dupes); the TopBar Retry sends again with a **new** `msg_id` | `src/stores/channel.ts:403-462`, `src/components/TopBar.vue:177-194` |

## 3. The design

### 3.1 One draft per place

A **place** is where a send would go: a channel (`ch:<name>`), a DM (`dm:<peer>`), a topic reply (`t:<task_id>`), or a new topic in a channel (`new:<channel>`, the same as `ch:`). When the target changes, the composer saves the current text under the old place and loads the new place's text. Typing saves (debounced 300 ms). A successful send clears that place's draft. Esc in an empty box does nothing new.

Drafts are kept in the browser (`spool.drafts`), per signed-in member: `{<human_id>: {<place>: {text, ts}}}`. Attachments are not stored (Q2). Old drafts are pruned: more than 30 days, or beyond the newest 50.

### 3.2 A mark where a draft waits

A channel or DM row with a draft shows a pencil mark; a topic card or Topics row with a reply draft shows the same mark. Tooltip: "Draft".

### 3.3 The target chip

While the box holds text, a chip at its start names the destination, in both omnibox positions: `#feedback`, `@HUM-3`, `Reply · <topic title>`, or `New topic · #lobby`. It updates live when the pane focus changes the target. In search mode it is hidden. The placeholder goes back to being a hint. The chip text comes from the same target that `send` uses, so it cannot name one place while the send goes to another.

### 3.4 Wipe on sign-out

`logout()` removes the member's drafts. A second member signing in on the same browser never sees the first one's drafts (keyed by human id).

### 3.5 Phase 3, also mobile: send when back online

From the mobile list §3.3. A send that fails for network reasons stays as a pending row marked "waiting for network" and is resent with the **same** `msg_id` when the socket reconnects, so the hub's de-dupe makes a replay safe; nothing is silently lost. TopBar's Retry reuses that `msg_id` too.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member | Start a reply, look at another channel, come back and find my text | no lost work |
| **US2** | **P1** | Member | Never post a draft written for `#feedback` into `#alerts` by accident | no wrong-channel sends |
| **US3** | **P1** | Member | See where Enter will send while I type | g-248 A3 |
| **US4** | **P2** | Member | Reload or reopen the browser and keep my drafts | survives a crash or an update reload |
| **US5** | **P2** | Member on a train (also mobile) | Write without signal and have it send when the network is back | mobile §3.3 |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | The composer keeps one draft per place (`ch:`, `dm:`, `t:`); a target change saves the old and loads the new | Planned |
| **FR-002** | Drafts persist in `spool.drafts`, keyed by human id then place, saved within 300 ms of typing | Planned |
| **FR-003** | A successful send clears that place's draft; a failed send keeps it | Planned |
| **FR-004** | Drafts older than 30 days, or beyond the newest 50, are pruned on load | Planned |
| **FR-005** | Rows and topic cards with a draft show a pencil mark | Planned |
| **FR-006** | While the box has text and is not in search mode, a chip names the destination, in top and bottom positions | Planned |
| **FR-007** | The chip and `send` read one target value | Planned |
| **FR-008** | `logout()` deletes the member's drafts | Planned |
| **FR-009** | (Phase 3, also mobile) a network-failed send is kept as pending and resent with the same `msg_id` on reconnect; Retry reuses the `msg_id` | Planned |
| **FR-010** | Help `omnibox-and-navigation.md` gains a "Drafts and the target chip" section | Planned |

## 6. Acceptance scenarios

| # | Check / test | Proves |
|---|---|---|
| **AC1** | e2e, mock, 1440: type `abc` on `#feedback`, click `#alerts` -> box is empty; click `#feedback` -> box is `abc` | FR-001 |
| **AC2** | e2e: type `abc` on `#feedback`, reload -> `abc`; open a topic, type `xyz`, reload with `?topic=` -> `xyz` | FR-002 |
| **AC3** | e2e: send from `#feedback` -> box empty, reload -> still empty, the `#feedback` row has no pencil | FR-003, FR-005 |
| **AC4** | unit (`drafts`): prune drops a 31-day-old entry and the 51st oldest; keys by human id | FR-002, FR-004 |
| **AC5** | e2e: with text on `#lobby` the chip reads `#lobby`; click a topic card (right pane takes focus) -> chip reads `Reply · <title>`; click the middle pane -> `New topic · #lobby`; type `/search x` -> no chip | FR-006, FR-007 |
| **AC6** | unit (`omnibox-topic`): the chip label function and the send target agree for every case in the existing target table | FR-007 |
| **AC7** | e2e: draft on `#feedback`, sign out -> `localStorage['spool.drafts']` has no entry for that human | FR-008 |
| **AC8** | e2e (Phase 3): set the page offline (CDP `Network.emulateNetworkConditions`), send `q` -> row shows "waiting for network"; go online -> exactly one message `q` arrives (same `msg_id`) | FR-009 |

## 7. Overlaps

| with | how |
|---|---|
| c-246 mobile list §3.3 | the same idea; this one spec covers both (Phase 3 is the offline queue). No second spec |
| 079 (unread on the row) | both add marks to the same rows: put the pencil and the number in one row slot; whichever lands second rebases |
| 078 Phase 2 | the Topics middle list may go away; then FR-005's topic mark lives on the sidebar row and the card only |
| 022 search mode | the chip hides in search mode; search behaviour unchanged |

## 8. Not in scope

Server-side drafts (synced across devices): Q1. A "Drafts" list view. Attachments in drafts (Q2). Editing of sent messages (032).

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Browser only, or drafts on the hub so they follow you between devices? | **Browser only** now: no migration, no new data on the hub; revisit if the owner wants cross-device drafts |
| **Q2** | Keep attachments in a draft? | **No**: files can be large and the browser cannot store `File` objects reliably across reloads; the text is kept and the chip row says "attachment not kept" if one was dropped |
| **Q3** | Does a chip click do anything? | **Yes: it opens the target** (scrolls to the channel or the topic), so you can check where you are sending; no menu |
| **Q4** | Offline queue (Phase 3) now or later? | **After Phases 1-2**, as its own lane: it touches the send path in `stores/channel.ts` and needs the CDP offline e2e |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the consensus (L4): per-place drafts, draft marks, target chip, wipe on sign-out, offline send queue (also mobile) | c-245 |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T22:20:00Z -->
