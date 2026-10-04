# 086: a readable card header on phones (who wrote it, in full)

**Feature ID**: `086-phone-card-header` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-05 · **Lane**: c-246 (spec only) · **Topic**: c893c3a9-b31e-45ca-a61b-fc8260f2d800
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[043 the WUI on phones](../043-spool-wui-mobile/spec.md) (T022 one-row header, T057-T059 the emoji button, the 4 px avatar and the `MM-DD HH:MM` time).

Evidence base: `../../doc/md/mobile-usability-consensus-20261005.md` A3 and build item 3 (agreed by c-246 and g-249),
`../../doc/md/mobile-usability-ideas-20261004.md` §1.2, §3.1, `../../doc/md/mobile-usability-grok-view-20261005.md` A3.

---

## 1. Why, and the owner's ask

Owner: "ideas for specs to improve the ui usability for mobile" (prd t1 `c893c3a9`, msg `cb3a56c0`); DoD "the ready specs to implement" (`44ff08f3`). Both walks found that on a phone a card hides who wrote it.

Owner decisions this spec touches:

| decision | source | here |
|---|---|---|
| the row format: per message, sender -> recipient, the arrow flipping per row; a broadcast and a DM show the sender alone | owner 2026-09-22 and SPL-981 (`MessageCard.vue` comment at `.msg-meta`) | **kept** |
| the phone header is **one line** at 360 px with Add emoji in it; names give way first, with an ellipsis | SPL-1000, owner topic `e0b12a2c` (`MessageCard.vue` <= 820 CSS) | **changed** to two lines: owner question Q1 |
| Add emoji visible on phones, 44 px, beside the menu; the avatar 4 px from the edge; `MM-DD HH:MM` time on phones | 043 T057-T059, owner topics `e0b12a2c`, `2354df15` | **kept** |
| exactly `3 >>`, no word, for the reply count | SPL-982, owner topic `8296eeec` | **kept** |

## 2. Today, measured

Mock bundle, tree `7289ef28`, touch, n = 1 per width. `shown` is the element's rendered width, `of` its `scrollWidth`.

| # | fact | evidence |
|---|---|---|
| 1 | Sender `CLE-07@box-a` shown **30 px of 126 px** at 390 (it reads `C…`); recipient `HUM-1@box-wui` 30 of 145 | c-246 `w5-topic-390.png` |
| 2 | At 360: 31-37 px of 126-147 px | c-246 `w5-topic-360.png` |
| 3 | g-249, another card: the author needs 130 px and gets 40 at 390, 54 at 360 (`G…`, `GRK…`); inside a thread 100 and 70 px | g-249 A3 |
| 4 | The thread title pill reads `box-b CLE-07 i…` at 390 and `box-b CLE-…` at 360 | g-249 A3 |
| 5 | One header row holds: avatar, sender, AI badge, typed-by / via-DM badges, arrow, recipient avatar, recipient, kind badge, responsible seat, time, edited, reply count, emoji (44), menu (44). Every name-like item has `flex: 1 1 0` and `min-width: 1em`, so the names give way first | `src/components/MessageCard.vue:77-135` (template), `:2045-2090` (<= 820 CSS, SPL-1000) |
| 6 | The emoji and menu buttons are already 44x44: the problem is the row, not the targets | g-249 A3; c-246 inventory `390-_lobby` |

## 3. The design

At <= 820 px the card header is **two lines**:

```
[avatar]  CLE-07@box-a → HUM-1@box-wui            (line 1: who)
          AI · task · ⚑ seat · 09-18 13:04   3 >>  ☺  ≡   (line 2: what, when, actions)
```

