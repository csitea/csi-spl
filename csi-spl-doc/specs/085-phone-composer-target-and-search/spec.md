# 085: the phone composer names its destination, and Search has a button

**Feature ID**: `085-phone-composer-target-and-search` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-05 · **Lane**: c-246 (spec only) · **Topic**: c893c3a9-b31e-45ca-a61b-fc8260f2d800
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[043 the WUI on phones](../043-spool-wui-mobile/spec.md) (the docked composer, D4),
[022 top-bar search](../022-spool-wui-top-bar-search/spec.md) (`/search` mode, the operator list),
[080 drafts and the target chip](../080-drafts-and-target-chip/spec.md) (**the chip model**: on a phone this spec turns it off, §3.1).

Evidence base: `../../doc/md/mobile-usability-consensus-20261005.md` A2 and build item 2 (agreed by c-246 and g-249),
`../../doc/md/mobile-usability-ideas-20261004.md` §1.1 task 3, §1.2, §3.5, §3.7, `../../doc/md/mobile-usability-grok-view-20261005.md` A2.

---

## 1. Why, and the owner's ask

Owner: "ideas for specs to improve the ui usability for mobile" (prd t1 `c893c3a9`, msg `cb3a56c0`); DoD "the ready specs to implement" (`44ff08f3`). The consensus put this second in its build order. It does not wait for the section-bar question (consensus Q1).

Owner decisions this spec keeps, unchanged:

| decision | source |
|---|---|
| on a phone the dock's button row is Back, Attach, Send (no camera, no extra button) | owner topic `d4bc9db4` (`tests/e2e/dock-buttons.test.mjs` header) |
| no floating GO; the dock's Send is the GO, and the dock is on every phone level so `/search` is always reachable | owner topic `9b58a27b`, SPL-1005 (`tests/e2e/mobile-go-dock.test.mjs` header) |
| no text line above the phone box: "remove also all of the texts on mobile above the omnibox" | owner t1 `dd98f8d7` (`MessageComposer.vue` comment above `.composer-target`) |
| one glyph inside the box at its start says the mode: `#` a new topic, the tree icon a reply | owner t1 `3d6d945d`, option A (`MessageComposer.vue` `composer-mode-glyph`) |

So nothing here adds a button to the dock row, a line above the box, or a control to the top bar.

## 2. Today, measured

Mock bundle, tree `7289ef28`, 390x844 and 360x780 with touch, n = 1 per row unless stated.

| # | fact | evidence |
|---|---|---|
| 1 | No search control on any phone screen. `top-bar-search` renders only when the desktop "at the bottom" setting is on (`v-if="atBottom"`) | `src/components/TopBar.vue:38-45`; c-246 inventory `390-_.png`; g-249 A2 (a tap on it failed, both widths) |
| 2 | Search on a phone = type `/search <terms>` in the box, then Enter: 2 taps + 8 characters of syntax, and `/` is on the phone keyboard's symbol layer. Slack: one tap on a search tab | c-246 ideas §1.1 task 3 (`/search?q=scaffold` reached) |
| 3 | The placeholder is one i18n string with desktop key hints: `"Message {target} — Enter for a new line · Ctrl+Enter or Cmd+Enter to send · /search to search everything"` (85+ characters). The field is 208 px wide at 390 and 178 px at 360, at 18 px type, so it shows ~14 characters | `i18n/locales/en.json:973` (`search.placeholder_target`), `:827-828` (`topic.reply_placeholder*`); g-249 A2 |
| 4 | On level 1 (the section lists) the box reads **"Message Topics"** whatever section is shown (Messages, Channels, Flow) | `src/pages/index.vue:249-253` (`target: tr('nav.topics')`); shots `390-_.png`, `w1-02-channels.png`, `w1-03-flow.png` |
| 5 | A send from level 1 with no open topic posts a **new topic** (`channel.send` with no target), from a screen that shows a list, not a feed | `src/pages/index.vue:214-236` |
| 6 | Once text is typed the placeholder is gone, so nothing names the destination; 080 §2 row 5 measured the same on desktop | 080 spec §2 |
| 7 | The `?` button inside the field (44x44 at 390) opens the operator list (`search-syntax-panel`) | `src/components/MessageComposer.vue:101-113`; inventory `390-_lobby` "Search syntax 44x44" |

## 3. The design

### 3.1 No target chip on a phone

**No chip on the phone** (owner, HUM-10, t1 `842e581f-664e-47c3-8f20-4f8a9e3f4e8c`, msg `b2e7c197-ca37-489a-899d-20f4b946d120`, 2026-10-07): "The whole small control should be removed. I can paste, and the paste works, but this small control, which says "Reply" (this bubble-like text), should be removed. It doesn't fit the mobile interface."

