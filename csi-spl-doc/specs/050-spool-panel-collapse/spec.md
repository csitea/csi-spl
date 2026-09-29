# Feature Specification: Collapse / expand triangles on the vertical panels

**Feature ID**: `050-spool-panel-collapse` · **Milestone**: M3 · **Status**: SPEC — awaiting owner answers
**Created**: 2026-09-29 · **Lane**: CLE-35101 (panel-triangles, WUI) · **Ticket**: CLE-35101
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

## 3. Design (pending the owner's answers in §6)

### 3.1 Which panels collapse
The middle feed (`.spool-main`) is the primary content and has no outer edge — it always fills the
space the side panels release. So the triangles live on the **two side panels**: the left
`ChannelSidebar` and the right topic pane. (Owner Q1.)

### 3.2 Collapsed state
A panel collapses to a **thin strip** (~14 px) that still holds the triangle, so re-opening is
always discoverable and the triangle never has to jump onto a neighbour. Collapsing gives the
released width to the middle feed; expanding restores the last dragged width. (Owner Q2.)

### 3.3 Triangle placement & direction
- The triangle sits in the panel's **top corner**, in the SAME corner as the close X: `close_buttons
  = mac` → top-left, `windows` → top-right (reuse `closeButtonShown`). (Owner Q3 for the corner.)
- Direction points the way the panel will move:
  - Left sidebar: open shows ◀ (collapse toward the left edge); collapsed shows ▶ (expand from the left).
  - Right pane: open shows ▶ (collapse toward the right edge); collapsed shows ◀ (expand).
  - RTL (Hebrew, `<html dir="rtl">`): the glyph mirrors with `dir` — see §3.6.

### 3.4 The right pane: triangle vs the existing X
The triangle **collapses** (hides the pane to its strip but KEEPS the topic loaded; re-open restores
it) — a different action from the X, which **closes** (clears the topic store). Recommend keeping
both, side by side. (Owner Q4.)

### 3.5 Persistence
Collapsed state persisted so it survives a reload, alongside the pane widths. Recommend following
whatever CLE-35099 lands for PaneDivider persistence (per-tenant on the account), so the panel layout
travels with the person. Until then it rides the existing `spool.pane-widths` localStorage shape.
(Owner Q5.)

### 3.6 RTL
There is no full RTL layout today (the sidebar does not move to the right in Hebrew). So for now RTL
only **mirrors the triangle glyph** via `dir`, matching the existing `<html dir="rtl">`. A full
mirrored pane order (sidebar on the right in Hebrew) is a larger change, out of scope unless the
owner wants it. (Owner Q6.)

### 3.7 Keyboard + aria
Each triangle is a real `<button aria-expanded="true|false">` with an `aria-label`
(`Collapse sidebar` / `Expand sidebar`, `Collapse thread` / `Expand thread`), reachable by Tab and
Enter/Space. Optional shortcut (Owner Q7).

### 3.8 Phones (≤ 820 px)
Excluded: the mobile stack shows one panel at a time, so there is nothing to collapse. The triangles
render only in the desktop/tablet shell.

## 4. Acceptance (e2e, puppeteer)
1. Desktop shell: a triangle in the top corner of the left sidebar and of the open right pane, in the
   corner the `close_buttons` claim dictates (mac vs windows).
2. Click collapses the panel to its strip and gives the width to the feed; `aria-expanded=false`.
3. Click again restores the previous width; `aria-expanded=true`.
4. Collapsed state survives a reload (persistence).
5. RTL snapshot: with `he` locale the glyph mirrors (only if §3.6 stays glyph-only).

## 5. Out of scope
- Collapsing the middle feed. - A full RTL pane reorder. - Phone (≤ 820 px) collapse.
- Changing PaneDivider persistence itself (CLE-35099 owns it).

## 6. Open questions to the owner (posted as one blocker in `d2c03bc9`)
See the blocker message; answers land back in this file's §3 before any code.