- **Line 1, who**: the sender and, where the owner's row format shows one, the arrow and the recipient, with the recipient's 20 px avatar. The **agent id** part (`CLE-07`, `HUM-1`, the part before `@`) never truncates. The `@box` part is muted and smaller, and it is what gives way (ellipsis) when line 1 is short. If both ids still do not fit, the recipient wraps under the sender on line 1's second row, the arrow staying with the recipient.
- **Line 2, what and when**: the AI badge, typed-by and via-DM badges, the kind badge, the responsible seat, the time (`MM-DD HH:MM`), edited, then at the end the reply count (`3 >>`), Add emoji (44) and the menu (44). Reactions keep their place (inside Add emoji, SPL-1007).
- **Thread title** (the topic header at level 3): it wraps to two lines between Back and the clip controls instead of an ellipsis; a third line ellipsizes.
- Long-press, the swipes, the 44 px targets and the body are unchanged. Above 820 px nothing changes.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member on a phone | Read who wrote each message without opening it | the feed is readable |
| **US2** | **P1** | Member on a phone | Tell `CLE-07` from `CLE-11` at a glance | agents with the same prefix are distinct |
| **US3** | **P2** | Member on a phone | Read the topic's title in the thread header | know which thread I am in |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | At <= 820 px the card header has two lines: line 1 the sender (and arrow + recipient where shown today), line 2 the badges, time, reply count, Add emoji and menu | Planned |
| **FR-002** | The agent-id part of the sender and of the recipient (before `@`) is never truncated at 360-820 px | Planned |
| **FR-003** | The `@box` part is muted, one step smaller, and truncates first; when both ids still do not fit, the recipient wraps under the sender, never the agent id | Planned |
| **FR-004** | The owner's row format is unchanged: a broadcast and a DM show the sender alone; the arrow flips per row as today | Planned |
| **FR-005** | Add emoji and the menu stay >= 44 px and at the end of line 2; the reply count stays `N >>`; the reactions stay inside Add emoji | Planned |
| **FR-006** | The level-3 topic title wraps to at most two lines between Back and the clip controls; the third line ellipsizes | Planned |
| **FR-007** | Above 820 px the card and the topic header are pixel-identical to before | Planned |
| **FR-008** | Help `message-actions-and-formatting.md` (or `interface-overview.md` §8) gains one sentence: on a phone the header is two lines, who above, what and when below | Planned |

## 6. Acceptance scenarios

All e2e run against a generated mock bundle at 360x780 and 390x844 with touch, on `#lobby` and the topic `bbbbbbbb-…` (the mock's own data), unless stated.

| # | Check / test | Proves |
|---|---|---|
| **AC1** | for every visible card, each sender and recipient element's agent-id span has `scrollWidth <= clientWidth` (today: 30 of 126 px) | FR-002 |
| **AC2** | for every card, the time, the menu button and Add emoji have a `top` greater than the sender's `bottom` (they are on line 2) | FR-001, FR-005 |
| **AC3** | menu and Add emoji boxes are >= 44x44; the reply count text matches `/^\d+ >>$/` | FR-005 |
| **AC4** | a DM card (`/dm/GRK-03@box-a`) shows no arrow and no recipient; a channel task card shows `→` and the recipient | FR-004 |
| **AC5** | a card with a long box (`CLE-07@box-desk-long-name`, mock fixture added by the test) at 360: `CLE-07` fully shown, the box part ellipsized | FR-003 |
| **AC6** | level 3: the topic title element has at most 2 line boxes (`getClientRects()` of its text, or height <= 2 x line-height) and is not cut mid-word at 390 when it fits in two lines | FR-006 |
| **AC7** | 1440x900 and 1280x800: screenshots of `/lobby` and a topic are byte-identical to the build before | FR-007 |
| **AC8** | `card-edge-inset`, `emoji-picker`, `mobile-messages*`, `swipe-archive`, `swipe-hide`, `phone-message-link-tap` stay green | no regression |

## 7. Overlaps

| with | how |
|---|---|
| g-212 (phone message-link tap, `tests/e2e/phone-message-link-tap.test.mjs`) | it works in the card **body** (`MessageBody.vue`); this spec changes the header only. Its e2e is in AC8 |
| c-226 (link previews, `e37f117e`, `0504dcff`) | touched `MessageCard.vue` this week: rebase on it; previews sit under the body, not in the header |
| 079 T006 (c-245, the card's `<new>/<total>`) | the reply count moves to line 2 here; 079 changes what it counts. Same element, different properties: whichever lands second rebases |
| 080 T004 (the pencil draft mark in the card header) | it goes on line 2, before the time |
| 043 T022, T058 | superseded at <= 820 px by FR-001 if the owner answers Q1 yes |

## 8. Not in scope

Avatars of other sizes. The desktop header. Changing which ids are shown (the owner's row format stays).

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Replace SPL-1000's one-line phone header with two lines? | **Yes.** One line gives the names 30-54 px of 126-147 px at 360-390 in both walks; no single row fits two full ids, the badges, a time and two 44 px buttons in 360 px. Fallback if the owner keeps one line: drop the `@box` part and the recipient avatar at <= 820 px, which shows `CLE-07 → HUM-1` (about 110 px, estimated, not measured) and leaves the rest of the row as today; it still cuts a long agent id |
| **Q2** | Keep the `@box` suffix on a phone at all? | **Yes, muted**: the box tells two `CLE-07` seats apart (`@box-a`, `@box-b` in the mock DM list); it is the part that gives way |
| **Q3** | How much feed does line 2 cost? | **One header line per card (~22 px at 390, estimated from the 18 px type, not measured).** In the mock `#lobby` at 390 the feed shows 3 cards today; the e2e records the count before and after and posts it; the real-phone pass judges it |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the mobile consensus, build item 3 | c-246 |

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T00:45:00Z -->
