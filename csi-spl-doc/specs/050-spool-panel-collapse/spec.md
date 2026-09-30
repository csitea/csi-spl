# Feature Specification: Collapse / expand triangles on the vertical panels

**Feature ID**: `050-spool-panel-collapse` · **Milestone**: M3 · **Status**: ANSWERED — implementing
**Created**: 2026-09-29 · **Lane**: CLE-35101 (panel-triangles, WUI) · **Ticket**: CLE-35101 · **Issue**: SPL-1186
**Authority**: this file. It touches `layouts/default.vue`, a new toggle component, and reuses
`SPL-1133` (`close_buttons`, the Win/Mac corner) and the pane-width plumbing of `usePaneWidths` /
`PaneDivider.vue`. Persistence coordinates with `046-spool-tenant-settings` / CLE-35099
(per-tenant settings + PaneDivider persistence). RTL depends on what `app.vue` already sets.

## 1. The owner's request, verbatim

prd t1 `#spool-hub-devel` topic `d2c03bc9-dc38-4e60-a071-674fabcafeae`, 2026-09-29:

> there should be a simple triangle-shaped small icon at the top right or top left corner of each
> of the 3 vertical panels (depending on whether the users use the Windows or the Mac placement);
> those triangles should point to either close or open the panel to the left or from the left (and
> in Hebrew the other direction)

> ask me questions if these specs are too vague: better to spec it first properly than to be sorry
> and fix it later

## 2. What exists today (measured on this branch, off `origin/master`)

| concern | where | today |
|---|---|---|
| 3-pane desktop shell (> 820 px) | `csi-spl-wui/src/layouts/default.vue:12-69` | `.spool-shell` flex row: `ChannelSidebar` (left) · `.spool-main` slot = feed (middle) · `LiveTopicPane`/`TopicPane` (right, only when a topic is open) |
| resizable dividers | `csi-spl-wui/src/components/PaneDivider.vue` | pointer + keyboard resizers between panels; `@input`/`@reset` |
| pane widths | `csi-spl-wui/composables/usePaneWidths.ts`, `utils/pane-widths.mjs` | `localStorage` key `spool.pane-widths`, per-device (not per-tenant yet); CSS vars `--sidebar-w` / `--topic-w`; sidebar narrows to a 72 px rail at ≤ 800 px (`SIDEBAR_NARROW_MAX`) |
| right pane close X | `TopicPane.vue:21`, `LiveTopicPane.vue:21` via `UiCloseButton` | calls `useTopicStore().close()` — clears the topic (parentTaskId, target, rootMsg, born) |
| Win/Mac close corner (SPL-1133) | `UiCloseButton.vue`, `utils/view-prefs.mjs:70` | per-person session claim `close_buttons` (`mac` = top-left default, `windows` = top-right); mirrored on `<html data-close-buttons>` |
| per-tenant setting pattern | `composables/useChannelOrder.ts`, `stores/access.ts` | read from `access.me.*`, save `PUT /v1/me/*`, debounced + optimistic |
| RTL / Hebrew | `nuxt.config.ts:195` (`he` → `dir:'rtl'`), `app.vue:27-40` | ONLY `<html dir="rtl">` + a few CSS responders. There is **no** mirrored 3-pane layout — the sidebar stays on the left in Hebrew today. |
| phones (≤ 820 px) | `composables/useMobileStack.ts` | one panel at a time; no side-by-side, so no collapse triangles |
| e2e | `csi-spl-wui/tests/e2e/*.test.mjs` (puppeteer) | e.g. `close-buttons.test.mjs`, `channel-order.test.mjs` |

## 3. Design (owner's answers folded in — d2c03bc9, 2026-09-29 14:31–14:36Z)

### 3.1 Which panels collapse — **all three** (Q1)
The owner: "the 3 big vertical panels, in the channels view: the channels, the topic panel and the
threads panel." So each of the three gets a triangle: the left **channels** sidebar, the middle
**topic** feed (`.spool-main`), and the right **threads** pane. The middle is included by explicit
request; when collapsed it yields its space to the neighbours.

### 3.2 Collapsed state — **thin strip** (Q2)
A panel collapses to a **thin strip** (~14 px) that still holds the triangle, so re-opening is always
discoverable and the triangle never jumps onto a neighbour. Expanding restores the last width.

### 3.3 Triangle placement & direction — **bottom corner** (Q3 + correction)
- The triangle sits in the panel's **bottom** corner (owner correction: "at the bottom of the panels
  not on the top"), on the side the Win/Mac setting dictates: `close_buttons = mac` → bottom-**left**,
  `windows` → bottom-**right** (reuse `closeButtonShown`, the same left/right rule as the close X, only
  anchored to the bottom).
