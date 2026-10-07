# 103: vim-style navigation across the whole UI

**Feature ID**: `103-vim-navigation` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-10-07 · **Lane**: a-501 (spec only) · **Topic**: 7d9e1681-66c8-4c0d-89c6-f946a1ae7e18
**Authority**: this file for behaviour; `tasks.md` for build order, ownership and done checks. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing.

Builds on, and does not repeat:
[081 command palette and pane keys](../081-command-palette-and-pane-keys/spec.md) (Ctrl+K, F6 cycle, roving tabindex, route focus),
[050 panel collapse](../050-spool-panel-collapse/spec.md) (handling collapsed strip panels),
[078 desktop wide thread layout](../078-desktop-wide-thread-layout/spec.md) (three-pane desktop layout architecture),
[023 user settings keys](../023-spool-user-settings-keys/spec.md) (keyboard shortcuts toggle claim),
`ChannelSidebar.vue` (arrow keys and j/k in channel list of commit `312ea460`),
`useMsgShortcuts.ts` and `utils/msg-shortcuts.mjs` (message shortcuts, Shift+B to list / Shift+U back of commits `b6562bf2`, `66f35c4d`, and `70384d49`),
`csi-spl-doc/doc/help/keyboard-shortcuts.md`.

---

## 1. Why, and the owner's ask

Verbatim owner instructions from HUM-10 (t1 topic `7d9e1681-66c8-4c0d-89c6-f946a1ae7e18`):

- `6decbad3`: *"actually I have a really better idea , could we use vim style navigation to the whole ui , except the omnibox"*
- `c80d7c30`: *"with j k l h"*
- `0f220e04`: *"as long as any object is selected in the ui which is in the sections of the small icons ( 0 panel , 1st panel , 2nd panel and the 3rd panel in all of the view ?!"*
- `553cf543` (Owner acceptance of dispatcher clarifications):
  1. Other text fields (search filter, settings field, dialog): `h j k l` type letters, as in the omnibox — *"yes"*
  2. `Enter` opens the selected item (channel, topic, message); `Esc` goes back one panel — *"yes"*
  3. `g g` / `Shift + G` jump to the first / last item in the panel — *"yes"*
  4. On by default; Settings -> Behaviour -> Keyboard shortcuts turns it off — *"yes , could be turned off from the user settings, on by default"*
  5. Phone: off — *"yes - no need for phone support for this one"*
  6. The existing `j` / `k` in the message lists become part of this; arrow keys keep working — *"yes"*
- `c503043c`: *"if you do not have more questions, go for the implementation"* (authorizing direct progression to build plan v1.0).

---

## 2. The universal 4-panel model

In EVERY desktop view across the entire application, the interface maps to four logical panels numbered **0** through **3**:

```
+---------------+---------------------+-----------------------------+-----------------------------+
| Panel 0: Rail | Panel 1: Left List  | Panel 2: Middle List / Main | Panel 3: Topic / Right Pane |
| (Small icons) | (Section inventory) | (Primary stream / content)  | (Thread / detail inspector) |
|               |                     |                             |                             |
| [Hash]        | # general           | [Msg Card 1]                | [Reply Card 1]              |
| [DMs]         | # lobby             | [Msg Card 2]                | [Reply Card 2]              |
| [Issues]      | # dev               | [Msg Card 3]                | [Reply Card 3]              |
| [Topics]      | ...                 | ...                         |                             |
| [Flow]        |                     |                             |                             |
+---------------+---------------------+-----------------------------+-----------------------------+
```

### Core Navigation Mechanics
- **`h`**: Move active selection to the panel to the left (3 → 2 → 1 → 0). Skips hidden or collapsed panels.
- **`l`**: Move active selection to the panel to the right (0 → 1 → 2 → 3). Skips hidden or collapsed panels.
- **`j`**: Move selection down to the next interactive item in the currently active panel.
- **`k`**: Move selection up to the previous interactive item in the currently active panel.
- **`g g`**: Quick chord (two presses within 500 ms) jumping to the first item in the active panel.
- **`Shift + G` (`G`)**: Jump to the last item in the active panel.
- **`Enter`**: Open or activate the selected item (e.g. switch channel, open thread in Panel 3, expand detail).
- **`Esc`**: Retreat one panel to the left (3 → 2 → 1 → 0), or dismiss an active overlay/dialog first.
- **Arrow keys**: `ArrowUp`, `ArrowDown`, `Home`, and `End` mirror `k`, `j`, `g g`, and `G` in parallel.