- At <= 820 px (the docked box, `composer--dock`) the omnibox renders **no** target chip: no `Reply · …`, no `#channel`, no `New topic`, focused or not, one line or many. The text field takes the freed width: line 1 starts at the field's inline start (after the mode glyph, when a thread shows one), with no chip indent.
- The target stays clear without it: the open thread or channel on screen names it, the placeholder says it (§3.2: `#alerts`, `Reply`), and the mode glyph and the dock's accent edge show a reply. The send target does not change: a reply goes into the open thread, a line on a channel (level 2) starts a new topic there.
- This replaces, on the phone only, the earlier picks: the chip inside the field on focus or text, the 9-character cut (`PHONE_CHIP_MAX`, owner msg `89704e48`, was 12) and "Chip 2" (msg `0b5cc9db`, the chip on a row on top of a multi-line draft). `phoneChipLabel` is removed.
- Above 820 px nothing changes: 080's chip (`chipLabel(target)`, 080 FR-006 / FR-007) stays in both desktop positions.

### 3.2 A short phone placeholder

At <= 820 px the placeholder is the destination only: `#alerts`, `@GRK-03`, `Reply`, and on level 1 `Search` (§3.4). Measured 2026-10-05 (c-284, tree ddc59252, n=2): "Message #alerts" wraps at 390 and 360, so the word `Message` is left out. The key hints (Enter, Ctrl+Enter, `/search`) leave the phone placeholder; they are listed at the top of the `?` panel instead. Desktop placeholders do not change.

### 3.3 Search has a button: the `?` becomes a magnifier on a phone

At <= 820 px the `?` button in the field shows a magnifier icon, keeps its 44 px target and is named "Search". A tap:

1. puts the box in search mode (the same state as typing `/search `: `omnibox--search`, the GO searches),
2. focuses the field (the keyboard opens) and opens the operator list that `?` opens today,
3. in search mode the mode glyph shows the magnifier (there is no chip on a phone, §3.1).

A second tap, or clearing the box, leaves search mode. Typing `/search ` still works. No new button: the dock row stays Back, Attach, Send.

### 3.4 Level 1 searches; it does not post

On level 1 (the section chooser and its list) the box is a search box: placeholder `Search`, mode glyph a magnifier, Enter opens `/search?q=`. It does not post a new topic from a list. To post, the reader opens a channel (level 2), whose name is on screen and in the placeholder. See Q2.

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member on a phone | See where Enter will post, before and while I type | no message lands in a place I did not mean |
| **US2** | **P1** | Member on a phone | Search with one tap, without knowing `/search` | search is findable |
| **US3** | **P2** | Member on a phone | Read a placeholder that fits the box | no clipped hint text |
| **US4** | **P2** | Member on a phone | Never start a topic by accident from a list screen | the list is for finding, the channel is for posting |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | At <= 820 px the docked box renders **no** target chip (owner msg `b2e7c197-ca37-489a-899d-20f4b946d120`, §3.1): not on focus, not with text, not on a multi-line draft; never a line above the box either (owner `dd98f8d7`). The send target is unchanged (a reply into the open thread, a new topic on a channel) | Planned |
| **FR-002** | No chip on the phone (owner msg `b2e7c197-ca37-489a-899d-20f4b946d120`): the text field takes the freed width, line 1 starts at the field's inline start (after the mode glyph, if any) with no chip indent. Replaces the 9-character cut (`PHONE_CHIP_MAX`, msg `89704e48`) and "Chip 2" (msg `0b5cc9db`) on the phone; `phoneChipLabel` is removed. The desktop chip (080 FR-006) stays | Planned |
| **FR-003** | At <= 820 px the placeholder is the destination only (`#<channel>`, `@<peer>`, `Reply`, `Search` on level 1); no key hints. New i18n keys `composer.phone_placeholder_*` in all 19 locales | Planned |
| **FR-004** | At <= 820 px the `?` button shows a magnifier, is named "Search", keeps a >= 44 px target, and a tap enters search mode, focuses the field and opens the operator list; a second tap or an empty box leaves search mode | Planned |
| **FR-005** | The operator list opened from the phone Search button starts with the key hints that left the placeholder | Planned |
| **FR-006** | On level 1 the docked box is search-only: placeholder `Search`, magnifier glyph, Enter opens `/search?q=<text>`; it never sends a message | Planned |
| **FR-007** | The dock row stays Back, Attach, Send; no control is added to it, to the top bar, or above the box | Planned |
| **FR-008** | Above 820 px nothing changes: placeholders, `?`, the chip of 080 and the top bar are as before | Planned |
| **FR-009** | Help `omnibox-and-navigation.md` §9 drops "The search icon in the top bar opens search as a full-screen sheet" (stale since SPL-1005) and describes the Search button on a phone (no chip there, §3.1) | Planned |

## 6. Acceptance scenarios