- Direction, taken literally from the owner ("point to either close or open the panel to left or from
  left, and in Hebrew the other direction"), **uniform across all three panels**:
  - open → **◀** (close, the panel goes to the left)
  - collapsed strip → **▶** (open, the panel comes from the left)
  - RTL (Hebrew, `<html dir="rtl">`): mirrored — open **▶**, collapsed **◀**.

> **Superseded — see §3.3.1.** The "uniform ◀/▶" rule above was the first cut. The owner then asked
> (prd t1 topic 80e40aca) that each triangle "point to the direction of the collapse or the expansion
> of the control". CLE-77809 made the glyph point the way the panel *moves*; CLE-77815 made that
> direction derive from the panel's **actual docked position** instead of the Win/Mac corner, fixing
> the both-collapsed case. §3.3.1 is the current rule.

### 3.3.1 Triangle direction — the current rule (CLE-77809, CLE-77815)

The glyph points the way the panel will **move** when clicked: while **open** it points toward the edge
it will collapse (dock) to; while **collapsed** the strip points back toward the space it expands into.
The corner from §3.3 still decides only *where the toggle sits*, no longer its direction.

The dock edge is derived from the panel's **actual position** in the flex row `[channels · topic ·
threads]`, not from the corner rule. The **filler** pane (`fillerPane`) takes the slack, so every other
panel packs to the edge *away* from it:

- **channels** is the leading panel → always docks to inline-**start** (points ◀ open, ▶ collapsed);
- **threads** is the trailing panel → always docks to inline-**end** (points ▶ open, ◀ collapsed);
- **topic** (middle) docks to inline-**start** when the filler is to its right (an open thread pane),
  and to inline-**end** when the filler is to its left (the thread pane closed or itself collapsed).

The bug this fixed (owner topic 80e40aca): with **messages + thread both collapsed** the channels pane
fills and both strips sit on the right, so both must point **◀**; the old corner rule made the middle
strip point ▶ into the edge. The two collapsed strips are also widened to a ≥24 px hit target and given
a gap + hairline seam so they no longer crowd, each keeping a panel-naming tooltip ("Expand messages" /
"Expand thread").

- **Helper (pure, framework-free):** `csi-spl-wui/src/utils/pane-collapse.mjs`
  - `collapseDir(pane, collapsed, topicOpen)` → the dock edge (`'start'|'end'`);
  - `arrowPointsEnd(collapsed, pane, collapsedMap, topicOpen)` → the glyph direction (true = ▶ / inline-end);
  - `fillerPane(collapsed, topicOpen)` → the pane that absorbs the slack.
- **Consumed by** `components/PaneCollapseToggle.vue` (reads the shared `pane-collapse` store + the
  topic/live stores for `topicOpen`); CSS renders `--point-start` / `--point-end`, RTL-mirrored via
  logical borders.
- **Tests:** the full `2^3` collapsed-state × `topicOpen` matrix in
  `csi-spl-wui/tests/unit/pane-collapse.test.mjs`, and the both-collapsed browser case at 1440 & 2560
  (case **B**) in `csi-spl-wui/tests/e2e/panel-collapse.test.mjs`.

### 3.4 The threads pane: triangle vs the existing X — **keep both** (Q4, my default; owner may flip)
The top **X closes** the thread (clears the topic store); the bottom **triangle collapses** it to the
strip but keeps the topic loaded (re-open restores it). At opposite ends they never collide. Posted to
the owner that I proceed with keep-both unless he wants the triangle to replace the X.

### 3.5 Persistence — **remembered** (Q5)
The collapsed state is persisted so it survives a reload. Storage split agreed with CLE-35099
(SPL-1182): they own the divider widths (`pane_sizes`, moving to `tenant_memberships.settings` per
person+tenant); I own the collapsed flags under the sibling key **`pane_collapsed`**, value
`{channels:bool, topic:bool, threads:bool}`. To stay fully decoupled while SPL-1182 lands, I keep
`pane_collapsed` in its own module + localStorage key `spool.pane-collapsed` now, shaped so CLE-35099
lifts it to the account with no reshape. No edits to `pane-widths.mjs` / `usePaneWidths.ts` /
`PaneDivider.vue`.

### 3.6 RTL — **no special layout** (Q6)
The owner: "no special layout for it required — continue with the current setup." So RTL only
**mirrors the triangle glyph** via `dir` (§3.3), matching the existing `<html dir="rtl">`. The panes
keep their left-to-right order in Hebrew, as today.

### 3.7 Keyboard + aria — **no shortcut** (Q7)
No keyboard shortcut for now (owner). Each triangle is still a real `<button aria-expanded>` with an
`aria-label`, reachable by Tab + Enter/Space.

### 3.8 Phones (≤ 820 px) — excluded
The mobile stack shows one panel at a time, so there is nothing to collapse. The triangles render only
in the desktop/tablet shell.

## 4. Acceptance (e2e, puppeteer)
1. Desktop shell: a triangle in the **bottom** corner of each of the 3 panels, on the side the
   `close_buttons` claim dictates (mac = left, windows = right).
2. Click collapses the panel to its strip; `aria-expanded=false`; the glyph flips ◀→▶.
3. Click again restores the previous width; `aria-expanded=true`.
4. Collapsed state survives a reload (localStorage `spool.pane-collapsed`).
5. RTL: with `he` locale the glyph mirrors (▶ open / ◀ collapsed).

## 5. Out of scope
- A full RTL pane reorder. - Phone (≤ 820 px) collapse. - Moving `pane_collapsed` to the account
  (CLE-35099's SPL-1182 lifts it later). - Changing PaneDivider persistence itself (CLE-35099 owns it).

## 6. Owner answers (verbatim, d2c03bc9)
1. "the 3 big vertical panels … the channels, the topic panel and the threads panel"
2. "collapse = thin strip"
3. "Mac = top-left, Windows = top-right yes" + "actually the triangle should be at the bottom of the
   panels not on the top" → bottom-left (mac) / bottom-right (windows)
4. (pending; proceeding with keep-both — X closes, triangle collapses)
5. "the collapsed state should be remembered"
6. "no special layout for it required … continue with the current setup"
7. "no keyboard shortcut for now needed"