---

## 3. Comprehensive view inventory

Inventory of every view in the application, mapping what Panels 0..3 hold and what keyboard interactions exist today:

| View & Route | Panel 0 (Rail) | Panel 1 (Left List) | Panel 2 (Middle / Main) | Panel 3 (Topic / Right Pane) | Today's Keys & Gaps |
|---|---|---|---|---|---|
| **Channels**<br>`/channel/:name` | Icon rail (`.sidebar-rail`: tabs, Help, Docs, Settings, Operator) | Channels list (`#sidebar-panel-channels`: `a.nav-item[data-key]`) | Channel message feed (`.spool-main`: `article.msg`) | Topic replies pane (`aside.live-pane`: `article.msg`, if open) | **Today**: Arrows & `j/k` on focused channel row (`312ea460`); `j/k`, arrows, Shift actions on cards; `Shift+U`/`Shift+B` crosses panels 2 & 3. **Gap**: `h/l` between panels does not exist; Panel 0 has no `j/k`. |
| **Direct Messages**<br>`/dm/:peer` | Icon rail | DM roster list (`#sidebar-panel-dm`: `.nav-item[data-key]`) | Direct message feed (`.spool-main`: `article.msg`) | Topic / thread pane (`aside.live-pane`, if open) | **Today**: Roving tabindex on DM rows; card `j/k` & Shift shortcuts in feed. **Gap**: No `h/l` across panels; no vim navigation in roster list. |
| **Topics View**<br>`/t`, `/t/:task_id`, `/` | Icon rail | Topics list (`#sidebar-panel-topics`: `.nav-item`) | Topic browse list (`.topic-browse__list`: `a.topic-row[data-key]`) | Topic thread feed (`aside.live-pane`: `article.msg`) | **Today**: `Shift+A` (archive) on topic row; `Shift+B` jumps back to reply; card shortcuts in pane. **Gap**: No `j/k` across topic rows in Panel 2; no `h/l` between list and thread. |
| **Flow**<br>`/` (Flow active) | Icon rail | Flow stream filters (`#sidebar-panel-flow`: `.nav-item`) | Aggregated cross-channel feed (`.spool-main`: `article.msg`) | Topic discussion pane (`aside.live-pane`, if open) | **Today**: Card shortcuts (`Shift+H` hide from flow, `j/k` step). **Gap**: No vim stepping in stream filter list; no `h/l`. |
| **Issues**<br>`/issues` | Icon rail | Epics / milestones list (`#sidebar-panel-issues`, or collapsed if 0 epics) | Issues table / grid (`tr.issues-row`: status, prio, assignee) | Issue detail modal / operator pane (`aside.operator-pane`) | **Today**: `j/k` steps rows; `ArrowLeft/Right` steps cols; `c`, `e`, `s`, `p`, `a`, `l` trigger actions; `Esc` dismisses. **Gap**: Collides with universal vim navigation (see §5); no `h/l` panel navigation. |
| **Calendar**<br>`/calendar` | Icon rail (`calendarRailOnly`) | Year strip (`CalendarYearStrip`: 36 mini-months / day pills) | Calendar grid (`CalendarMainView`: Day / Week / Month slots) | Event detail / day sheet (`aside.live-pane`, if open) | **Today**: Clicks only; `Esc` closes strip on mobile. **Gap**: No keyboard navigation across months, days, or event entries; no `h/l`. |
| **People**<br>`/people`, `/people/:id` | Icon rail | People member list (`#sidebar-panel-people`: `.nav-item`) | Member profile card (`.feed-body`: details, presence, seat) | DM thread or operator pane (`aside.live-pane`, if open) | **Today**: Mouse clicks; F6 stops. **Gap**: No `j/k` in member list; no `h/l` to reach profile card or thread. |
| **Agents**<br>`/agents`, `/agents/:id` | Icon rail | Agents list (`#sidebar-panel-agents`: `.nav-item`) | Agent status card (`.feed-body`: runs, runtime config) | Operator console (`aside.operator-pane`: agent lifecycle) | **Today**: F6 stops. **Gap**: No `j/k` in agent roster; no `h/l` to move between list and operator console. |
| **Boxes**<br>`/boxes`, `/boxes/:id` | Icon rail | Boxes machine list (`#sidebar-panel-boxes`: `.nav-item`) | Box hardware card (`.feed-body`: liveness, seated users) | Operator diagnostics pane (`aside.operator-pane`, if open) | **Today**: F6 stops. **Gap**: No `j/k` in box list; no `h/l` to move between machine list and console. |
| **Events**<br>`/events` | Icon rail | Events filter / categories (sidebar body) | Event log table (`.events-table`: `tr[data-test="events-row"]`) | Event detail / JSON inspector (if open) | **Today**: F6 stops. **Gap**: No `j/k` across log rows; no `h/l` between filters and table. |
| **Archive**<br>`/archive` | Icon rail | Archive navigation / search (`#sidebar-panel-topics`) | Archived topics list (`.archive-list`: `.archive-row`) | Archived thread pane (`aside.live-pane`, if open) | **Today**: Click to open thread in right pane; Enter on links. **Gap**: No `j/k` stepping across archive rows; no `h/l` between list and thread. |
| **Search**<br>`/search` | Icon rail | Grouped search hits (`#sidebar-panel-search`: `SideHitList`) | Search query preview / info (`.feed-body`) | Search result thread pane (`aside.live-pane`, if open) | **Today**: Arrow keys in `SideHitList` (`CLE-77884`). **Gap**: `j/k` not unified in hits list; no `h/l` between hits and preview/thread. |
| **Settings**<br>`/settings`, `?settings=:id` | Icon rail (under routed dialog) | Settings section nav (`.settings-nav`: 7 section links) | Settings form section (`.settings-content`: options, inputs) | Empty / None | **Today**: Dialog Escape closes; Tab navigates fields. **Gap**: No `j/k` in section list; `l` does not enter settings content; no `h` to return. |
| **Tenant Settings**<br>`/tenant-settings/:id` | Icon rail | Tenant sections nav (`.settings-nav`: General, Members, etc.) | Tenant management view (`.settings-content`: tables, inputs) | Empty / Detail pane | **Today**: F6 stops; Tab. **Gap**: No `j/k` in tenant section nav; no `h/l` between sections and main content. |
| **Docs**<br>`/docs`, `/docs/:path*` | Icon rail (`docsRailOnly`) | Repo folder tree (`.docs-tree`: `DocsWorkspaceTree`) | Markdown reader (`.feed-body`: `MarkdownBlock`) | Editor drawer / Conflict view (when active) | **Today**: Click / Enter expands folders; tree scrolling. **Gap**: No `j/k` walking tree nodes; no `h/l` stepping from tree to document body. |
| **Help**<br>`/help`, `/help/:page` | Icon rail (`helpRailOnly`) | Help topics nav (`.help-nav`: links list) | Help document body (`.help-content`: `MarkdownBlock`) | Empty / None | **Today**: Click navigation. **Gap**: No `j/k` walking help pages; no `h/l` moving between navigation and document text. |

