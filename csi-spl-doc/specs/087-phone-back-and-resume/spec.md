# 087: on a phone, Back is always one level, and the app reopens where you left off

**Feature ID**: `087-phone-back-and-resume` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-05 · **Lane**: c-246 (spec only) · **Topic**: c893c3a9-b31e-45ca-a61b-fc8260f2d800
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[043 the WUI on phones](../043-spool-wui-mobile/spec.md) (N1-N5 the three-level stack, T005 the swipe, T055 overlays as stack steps).

Evidence base: `../../doc/md/mobile-usability-consensus-20261005.md` D7, U1 and build item 4,
`../../doc/md/mobile-usability-ideas-20261004.md` §1.1 task 9, §3.4, `../../doc/md/mobile-usability-grok-view-20261005.md` A7, A8.

---

## 1. Why, and the owner's ask

Owner: "ideas for specs to improve the ui usability for mobile" (prd t1 `c893c3a9`, msg `cb3a56c0`); DoD "the ready specs to implement" (`44ff08f3`). Back has failed the owner before: c78fb3ec, "the back button on both the bottom and top bars does not work ... one has to close the app" (`src/utils/mobile-stack.mjs:60-66`). The consensus joins two items that live in the same code (`useMobileStack`): a Back that never leaves the level structure, and a reopen that rebuilds it.

## 2. Today, measured

Mock bundle, tree `7289ef28` (c-246) and g-249's pass, touch, n = 1 per row.

| # | fact | evidence |
|---|---|---|
| 1 | Reopening the app at `/` (the manifest `start_url`, the home-screen icon) after `/channel/feedback` lands on **level 1, Messages tab**: the place is lost; getting back costs 2 taps (channel) or 3 (topic) | c-246 ideas §1.1 task 9 |
| 2 | **Browser Back from level 1 after a visit to `/login` shows the sign-in page while signed in**: "Sign-in is unavailable right now. Signed in as HUM-1 · Continue to topics · Sign out" | c-246, 360x780, `/login` -> `/` -> Back (`w10-back-to-login-360.png`); g-249 A7/A8 saw the same screen after an edge swipe |
| 3 | g-249: an edge swipe from x = 8 at level 3 went to level 1 at 360 (skipping the channel) | g-249 A8, n = 1 |
| 4 | c-246 could **not** reproduce row 3: an edge swipe (x = 8) and a swipe from x = 100 each went 3 -> 2 at 360 and 390 on the tap path (Channels, `#lobby`, a card), and 3 -> 2 -> 1 on four deep-link entries (fresh tab at `?topic=`; `/` then `?topic=`; `/login`, `/`, `?topic=`; `/channel/lobby` then `?topic=`); browser Back 3 -> 2 at both widths | c-246 walks 8-9, n = 1 per path and width |
| 5 | The in-app swipe is one listener on the shell (`layouts/default.vue:32` `@touchend` -> `useMobileStack().swipe.onTouchEnd`), active only at level > 1; a pop walks `history.back()` when the entry under is ours (`mobileHasBelow`), else steps down in place | `src/composables/useMobileStack.ts:301-335` |
| 6 | The normal sign-in leaves no `/login` entry (`navigateTo(redirect, { replace: true })`); an external identity-provider round trip or a typed `/login` does | `src/pages/login.vue:96`; `middleware/signed-out-redirect.global.ts:36,74` |
| 7 | CDP touch events cannot drive the **browser's own** back gesture (iOS Safari edge swipe, Android system Back). Neither walk measured it | both docs, "not measured" |

So the measured defects are rows 1 and 2. Row 3 is unreproduced: this spec turns every Back path into a gate, so a skip on any path is caught, and asks a real-phone pass for row 7.

## 3. The design

### 3.1 Back never shows the sign-in page to a signed-in member

When a history step (Back, a swipe, the OS gesture) lands on `/login` and the session is signed in, the app does not render the sign-in page. It replaces that entry with the app's front door and steps back once more, so Back continues out of the app exactly as it would have without the stale entry. A signed-out member still sees the sign-in page.

### 3.2 Back is one level on every path: a gate

One e2e matrix, part of CI: **entry** x **method** x **width**.

- entries: the tap path to level 3; a fresh tab at level 3 (`?topic=`); a fresh tab at level 2; `/` then a level-3 deep link; `/login`, `/`, then level 3; a resumed place (§3.3); a notification open (`/m/<msg_id>`)
- methods: the header chevron, the dock Back, the edge swipe (x = 8), a swipe from x = 100, browser Back, and the same with an overlay (a sheet) open first
- widths: 360x780, 390x844

Each step must move exactly one level (3 -> 2 -> 1), an overlay first closes itself (T055), and no step reaches `/login` while signed in.

### 3.3 Reopen where you left off

