# 081: command palette (Ctrl+K), pane keys and a complete shortcut overlay

**Feature ID**: `081-command-palette-and-pane-keys` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-04 · **Lane**: c-245 (spec only) · **Topic**: 3a74320e-b5b0-44b8-bf1e-6d1b9c84d5ed
**Authority**: this file for the behaviour; `tasks.md` for what is built, with the sha and the check for each item. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[022 top-bar search](../022-spool-wui-top-bar-search/spec.md) (full-text search stays there),
[050 panel collapse](../050-spool-panel-collapse/spec.md) §3.7 (no collapse shortcut, owner Q7),
[075 docs section](../075-docs-section/spec.md) (the docs list the palette reads),
[078 desktop layout](../078-desktop-wide-thread-layout/spec.md),
`../../doc/md/SPEC-spool-wui-layout.md` §2.2 *Quick Switcher* (specced, never built: this spec replaces it),
help `../../doc/help/keyboard-shortcuts.md` (§7 is generated from code).

Evidence base: `../../doc/md/desktop-usability-consensus-20261005.md` L5 (agreed by c-245 and g-248), ideas doc §3.1, §3.2, T1, T6, T7, T8; grok view A8.

---

## 1. Why, and the owner's ask

Owner go: ea6330ff (starters #3 command palette and #4 keyboard-first navigation are in the pick). Owner posts on keys and focus, verbatim (relayed by c-002, msg 7f75f5e5):

- `4104f0c8`: "we should introduce also a shortcut system , for example , shift + h , or prpopse what kind of shortcuts cuold be used for those quick actions , something generic to go with the first letter for an action"
- `83c39d11`: "the new Shift + <<action>> keyboard shortcuts are not visible here ..."
- `55ad15bc`: "when I hide a card in the reply msgs panel , the focus afte rhitting Shift + H , goes to the second panel , when it should stay in the 3rd panel"
- `8b1a5cc5`: "basically on every keyboard shortcut on the left panel , after hitting the shortcut the focus should go back to this panel ,"

## 2. Today, measured

| # | fact | evidence |
|---|---|---|
| 1 | `Ctrl+K` opens nothing; focus stays where it was | both walks (mock, 1440, n=1); `grep -rniE 'ctrl\+k\|cmd\+k\|quick.?switch\|command.?palette' src --include=*.vue --include=*.ts --include=*.mjs \| wc -l` -> 0 |
| 2 | Switching channel, opening settings and opening a doc take 2, 2 and 4+ clicks; none has a key | ideas doc T1, T6, T7 |
| 3 | Any chord with Ctrl, Meta or Alt is rejected by the one shortcut rule, and the window listener is installed only while message cards are registered | `src/utils/msg-shortcuts.mjs:99-114` (:102), `src/composables/useMsgShortcuts.ts:162-197` |
| 4 | 35 `Tab` presses from load to the first message card; every DM row is two stops (row + ≡); no skip link | ideas doc T8; `grep -rniE 'skip-link\|skip to' src \| wc -l` -> 0 |
| 5 | Pane focus knows `middle` and `right` only; there is no key to move between panes | `src/stores/pane-focus.ts:6`, `src/utils/pane-focus.mjs:12-13` |
| 6 | Nothing moves focus after a route change | `src/layouts/default.vue:288-298` (`afterEach` only closes panes) |
| 7 | `Shift+?` lists the 12 message actions, the topic-row Archive and four navigation keys; it lists no pane, section or global keys | `src/components/MsgShortcutsHelp.vue:7-18`; grok view A8 |
| 8 | Focus-hold after a Shift shortcut exists (`holdPanel`) and has an e2e (`hide-keeps-pane-focus`) | `useMsgShortcuts.ts:102-160` |
| 9 | Sections: `RAIL_TABS` (10) in `src/utils/rail-order.mjs:15`; only a reverse path→tab map exists (`tabForPath`, `src/utils/sidebar-tabs.mjs:55-70`); settings pages: `SETTINGS_SECTIONS` (7) | code read |

## 3. The design

### 3.1 The palette

`Ctrl+K` (`Cmd+K` on macOS) opens a centred dialog with one input, from anywhere on a desktop, including while typing in the composer. Typing filters one ranked list of:

| group | source |
|---|---|
| Sections | the rail tabs, Help, Docs, Workspace settings (admin only) |
| Channels, people | the channel and roster stores (DMs open `/dm/<peer>`) |
| Topics | the workspace's recent topics (the Topics list's data) |
| Docs | the docs tree (075's source, not a second index) |
| Settings | the 7 settings pages |

`Enter` goes there; `↑/↓` move; `Esc` closes and restores focus. Ranking: exact prefix, then word prefix, then substring, then recency of use (browser, `spool.palette-recent`, last 20). Empty input shows the recent items.

A leading `>` switches to **actions**: the actions of the message menu that the current selection allows (same list and gating as `msgMenuItems`), plus *New topic here*, *Mark all read here*, *Change theme*. Each action row shows its shortcut, so the palette teaches the keys. The palette never sends a message: `/` stays the place to compose and search (g-248's condition).

### 3.2 Pane keys and the skip link

- `F6` / `Shift+F6` moves focus left pane → middle pane → right pane (when open) → omnibox, and back. The target is the pane's selected row, else its first row, else its heading.
- A skip link ("Skip to messages") is the first Tab stop; it focuses the middle pane.
- The left list is **one Tab stop**: arrows move inside it (roving tabindex), and a row's ≡ menu opens with `Shift+F10` / the context-menu key instead of being its own stop.

### 3.3 Focus after a route change

After a navigation that is not a popstate, focus goes to the new middle pane's selected row or heading (`tabindex="-1"`), and a polite live region announces the page title. A shortcut pressed in a pane keeps focus in that pane (today's `holdPanel` rule, extended to every key in this spec).

### 3.4 The complete overlay

`Shift+?` lists every key in groups: **Global** (`Ctrl+K`, `/`, `F6`, `Esc`, `?`), **Message** (the 12 Shift keys), **Topic list**, **Moving** (`↑/↓`, `j/k`, `Enter`), **Dividers** (arrows, Home, End). The groups and labels come from one table in `msg-shortcuts.mjs`; help `keyboard-shortcuts.md` §1 and §7 are generated from it and a unit test fails when page and code disagree (today's §7 pattern).

## 4. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Member | Press `Ctrl+K`, type `fee`, press Enter and be in `#feedback` | 2 clicks become 1 chord + 3 keys |
| **US2** | **P1** | Member | Reach settings, a doc or a person the same way | T6, T7 |
| **US3** | **P1** | Keyboard user | Move between panes with `F6`, and reach the messages in two key presses after load | T8: 35 Tab presses today |
| **US4** | **P1** | Member | See every key in `Shift+?` | owner 83c39d11 |
| **US5** | **P2** | Member | Run "archive" on the selected topic from the palette and learn its key | the palette teaches |

## 5. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | `Ctrl+K` / `Cmd+K` opens the palette on any desktop page, also from a text field; ignored on a phone and while another modal is open | Planned |
| **FR-002** | The palette lists sections, channels, people, recent topics, docs and settings pages from their existing stores; admin-only rows follow the existing gates | Planned |
| **FR-003** | Ranking: prefix, word prefix, substring, then recency (`spool.palette-recent`, 20); empty input shows recents | Planned |
| **FR-004** | `>` lists actions allowed for the current selection with `msgMenuItems` gating, plus new topic, mark all read, change theme; each row shows its key | Planned |
| **FR-005** | The palette never sends a message | Planned |
| **FR-006** | `F6` / `Shift+F6` cycle left, middle, right (if open), omnibox | Planned |
| **FR-007** | A skip link is the first Tab stop and focuses the middle pane | Planned |
| **FR-008** | The left list is one Tab stop with arrow keys inside; a row menu opens with `Shift+F10` / ContextMenu | Planned |
| **FR-009** | After a non-popstate navigation, focus goes to the middle pane's selected row or heading and a live region announces the page | Planned |
| **FR-010** | Every key from this spec keeps focus in the pane where it was pressed | Planned |
| **FR-011** | `Shift+?` shows the five groups from one table; help §1 and §7 are generated from it and unit-tested | Planned |
| **FR-012** | The `keyboard_shortcuts` setting turns off the single-letter and Shift keys; `Ctrl+K`, `F6`, `Esc` and the skip link stay (they are not letters) | Planned |

## 6. Acceptance scenarios

| # | Check / test | Proves |
|---|---|---|
| **AC1** | e2e, mock, 1440: on `/lobby`, `Ctrl+K`, type `fee`, `Enter` -> URL `/channel/feedback`, palette closed, focus in the middle pane | FR-001, FR-002 |
| **AC2** | e2e: focus the composer, type `abc`, `Ctrl+K` -> palette opens; `Esc` -> focus back in the composer with `abc` intact | FR-001, FR-005 |
| **AC3** | unit (`palette`): for items `feedback`, `fee-review`, `coffee` and query `fee` -> order `feedback`, `fee-review`, `coffee`; a recent item outranks an equal match | FR-003 |
| **AC4** | e2e: select a topic card, `Ctrl+K`, type `>arch` -> an *Archive* row with `⇧A`; `Enter` archives it (undo toast shows) | FR-004 |
| **AC5** | e2e: from load, `Tab` -> the skip link; `Enter` -> focus in the middle pane; total key presses to the first card ≤ 3 | FR-007 |
| **AC6** | e2e: `F6` x3 from the left pane with a topic open -> focus is in middle, right, omnibox in turn; `Shift+F6` goes back | FR-006 |
| **AC7** | e2e: `Tab` from the skip link through the left list -> the list takes exactly one stop; `↓` moves the row focus | FR-008 |
| **AC8** | e2e: click People in the rail -> `document.activeElement` is inside `.spool-main`, and the live region text is the page title | FR-009 |
| **AC9** | unit: the overlay table has the five groups; the generated help §1/§7 equals the page text | FR-011 |
| **AC10** | e2e: with the setting off, `Shift+A` does nothing and `Ctrl+K` still opens the palette | FR-012 |
| **AC11** | existing `msg-shortcuts`, `slash-focus`, `hide-keeps-pane-focus` suites stay green | no regression |

## 7. Overlaps

| with | how |
|---|---|
| Shift-shortcut work (g-209, named by the orchestrator; `grep -rIl 'g-209' .` -> 0 files, so no spec of its own on master) | this spec owns the overlay table and the global listener; the Shift message keys stay as they are. Coordinate before touching `msg-shortcuts.mjs` |
| 075 docs (c-240, running) | palette docs rows read 075's docs list; no second index |
| 022 search | full-text search stays in the omnibox (`/search`); the palette only navigates and acts |
| 050 Q7 | no collapse key is added |
| next-unread spec (L8) | its `Alt+Shift+↓` joins the overlay's Global group |

## 8. Not in scope

`g`-then-letter go-to sequences (Q3). Custom key bindings. Phone keys (FR-001 ignores phones).

## 9. Open questions, each with a recommended answer

| # | Question | Recommended answer |
|---|---|---|
| **Q1** | Should `Ctrl+K` work while typing in the composer? | **Yes** (Slack, Linear): it inserts no text, and the composer keeps its text when the palette closes |
| **Q2** | Chrome uses `Ctrl+K` for its own search box. Take it anyway? | **Yes, with `preventDefault` inside the page**: the same as GitHub and Slack; outside the page Chrome keeps it |
| **Q3** | Add `g c` / `g p` style go-to sequences too? | **No for now**: the palette covers going to a section in about the same keys (g-248: one chord, not a second system) |
| **Q4** | Roving tabindex in the left list changes the Tab order people know. Do it? | **Yes**: 16 of the 35 stops are DM rows and their menus; the WAI-ARIA listbox pattern is the standard |

## 10. Version log

| Version | Change | Author |
|---|---|---|
| v0.1 | First spec from the consensus (L5): palette, pane keys, skip link, roving left list, focus after route, complete overlay | c-245 |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T22:35:00Z -->