---

## 4. Interaction specification & key behaviors

### 4.1 Panel Selection & Movement (`h` / `l`)
- Pressing `h` calculates the target panel as `activePanel - 1`.
- Pressing `l` calculates the target panel as `activePanel + 1`.
- **Panel Visibility Rule**: If a panel is collapsed, hidden by CSS (e.g., `display: none` in `.sidebar--rail`), or unmounted (e.g., Panel 3 closed because no thread is active), navigation skips it and lands on the next visible panel in the requested direction.
- **Boundaries**: Movement does not wrap. Pressing `h` at Panel 0 remains at Panel 0; pressing `l` at the rightmost visible panel remains at that panel.
- **Target Selection upon Panel Entry**:
  1. The previously selected/focused item in that panel (retaining memory while on the same route).
  2. If none, the currently active item (`[aria-current="true"]`, `[aria-selected="true"]`, `[data-selected="true"]`).
  3. If none, the first interactive item in that panel.
  4. If the panel is empty, focus lands on the panel container or heading (`tabindex="-1"`).

### 4.2 Item Stepping (`j` / `k`)
- In Panel 0: Steps vertically through the rail icon tabs (`sidebar-tab`, Help, Docs, Settings, Operator).
- In Panel 1: Steps vertically through the list items (`.nav-item`, `.settings-nav__link`, tree rows).
- In Panel 2: Steps vertically through feed cards (`article.msg`), topic rows (`a.topic-row`), table rows (`tr.issues-row`, `tr[data-test="events-row"]`), or calendar slots.
- In Panel 3: Steps vertically through reply cards (`article.msg`) or operator inspector items.
- Stepping updates both visual focus and selection state, smoothly scrolling the target item into view using `scrollRowIntoPane`. Stepping does not wrap at panel endpoints.

