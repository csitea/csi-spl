# 088: drafts on a phone (080's draft model, made to survive the phone)

**Feature ID**: `088-phone-drafts` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-05 · **Lane**: c-246 (spec only) · **Topic**: c893c3a9-b31e-45ca-a61b-fc8260f2d800
**Authority**: this file for the phone behaviour; **`../080-drafts-and-target-chip/spec.md` for the draft model**; `tasks.md` for what is built. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

**One draft model.** This spec adds no store, no key and no format. It uses 080's `spool.drafts` (`{<human_id>: {<place>: {text, ts}}}`), its places (`ch:`, `dm:`, `t:`), its prune, its sign-out wipe and its Phase 3 offline queue (080 FR-009, T006). It only adds what a phone needs on top: saving before the OS freezes the tab, coming back after the OS threw the tab away, and the checks at phone size.

Builds on: [080](../080-drafts-and-target-chip/spec.md) (the model), [043](../043-spool-wui-mobile/spec.md) (the docked composer, the stack), [087](../087-phone-back-and-resume/spec.md) (reopen where you left off).

Evidence base: `../../doc/md/mobile-usability-consensus-20261005.md` D3 and build item 5, `../../doc/md/mobile-usability-ideas-20261004.md` §3.3.

---

## 1. Why, and the owner's ask

Owner: "ideas for specs to improve the ui usability for mobile" (prd t1 `c893c3a9`, msg `cb3a56c0`); DoD "the ready specs to implement" (`44ff08f3`); 080's own owner go: ea6330ff ("Drafts that survive"). The consensus disputed drafts (g-249: no evidence) until a measurement settled it (row 1 below).

## 2. Today, measured

| # | fact | evidence |
|---|---|---|
| 1 | On a phone, `half-written reply` typed in `#lobby` was **still in the box in `#feedback`** after Back and a tap on `#feedback`, ready to post there; back in `#lobby` it was there too; after a reload the box was empty | c-246, mock, 390x844, touch, tree `7289ef28`, n = 1 (consensus D3) |
| 2 | The phone dock is the same `MessageComposer` instance as the desktop omnibox (TopBar mounts it once and teleports it to the dock), so 080's per-place drafts apply to the phone without a second composer | `src/components/TopBar.vue:33-60`; 080 §2 row 3 |
| 3 | 080 saves a draft 300 ms after typing (debounced). A phone freezes a page as soon as the user switches app or locks the screen, and may discard it later without any further event; text typed in those last 300 ms is lost | 080 FR-002; Page Lifecycle: `visibilitychange` / `pagehide` are the last events a phone page reliably gets |
| 4 | On a phone, changing place is mostly Back (chevron, dock Back, swipe) and taps on level-1 rows, not the desktop sidebar clicks 080's AC1 uses | 043 N3; `dock-buttons.test.mjs` header |
| 5 | Nothing reacts to an OS-discarded tab coming back (`document.wasDiscarded`): it is a cold start at its last URL | `grep -rc wasDiscarded csi-spl-wui/src` -> 0 |

## 3. The design

1. **Save before the freeze.** On `visibilitychange` to `hidden` and on `pagehide`, the current box text is written to 080's store at once (no debounce). The same flush runs when the docked composer loses focus because a level changes (Back, swipe, a row tap).
2. **Every phone way of leaving a place saves it.** Back by the chevron, the dock Back, the edge swipe and browser Back each go through 080's place change (the target changes, the old text is saved, the new place's text loads). No phone-only code path skips it.
3. **Come back after a discard.** A tab the OS discarded reloads at its last URL. With 080 the box then loads that place's draft; with 087 a cold start at `/` reopens the last place, whose draft loads the same way. No extra store.
4. **The draft mark at phone size.** 080's pencil on rows and topic cards is visible on the level-1 lists and on the phone card header (086 line 2), at least 12 px, with its "Draft" name for screen readers.
5. **The offline queue on a phone.** 080 Phase 3 (T006) is the queue. On a phone it must also hold when the page is hidden while a send waits for the network, and when the page was discarded and reloaded: the pending send is either resent once with its `msg_id` or put back in the box as that place's draft, never silently dropped.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member on a phone | Switch to another app mid-reply and find my text when I come back, even if the phone closed the tab | no lost work |
| **US2** | **P1** | Member on a phone | Go Back from a channel with a half-written reply and not carry it into the next channel | no wrong-channel posts |
| **US3** | **P2** | Member on a phone | See on the list which channels hold a draft | finish what I started |
| **US4** | **P2** | Member on a train | Press Send in a tunnel, lock the phone, and have the message go out once when the signal is back | 080 US5 on a phone |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | On `visibilitychange` -> `hidden` and on `pagehide`, the box text is saved to 080's store for the current place immediately (no debounce) | Planned |
| **FR-002** | A level change on a phone (chevron, dock Back, edge swipe, browser Back, a row tap) saves the old place's text and loads the new place's, through 080's place change | Planned |
| **FR-003** | After a reload or an OS discard at a place's URL, the box holds that place's draft; after 087's restore at `/`, the restored place's draft | Planned |
| **FR-004** | 080's draft mark is shown on phone level-1 rows and on the phone card header, >= 12 px, named "Draft" | Planned |
| **FR-005** | With 080 Phase 3: a send pending when the page is hidden or discarded is resent once with its `msg_id` on return, or restored as the place's draft; it is never dropped | Planned |
| **FR-006** | No second store, key or format: every read and write goes through 080's `src/utils/drafts.mjs` | Planned |