All e2e run against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <name>`), at 390x844 and 360x780 with touch unless stated.

| # | Check / test | Proves |
|---|---|---|
| **AC1** | at 390 and 360: open `#alerts` (level 2), the box unfocused, tapped, and with `x` typed; open a topic (level 3), tap the box: no `[data-test=composer-target-chip]` in any state; at 1440 a typed line on `#alerts` still shows the chip `#alerts` | FR-001, FR-002 |
| **AC2** | in every state of AC1 no element with text sits between the box's top edge and the feed, line 1 of the text starts at the field's inline start (no `text-indent`), and the textarea spans the field's inner width; sending at level 2 stores a new topic (`is_parent` 1, a list card) and at level 3 a reply into the open thread (`is_parent` 0 on its task, drawn in the thread only) | FR-001, FR-002, FR-007 |
| **AC3** | unit (`omnibox-topic`): `chipInfo` returns null while docked, and no `phoneChipLabel`, `PHONE_CHIP_MAX` or phone chip CSS is left; e2e at 360: type 60 characters on `#alerts` -> no chip, every line of text starts at the field's inline start. The dock tests (`phone-composer-target`, `composer-buttons-bottom`, `dock-buttons`, `phone-dock-geometry`, `composer-mode-cue`) assert the chip is absent on the phone with a draft, the dock geometry unmoved (field edges, Back, Attach, Send, each 44 px), and the desktop chip present. Owner msg `b2e7c197-ca37-489a-899d-20f4b946d120`, replacing "Chip 2" (`0b5cc9db`) | FR-002 |
| **AC4** | the placeholder's `scrollWidth <= clientWidth` on `#alerts`, a DM and a topic, at 360 (it fits) | FR-003 |
| **AC5** | level 2: tap Search (the magnifier, >= 44x44) -> the form has `omnibox--search`, the field is focused, `search-syntax-panel` is open; type `scaffold`, tap Send -> `/search?q=scaffold`; total taps from level 2: 2 + typing (today: 2 + `/search ` syntax) | FR-004, FR-005 |
| **AC6** | level 1 (Messages, then Channels, then Flow): the placeholder reads `Search` on each; type `abc`, Enter -> `/search?q=abc`, and the mock feed has no new message | FR-006 |
| **AC7** | the dock row's buttons are exactly `dock-back`, `attach`, `send` (`dock-buttons`, `mobile-go-dock` stay green) | FR-007 |
| **AC8** | 1440x900: the placeholder string, the `?` icon and the top bar are byte-identical to before (screenshots of `/lobby` and a topic) | FR-008 |
| **AC9** | `grep -c "search icon in the top bar" csi-spl-doc/doc/help/omnibox-and-navigation.md` -> 0 | FR-009 |

## 7. Overlaps

| with | how |
|---|---|
| 080 (c-245, drafts and the chip) | **one chip model**: 080 T005 writes `chipLabel` and the chip block of `MessageComposer.vue`; on a phone this spec now turns the chip off (§3.1, owner msg `b2e7c197`) |
| 080 drafts (and 088, the phone drafts) | none in code: the chip names the place whose draft is in the box |
| consensus Q1 (the section bar) | independent: the box and its Search stay in the dock wherever the bar goes |
| 022 search mode | reused, not changed: same `omnibox--search` state, same operator list |
| `composer-mode-cue`, `thread-dock-target`, `mobile-go-dock`, `dock-buttons` e2e | must stay green |

## 8. Not in scope

A search tab or a search screen of its own (consensus Q1 may add one). Changing the desktop placeholder. Voice input.

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Where does the phone Search button live: the `?` slot inside the field, the top bar, or the dock row? | **The `?` slot.** The owner fixed the dock row (`d4bc9db4`) and removed a floating GO (`9b58a27b`); the top bar was emptied for the workspace (SPL-995 E). The `?` is already a 44 px target inside the field, and the operator list it opens is the right help for search |
| **Q2** | Should level 1 stop posting new topics (FR-006)? | **Yes.** On level 1 the reader sees a list, the label says "Topics" whatever the list is (§2 row 4), and a send there starts a topic in a channel the screen does not show. Posting from a channel (level 2) is one tap away. If the owner wants posting from level 1, the fallback is a chip naming the real target channel |
| **Q3** | Should the chip show before typing (on focus), or only with text as on desktop (080)? | **Superseded: no chip on a phone** (owner msg `b2e7c197-ca37-489a-899d-20f4b946d120`). It was "on focus"; the placeholder and the open thread or channel now name the target |
| **Q4** | How wide may the chip be, given the narrow field? | **Superseded: no chip on a phone** (owner msg `b2e7c197-ca37-489a-899d-20f4b946d120`), so the field keeps its full width. History: 12 characters, then 9 (msg `89704e48`, 2026-10-06, to make pasting easy), then "Chip 2" on a row on top of a multi-line draft (msg `0b5cc9db`) |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the mobile consensus, build item 2 | c-246 |

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T00:30:00Z -->