- The app remembers, per signed-in member, the last place shown: the route, its `?topic=` and the anchor message of the scroll position (`spool.lastPlace` in the browser: `{<human_id>: {path, topic, anchor, ts}}`).
- A cold start at `/` (no query, no hash, not a notification open) within **12 hours** of `ts` opens that place, at that anchor, with the stack rebuilt under it: level 2 under a level-3 place, level 1 under that, so Back walks 3 -> 2 -> 1 and only then leaves the app.
- A deep link, a notification tap (`notify-open`), a shared URL or a `?settings=` route always wins over the restore.
- Sign-out deletes the member's entry (as 080 FR-008 does for drafts). A place that no longer exists (archived topic, removed channel) falls back to level 1 without an error.
- Phones only (<= 820 px). A desktop keeps its tabs.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member on a phone | Reopen the app and be back in the channel or topic I left | 2-3 taps saved per return |
| **US2** | **P1** | Member on a phone | Press Back and always go one step up | no surprise jumps |
| **US3** | **P1** | Signed-in member | Never see the sign-in page by pressing Back | no "unavailable" scare |
| **US4** | **P2** | Member opening an alert | Land on the alert's message, not my last place | the alert wins |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | A history step that lands on `/login` with a signed-in session replaces that entry with the front door and steps back once more; the sign-in page is never painted for a signed-in member | Planned |
| **FR-002** | Every Back method (chevron, dock Back, edge swipe, mid swipe, browser Back) moves exactly one level from every entry of §3.2, at 360 and 390 px; with an overlay open the first Back closes it | Partial (043 T005, T055 cover the tap path; the matrix is new) |
| **FR-003** | The app stores the last place per human id in `spool.lastPlace` (`path`, `topic`, `anchor`, `ts`) on every level-2/3 change and on `pagehide` | Planned |
| **FR-004** | A cold start at bare `/` within 12 h of `ts` opens the stored place with the stack rebuilt under it (history entries tagged 1 and 2 below a level-3 place) and scrolls to `anchor` | Planned |
| **FR-005** | A deep link, a query or hash, a notification open (`/m/<id>`, `notify-open`) or a `?settings=` route skips the restore | Planned |
| **FR-006** | Sign-out deletes the member's `spool.lastPlace` entry; a stored place that fails to load falls back to level 1 with no error notice | Planned |
| **FR-007** | Above 820 px no restore runs and Back is unchanged | Planned |
| **FR-008** | Help `interface-overview.md` §8 says the app reopens where you left off on a phone, and how to start fresh (the section chooser) | Planned |

## 6. Acceptance scenarios

All e2e against a generated mock bundle with a signed-in mock session (`spool.mock.session`), touch on, at 360x780 and 390x844.

| # | Check / test | Proves |
|---|---|---|
| **AC1** | `/login`, then `/`, then browser Back: the URL is not `/login`, and no element with `data-test` of the sign-in form or the text "Sign-in is unavailable" is painted at any point (MutationObserver log) | FR-001 |
| **AC2** | the §3.2 matrix (7 entries x 6 methods x 2 widths): each Back moves `data-mobile-level` by exactly one, an open sheet closes first, and `/login` never appears; the run prints the full matrix | FR-002 |
| **AC3** | open `#feedback`, then a topic, scroll to its 3rd reply; close the page; new page at `/` -> level 3, the same topic, the 3rd reply in view; Back -> level 2 `#feedback`; Back -> level 1 | FR-003, FR-004 |
| **AC4** | as AC3, but `ts` set 13 h back -> level 1 | FR-004 |
| **AC5** | as AC3, but open `/m/<msg_id>` of another message -> that message, not the stored place; and `/?settings=` -> the settings list | FR-005 |
| **AC6** | sign out -> `localStorage['spool.lastPlace']` has no entry for that human; a stored topic id that the mock does not know -> level 1, no `ErrorNotice` | FR-006 |
| **AC7** | 1440x900: a fresh `/` opens as before; the `mobile-stack`, `mobile-back-stuck`, `mobile-overlay` e2e and the `notify` unit test stay green | FR-007 |
| **AC8** | real phone (tasks T006): the OS back gesture (iOS Safari edge swipe in an installed app, Android system Back) on the AC2 tap path moves one level and never shows sign-in | FR-002 on the real gesture |

## 7. Overlaps

| with | how |
|---|---|
| 043 (`useMobileStack`, N3-N5, T055) | the stack and its history tags are reused; the restore pushes tagged entries the same way `push()` does. 043's rule that only `useMobileStack` writes stack history holds: the restore lives in it |
| 080 (drafts) and 088 (phone drafts) | the restored place loads its draft through 080's model; 088 owns that interplay |
| 085 (phone composer) | none in code |
| `notify-open` (CLE-77890) | an alert open wins (FR-005) |
| consensus Q1 (the section bar) | independent; the bar's More sheet is an overlay (T055 rules) |
| c78fb3ec, `mobile-back-stuck.test.mjs` | the earlier Back fix; its test joins the gate |

## 8. Not in scope

Restoring on a desktop. Syncing the last place across devices. Changing the 043 level model.

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | How long is a stored place fresh? | **12 hours**: covers a working day and an overnight break is a fresh start at the section chooser. Slack has no limit; a limit avoids reopening a stale thread days later |
| **Q2** | Restore level 3 (the topic) or only level 2 (its channel)? | **Level 3**, with level 2 rebuilt under it, so one Back is the channel (Slack, WhatsApp reopen the thread you were in) |
| **Q3** | At level 1, should Back leave the app or stay? | **Leave**, as today: Android expects the system Back at the root to leave; the fix is only that no stale `/login` sits in between (FR-001) |
| **Q4** | Keep the browser storage key per human id or per tab? | **Per human id**, the 080 pattern: a second member on the same browser never reopens the first one's place |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the mobile consensus, build item 4 (D7 + U1) | c-246 |

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T01:00:00Z -->