## 6. Acceptance scenarios

All e2e against a generated mock bundle with a signed-in mock session, touch on, at 360x780 and 390x844.

| # | Check / test | Proves |
|---|---|---|
| **AC1** | `#lobby`: type `abc`, chevron Back, tap `#feedback` -> box empty; Back, tap `#lobby` -> `abc` (today: `abc` shows in `#feedback`). Repeat with the dock Back and with an edge swipe | FR-002 |
| **AC2** | `#lobby`: type `abc` and, within 50 ms of the last key, dispatch `visibilitychange` (hidden) -> `localStorage['spool.drafts']` holds `abc` for `ch:lobby` | FR-001 |
| **AC3** | `#lobby`: type `abc`, wait 400 ms, reload -> `abc`; open a topic, type `xyz`, reload -> `xyz` | FR-003 |
| **AC4** | with 087 built: draft `abc` on `#feedback`, close the page, open `/` -> 087 restores `#feedback` and the box reads `abc` | FR-003 |
| **AC5** | a draft on `#feedback`: at level 1 its row shows the pencil (>= 12 px, accessible name "Draft"); a topic reply draft shows the pencil on that card | FR-004 |
| **AC6** | with 080 T006 built: CDP offline, send `q` on `#lobby`, dispatch `visibilitychange` hidden then visible, go online -> exactly one `q` arrives; a second run reloads the page while offline -> `q` is back in the box as the `#lobby` draft or arrives once, never neither | FR-005 |
| **AC7** | `grep -rn "localStorage\|storageSetJson" src/components/MessageComposer.vue src/plugins/drafts-flush.client.ts` shows only calls into `src/utils/drafts.mjs` (no own key) | FR-006 |

## 7. Overlaps

| with | how |
|---|---|
| **080 (c-245)** | **the model**. 088 tasks start after 080 T003 (drafts wired) and, for AC6, after 080 T006 (the queue). 088 adds only a `flushDraft()` export to `drafts.mjs` and the phone listeners |
| 087 (resume) | AC4 needs 087 T004; without it AC4 is skipped, not failed |
| 086 (card header) | the pencil sits on line 2 of the phone header |
| 085 (phone composer) | the chip names the place whose draft is in the box; no shared code beyond 080's target |
| c-245's desktop list §3.3 | merged into 080; this is its phone half, as c-001 asked (one model) |

## 8. Not in scope

Drafts on the hub (080 Q1: browser only). Attachments in drafts (080 Q2). A drafts list screen.

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Extend 080 or write a separate phone spec? | **A separate, small spec that references 080**: `specs/README.md` §2 rule 5 ("Edit only your own `specs/NNN-*/**`") keeps 080 in c-245's hands; this file adds no model, only phone behaviour (FR-006) |
| **Q2** | Flush on every keystroke on a phone instead of on hide? | **No**: 080's 300 ms debounce plus the hide/pagehide flush covers the freeze without a storage write per key on a slow phone |
| **Q3** | When a pending offline send meets a reload, resend it or put it back in the box? | **Back in the box when the network is still down after the reload, resend once (same `msg_id`) when it is up**: the reader sees the text either way and the hub de-dupes the race |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the mobile consensus, build item 5, on 080's one draft model | c-246 |

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T01:10:00Z -->