### 4.3 Endpoint Jumps (`g g` / `Shift + G`)
- **`g g`**: Pressing `g` enters a 500 ms chords window. If a second `g` is pressed within that window, focus jumps immediately to the first selectable item of the current panel. If any other key is pressed or 500 ms elapses, the sequence resets.
- **`Shift + G` (`G`)**: Jumps immediately to the last selectable item of the current panel.

### 4.4 Activation & Retreat (`Enter` / `Esc`)
- **`Enter`**:
  - Panel 0: Switches to the selected rail section and advances focus to Panel 1.
  - Panel 1: Opens the selected item (channel, DM, doc, etc.), loading its contents into Panel 2 and advancing focus to Panel 2.
  - Panel 2: Opens the selected message thread or topic into Panel 3 and advances focus to Panel 3 (or opens the item's primary view).
  - Panel 3: Focuses the reply composer or activates the focused card action.
- **`Esc`**:
  - If a modal dialog, dropdown menu, point menu, or emoji picker is open: dismisses the overlay and restores focus to the triggering element (existing overlay priority).
  - If an in-place message editor or code block is active: cancels editing (existing edit priority).
  - If the Top Omnibox or a text field is focused: blurs the field and restores focus to the active panel item.
  - Otherwise, steps one panel to the left:
    - Panel 3 → closes thread pane (or leaves Panel 3) and focuses the parent row in Panel 2.
    - Panel 2 → moves focus to the selected row in Panel 1.
    - Panel 1 → moves focus to the active tab in Panel 0.
    - Panel 0 → no-op (remains at Panel 0).

---

## 5. Conflict analysis and resolutions

The application already defines single-letter shortcuts, Shift-letter shortcuts, and dialog keys. Every potential collision is mapped and resolved:

| Key Press | Context | Existing Meaning | Collision & Resolution |
|---|---|---|---|
| **`h`** | Any panel | None currently bound outside text fields. | **No conflict**. `h` moves focus to the left panel (`panel - 1`). Does not collide with `Shift + H` (which requires `shiftKey: true`). |
| **`Shift + H`** | Message card | "Hide from flow" (`MSG_SHORTCUTS`) | **Preserved**. `Shift + H` continues to hide messages. Vim navigation only acts when `!ev.shiftKey` (for `h`). |
| **`l`** | Issues view (Panel 2) | Opens "Label" picker menu (`issues.vue:2247`) | **Resolved**: In Issues view, universal `l` moves focus to Panel 3 (issue detail pane/modal). To edit labels without leaving the keyboard, users press `Shift + L` or edit via palette `>label` / cell edit. Across all other views, `l` moves to the right panel. |
| **`Shift + L`** | Message card | "Copy link" (`MSG_SHORTCUTS`) | **Preserved**. Requires Shift; `l` requires no Shift. |
| **`j` / `k`** | Message feeds | Walks message cards (`useMsgShortcuts.ts`) | **Harmonized**. Existing message stepping becomes the standard implementation for Panel 2 and Panel 3 feeds. |
| **`j` / `k`** | Channels list | Walks channel rows (`ChannelSidebar.vue`, `312ea460`) | **Harmonized**. Existing channel row stepping becomes the Panel 1 adapter. |
| **`j` / `k`** | Issues grid | Walks issue rows (`issues.vue:2233`) | **Harmonized**. Adopts universal step behavior. |
| **`Shift + K`** | Message feed | Opens kind menu (`MSG_SHORTCUTS`) | **Preserved**. Gated on `shiftKey: true`. `k` without Shift steps up. |
| **`g g`** | Any panel | Unbound (`081` §8 left sequences out) | **New sequence**. A 500 ms sequence buffer traps the second `g` and executes jump to first item. |
| **`Shift + G`** (`G`) | Any panel | Unbound in `MSG_SHORTCUTS` | **New action**. Jump to last item. Distinct from lowercase `g`. |
| **`Enter`** | Omnibox / inputs | Sends message / submits form | **Preserved**. Vim navigation ignores all key events originating within text fields (`inTypingOrOverlay`). |
| **`Enter`** | Card / Row | Opens thread / opens channel | **Harmonized**. Standardized across all 4 panels. |
| **`Esc`** | Dialog / Menu | Closes modal / menu | **Preserved with priority**. Overlays intercept `Esc` first. Only when no overlay or editor is active does `Esc` step back one panel. |
| **Arrow Keys** | All panels | Stepping and divider resizing | **Preserved**. Arrow keys run in parallel alongside `h j k l`. |

---

## 6. Architecture & technical design

### 6.1 One Unified Key Layer
No per-view or per-component duplicate listeners.
- **Pure Helper**: `src/utils/vim-nav.mjs` implements key mapping, sequence buffer (`g g`), and panel arithmetic without DOM dependencies for 100% unit testability.
- **Panel Registry**: `src/utils/vim-panels.mjs` defines the DOM selector contracts for Panels 0, 1, 2, 3 across all view types.
- **Reactive State**: `src/stores/vim-nav.ts` tracks `{ currentPanel: 0|1|2|3, lastKeys: Record<PanelId, string> }`.
- **Global Listener**: `src/composables/useVimNavigation.ts` installed once in `src/layouts/default.vue`.

```
                    +------------------------------------+
                    |        window keydown event        |
                    +------------------------------------+
                                      |
                     +----------------------------------+
                     | Is phone? typing? overlay open?  |
                     +----------------------------------+
                                  /       \
                            (Yes)/         \(No)
                                /           \
                     +-------------+    +------------------------------------+
                     | Return/noop |    | vimNavMatch(ev, buffer)            |
                     +-------------+    +------------------------------------+
                                                        |
                                        +------------------------------------+
                                        | Execute: panel change / row step / |
                                        | jump first/last / open / escape    |
                                        +------------------------------------+
                                                        |
                                        +------------------------------------+
                                        | Set DOM focus + focus ring style   |
                                        +------------------------------------+
```

### 6.2 Focus vs. Selection & The Owner Focus Rule
- **Owner Focus Rule**: A single visible focus ring, exactly one accent colour, width `<= 3px`.
- CSS variable `--vim-focus-ring`: `outline: 2px solid var(--accent, #3b82f6); outline-offset: -1px; border-radius: 4px;`.
- Roving `tabindex`: The currently selected item in each panel retains `tabindex="0"`; siblings retain `tabindex="-1"`.
- When `j`/`k` or `h`/`l` activates an item, the element receives DOM `.focus({ preventScroll: true })` and `data-vim-selected="true"`.

### 6.3 Empty, Collapsed, or Hidden Panels
- In views with `sidebar--rail` (e.g. `/docs`, `/calendar`, `/help`), Panel 1 (`.sidebar-body`) is hidden via CSS `display: none`.
- The panel resolver inspects `getClientRects().length > 0` and skip-flags.
- Navigating `l` from Panel 0 in `/docs` skips Panel 1 and directly focuses Panel 2 (`.docs-tree` / markdown content).
- Navigating `h` from Panel 2 in `/docs` skips Panel 1 and lands directly on Panel 0 (`.sidebar-rail`).
- If Panel 3 is closed (no topic open), `l` stops at Panel 2. Pressing `Enter` on a topic row or message card opens Panel 3 and moves focus into it.

### 6.4 Overlay & Dialog Suspension
- When an overlay matching `[role="dialog"][aria-modal="true"], dialog[open], .point-menu, .kind-picker, .command-palette` is open:
  - Vim navigation single-key listeners are completely suspended.
  - Key events bubble normally to the dialog or menu.
  - When the dialog closes, focus returns to the saved panel element without state loss.

### 6.5 Lazy Loading Budget (155 KB Initial Chunk Constraint)
- The global layout (`default.vue`) contains only a lightweight lazy trigger hook.
- The full navigation engine and view panel definitions load lazily via dynamic import on first interaction or mount idle (`requestIdleCallback`), strictly preserving the WUI initial bundle budget under 155 KB.

---

## 7. User stories

| ID | Priority | Role | Story | Benefit |
|---|---|---|---|---|
| **US1** | **P1** | Keyboard User | Press `j` and `k` in Panel 0 to move between rail tabs, and press `Enter` to open one. | Navigates the entire app shell without touching the mouse. |
| **US2** | **P1** | Power User | Press `l` from Panel 1 to move into the messages feed (Panel 2), walk messages with `j`/`k`, and press `l` to move into the thread replies (Panel 3). | Seamless horizontal and vertical keyboard navigation. |
| **US3** | **P1** | Reader | Press `g g` to jump to the newest/first message and `Shift + G` to jump to the oldest/last message in any active panel. | Rapid navigation across long feeds and lists. |
| **US4** | **P1** | Keyboard User | Press `Esc` in Panel 3 to close or leave the topic pane and return to the parent message in Panel 2. | Intuitive, muscle-memory reversal across panel hierarchies. |
| **US5** | **P1** | Writer | Click into the Omnibox or comment box and type `h j k l` without triggering navigation. | Text entry remains 100% unaffected. |
| **US6** | **P2** | Operator | Navigate issues, calendar events, docs, and settings panels using the exact same `h j k l` chords. | Unified mental model across the entire application. |
| **US7** | **P2** | Member | Turn off vim navigation under **Settings → Behaviour → Keyboard shortcuts** if preferred. | Preserves user choice and accessibility customization. |

---

## 8. Functional requirements

| ID | Description | Status |
|---|---|---|
| **FR-001** | Support `h`, `j`, `k`, `l` panel and row navigation across Panels 0, 1, 2, 3 on all desktop views. | Planned |
| **FR-002** | Support `g g` (within 500 ms) and `Shift + G` to jump to the first and last selectable item in the active panel. | Planned |
| **FR-003** | Support `Enter` to open/activate the selected item and `Esc` to retreat one panel to the left. | Planned |
| **FR-004** | Parallel support for arrow keys (`ArrowUp`, `ArrowDown`, `Home`, `End`) alongside vim keys. | Planned |
| **FR-005** | Inactivity in all text fields (Omnibox, textareas, inputs, contenteditables): literal letters are typed. | Planned |
| **FR-006** | Complete deactivation on mobile / phone viewports (`<= 820px`). | Planned |
| **FR-007** | Honor personal claim `keyboard_shortcuts: false`: single-letter vim keys do nothing when disabled. | Planned |
| **FR-008** | Dynamic skip of collapsed, hidden, or unmounted panels when navigating horizontally with `h` and `l`. | Planned |
| **FR-009** | Enforce single focus ring colour `<= 3px` on all vim-focused elements. | Planned |
| **FR-010** | Suspension of vim navigation while modals, sheets, dialogs, or point menus are open. | Planned |
| **FR-011** | Restore focus and selection memory when returning to a previously active panel. | Planned |
| **FR-012** | Lazy loading of the vim navigation engine to remain within the 155 KB initial chunk budget. | Planned |
| **FR-013** | Documentation in `csi-spl-doc/doc/help/keyboard-shortcuts.md` and the `Shift + ?` overlay. | Planned |

---

## 9. Acceptance criteria & test list

### 9.1 Unit Tests (`tests/unit/vim-nav.test.mjs`, `tests/unit/vim-panels.test.mjs`)
- `vimNavMatch`: detects `h`, `j`, `k`, `l`, `Enter`, `Esc`, `G`, and two sequential `g` presses within 500 ms.
- `vimNavMatch`: ignores chords when `ctrlKey`, `metaKey`, or `altKey` is held.
- `vimNavMatch`: returns null when target is an input, textarea, or contenteditable.
- `nextPanel`: correctly calculates horizontal transitions 0 ↔ 1 ↔ 2 ↔ 3 and skips invisible panels.
- `stepItem`: advances index with bounds checking (no out-of-bounds wrapping).

### 9.2 E2E Tests (Extending EXISTING test files only)
- **`tests/e2e/pane-keys.test.mjs`**:
  - Test `h` and `l` transitioning focus across Panels 0, 1, 2, and 3 on desktop.
  - Test `Esc` stepping backward from Panel 3 to Panel 2, and Panel 2 to Panel 1.
  - Test `g g` and `Shift + G` jumping to first and last message cards.
- **`tests/e2e/channel-order.test.mjs`**:
  - Test `j` and `k` walking the Channels list in Panel 1, and `Enter` loading the channel into Panel 2.
- **`tests/e2e/msg-shortcuts.test.mjs`**:
  - Test `j` and `k` walking message cards in Panel 2 and reply cards in Panel 3.
  - Verify `Shift + H`, `Shift + K`, `Shift + U`, and `Shift + B` continue functioning alongside vim navigation.
- **`tests/e2e/command-palette.test.mjs`**:
  - Control test: When `keyboard_shortcuts` setting is turned off, `h j k l` do nothing.
- **`tests/e2e/slash-focus.proof.mjs`**:
  - Control test: When typing in the Omnibox or a search filter, `h`, `j`, `k`, `l`, `g`, `G` insert characters and do not move panels.
- **`tests/e2e/issues-views.test.mjs`**:
  - Test `h` / `l` transitioning between epics (Panel 1), issue rows (Panel 2), and issue details (Panel 3).
- **`tests/e2e/docs.test.mjs`**:
  - Test `h` / `l` transitioning between rail (Panel 0), folder tree (Panel 1), and document text (Panel 2).
- **`tests/e2e/help-two-panes.test.mjs`**:
  - Test `j` / `k` walking help topics and `l` moving into help content.

---

## 10. Overlaps

| With | Relationship |
|---|---|
| **081 Command Palette & Pane Keys** | Vim navigation complements `F6` (which cycles forward) with direct directional `h`/`l` movement. Both share the same underlying pane focus store. |
| **050 Panel Collapse** | Vim navigation respects panel collapse states: a collapsed panel strip is skipped during horizontal `h`/`l` transit. |
| **078 Desktop Thread Layout** | Vim navigation directly operates over the 3-pane layout containers established by 078. |
| **Channel Keys (`312ea460`)** | Channel list keyboard walking is generalized into the standard Panel 1 vim adapter. |
| **Shift+B / Shift+U (`c-496`, `c-499`, `70384d49`)** | Existing jump shortcuts between Panel 3 replies (Shift+B) and Panel 2 starter cards (Shift+U back) remain fully active. |

---

## 11. Not in scope

- Mobile / phone support (explicitly declined by owner in Q5).
- Custom key remapping / user-defined keybindings.
- Complex multi-key Vim command mode (`:w`, `/search`, visual block mode).
- New standalone E2E test files (violates shard control; existing test suites are extended).

---

## 12. Open questions

All core design choices were confirmed by the owner in t1 message `553cf543` and authorized for immediate implementation in `c503043c`. Zero blocking open questions remain.

---

## 13. Version log

| Version | Date | Author / Lane | Summary |
|---|---|---|---|
| **v1.0** | 2026-10-07 | a-501 | Complete v1.0 specification of Vim-style 4-panel navigation across the entire UI. |

<!-- version: 1.0.0 · updated: 2026-10-07 · last-edit: 2026-10-07T12:15:00Z -->
