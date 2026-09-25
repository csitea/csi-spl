# Feature Specification: Message Levels — the Opening Card and the Thread Line

**Feature ID**: `033-spool-message-levels` · **Milestone**: M3 · **Status**: Implemented (three items Planned, `tasks.md` T013–T015)
**Created**: 2026-09-25 · **Lane**: MESSAGE-LEVELS (hub + DB + browser)
**Authority**: this file for the rule; `tasks.md` for what is built and where.

Status vocabulary follows `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

## Naming

The owner calls the flag `is_topic`. The column, the wire field and the code call it
`is_parent`. They are the same bit: `is_topic=1` ≡ `is_parent = 1` ≡ **level 1**;
`is_topic=0` ≡ `is_parent = 0` ≡ **level 2**.

## The owner's request, verbatim (2026-09-25)

> A spool message is one of two levels.
>
> Level 1 is the opening message of a topic. It is the card in the middle pane (channel
> feed, direct-message feed, lobby feed, topics home). One card per topic. The card is
> that opening message. Later activity may move the card up. The card's text stays the
> opening message.
>
> Level 2 is a message written while the right-hand topic pane is open. The reader got
> there by clicking replies. That click opens the right pane and leaves the left tab where
> it was (Channels, DMs, Topics, or Flow). A level-2 message is stored with is_parent = 0.
> It is drawn only inside the open topic on the right. It is never a row in the middle
> pane, never a new topic card, and never a new row on the topics home list.

Refined the same day, after trying the build:

> there is still bug in the cration of the msgs ... whenever the last selected pane was
> the middle pane - check test-02 typing on the omnibox and hitting enter should have
> created an is_topic=1 msg , not a thread msg with is_topic=0

> test-03 when the right threads / topic content panel is visible and last selected the
> typing of msgs should produce an is_topic=0 msg

> it should be possible to also edit the is_topic=1 msgs by double clicking them

> delete all of te msgs data from the dev and prd , to start clean with the testing

## Clarifications

### Session 2026-09-25

- **The pane selected last decides, not "is the pane open".** **OWNER-STATED** (test-02,
  test-03 above). The first three builds keyed the level on the left tab (`69cdf97`), then
  on the pane being open (`5b16c0f`); the owner's test-02 was stored as a thread line
  because the pane was still open although the owner had gone back to the middle.
- **Opening a topic puts the reader on the right.** A replies click, a card click, Enter on
  a focused card and a topics-home row click all count as selecting the right pane.
  **OWNER-STATED** for the replies click (the original request); the other three are the
  same action by another input, **INFERRED**.
- **The sidebar, the top bar (Omnibox) and a pane divider select nothing.** Typing in the
  Omnibox must not itself move the choice. **INFERRED** — the Omnibox is where every line
  is typed, so it cannot be the signal.
- **A pane opened from a `?topic=` URL with no click yet counts as the right pane.**
  **INFERRED**: it is the newest thing on screen.
- **`in: <title>` still names the topic**, whatever pane was selected. **OWNER-STATED**.
- **A box or agent send is always level 1.** The hub stores `is_parent = 1` for it; only a
  browser chooses. Decided with the hub change (`69cdf97`). **Amended in 0.5.7
  (FR-ML-013):** except a line on a channel topic's task, which is stored level 2
  (`internal/hub/channels.go` `boxLevel`); a new task, a DM topic and the legacy lobby
  task stay level 1.
- **`is_parent` is hub metadata, not part of the signed envelope** — same reason as 032's
  edit marker: no signature covers a field the browser chooses.
- **Double-click edits a level-1 card too.** **OWNER-STATED**. `82ddd5e` (another lane)
  shipped it for right-pane lines only and kept the middle card click-to-open; `618851f`
  extends it to the viewer's own middle card. The first click of the double click still
  opens that card's topic.

## User stories

### US1 — start a topic (P1)

With the right pane closed, or with the middle pane selected last, a member types a line
in the Omnibox and sends it. One new card appears in the middle pane; the hub stores the
line with `is_parent = 1` on a new `task_id`.

### US2 — write inside a topic (P1)

The member clicks replies on a card. The right pane opens on that topic, the left tab does
not change. The next line is stored with `is_parent = 0` on **that topic's** `task_id`,
appears in the right pane only, and the middle still shows exactly one card for the topic,
reading the opening line.

### US3 — go back to the middle (P1, test-02)

With the right pane still open, the member clicks in the middle pane and sends. The line
is a new topic (US1), not a line of the open one.

### US4 — it survives a reload and a second reader (P1)

After a reload, and in a second tab that only receives lines over the live socket, a
level-2 line is still absent from the middle and present when its topic is opened.

### US5 — fix a typo with a double click (P2)

A double click on the member's own message — a middle card or a right-pane line — opens
the same in-place editor as `e` (032).

## Functional requirements

| id | requirement | status |
|---|---|---|
| FR-ML-001 | `messages.is_parent smallint NOT NULL`, 0 or 1; existing topic openers backfilled to 1 | Implemented — rdb `0034`, `0035` |
| FR-ML-002 | Browser send frame carries `is_parent`; absent = 1, other values rejected; box sends stored as 1 (except FR-ML-013) | Implemented — `internal/hub/wui.go` `uiParent` |
| FR-ML-003 | The topic read and the live `message` frame return `is_parent` | Implemented — `69cdf97` |
| FR-ML-004 | A send is level 2 into the open topic iff the right pane is open **and** was selected last; otherwise level 1 on a new task; `in:` wins | Implemented — `618851f` (`utils/pane-focus.mjs`, `utils/omnibox-topic.mjs`) |
| FR-ML-005 | The middle list never shows an `is_parent = 0` line as a card; one card per topic, reading the opening line | Implemented — `66de3bc`, `778cf49` |
| FR-ML-006 | The right pane keeps its topic's level-2 lines after the send is confirmed | Implemented — `778cf49` |
| FR-ML-007 | The topics home list never gets a new row for a level-2 line | Implemented — `topic-list.mjs` `bumpTopic` |
| FR-ML-008 | After a reload a topic keeps its card even when its newest page is all level 2 | Implemented — `618851f` (`listMessages`) |
| FR-ML-009 | A new lobby topic reaches every open `/lobby` live, not only its sender | Implemented — `618851f` (`pages/lobby.vue`) |
| FR-ML-010 | Double click opens the editor on the viewer's own message at either level | Implemented — `82ddd5e` + `618851f` |
| FR-ML-011 | `/t/<task_id>` shows the level-2 line in the topic and adds no second card | Partial — code: `pages/t/[task_id].vue` sends level 2 (`isParentFlag({ paneVisible: true })`); the proof surface is missing, `tasks.md` T014 |
| FR-ML-012 | A level-2 reply is stored in its topic root's channel, whatever client sent it untagged | Implemented — hub `7b6e0ae` (0.5.4); backfill rdb 0042 applied dev + prd, `tasks.md` T017 |
| FR-ML-013 | An agent's line on a channel topic's task is a level-2 reply, as the same line from the WUI reply pane is | Partial — hub 0.5.7 `boxLevel` built; rdb 0043 backfill applied on dev/prd is not recorded, `tasks.md` T018 |

## Level-1 card presentation in the middle pane (CLE-34989)

The owner, 2026-09-25 18:48:43Z, PRD #spool-hub-devel topic `db0f9d71`, verbatim:

> implement the feagture to clip the size of the msg with is_parent=1 to max 5 rows of text or max 30% of the screen if picture is involved ... the rest should be expandable via the similar expandable graggable handle which exists in the ommibox ... so that the middle topics pane where the is_parent=1 msgs are displayed will stay by default tighty. There should be a control which sets the height of those posts to 3 different ways - only titles ( where title is the first 90 chars , this default of 5 rows max and all size

| id | requirement | status |
|---|---|---|
| FR-ML-020 | A level-1 card in the MIDDLE pane (lobby, channel, DM) is clipped by default at 5 text rows of its body; the thread pane and the new-topic cards above it are never clipped | Implemented — `utils/card-clip.mjs` `cardClipPx`, `LiveFeed` `clip` (middle hosts only) |
| FR-ML-021 | A card carrying an inline picture is clipped at 30% of the window height instead (never below 5 rows); its text keeps its own 5-row cap inside that box, so the picture is in view | Implemented — `cardHasPicture` + `cardClipPx`, `.card-clip--pic-text` |
| FR-ML-022 | A clipped card shows it (the last line fades) and carries a grip like the omnibox's: a drag sets its height, from one row to all of it; Enter / Space shows all or goes back; Arrow Up / Down step two rows. The drag is per card and not stored | Implemented — `MessageCard.vue` `.card-grip` |
| FR-ML-023 | A 3-way control in every middle-pane header: `titles` (first 90 characters of the body on one line), `5 rows` (default), `full`; a keyboard radiogroup | Implemented — `CardClipControl.vue` |
| FR-ML-024 | The mode is one per browser and survives a reload (localStorage `spool-card-clip`, try/catch; a bad value reads as the default) | Implemented — `useCardClip.ts` |
| FR-ML-025 | The row cap follows the font-size setting (measured line height; rem fallback) | Implemented — `measure()` reads the rendered line height |
| FR-ML-026 | Every new string in all 19 locales (i18n parity) | Assigned — GRK-3512, `tasks.md` T019 |

## Success criteria

- **SC-ML-1**: the live proof `csi-spl-wui/tests/e2e/parent-level-live.proof.mjs` passes
  every step on dev and prd (channel, DM, lobby, topics home; sender tab and watcher tab;
  reload; test-02; test-03; double click). Measured `618851f`: dev 80/80, prd 80/80, n=1
  per surface (`tasks.md` T011).
- **SC-ML-2**: `tests/unit/parent-level.test.mjs` green in the unit runner.
- **SC-ML-3** (CLE-34989): signed in on dev and prd, the computed card heights per mode
  match FR-ML-020..FR-ML-023, a grip drag grows a card, the thread pane stays unclipped,
  and the mode survives a reload (`tasks.md` T019).

<!-- version: 0.1.4 · updated: 2026-09-25 · last-edit: 2026-09-25T19:45:28Z -->
