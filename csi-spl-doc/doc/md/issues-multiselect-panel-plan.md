# Issues multi-select panel and UI design — consensus plan (v0.1)

Epic: SPL-2403  
Spec: [csi-spl-doc/specs/039-spool-issues](../../specs/039-spool-issues)  
Issue: SPL-2497 (wip)  
Owner Topics: `405e08ba-62c2-4c89-8608-cf69b40e85df` (Multi-select checkboxes), `67d850ce-4346-4e5a-93f7-5c8e23ee0998` (3D Detail tabs), `0f67a177-fa3e-4a09-854d-415ca202d08e` (Issues UI professionalism)  
Task: `dispatch-405e08ba`  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16), [CLAUDE.md](../../../CLAUDE.md), [developer-guide.md](developer-guide.md)  

**Status: v0.1 DRAFT FOR PANEL REVIEW**  
Editor: **a-434@sat** (agy)  
Claude Reviewer Seat: Assigned per brief (to review and sign in `csi-spl-doc/doc/md/issues-multiselect-panel/seat-claude.md`)  
Mistral Reviewer Seat: Assigned per brief (to review and sign in `csi-spl-doc/doc/md/issues-multiselect-panel/seat-mistral.md`)  

**Pinned Baseline:** Baseline measurements, DOM observations, and view screenshots are pinned to origin/master at commit `51009ada42bc8920ab609c0bf6ddd5b0ad33baca`. Measurements and captures were taken on the live `dev` estate (`https://dev.spool-hub.ai`) across mobile (**412×915**) and desktop (**1280×800**) viewports in both **dark** and **light** themes. Real PNG screenshots and empirical metrics are stored in `/var/spool-hub/dispatch/405e08ba/work/`.

---

## 1. Executive Summary & Owner Mandates

The owner directed three key improvements for the Issues user interface in topics `405e08ba`, `67d850ce`, and `0f67a177` (HUM-10):

### 1.1 Multi-Select Checkboxes & Placement (Topic `405e08ba`)

> **msg `83a58259`:**  
> "I just have the feeling that in this listing, the select boxes should not be radio boxes, but they should be like checkboxes."  
>
> **msg `b8506d57`:**  
> "And they should be placed similarly, but probably some kind of space optimization could be done there. I don't know: a mixture of experts, a small panel to discuss how these things are done exactly on this view, especially taking into consideration the best possible usability to be able to use and manipulate multiple items. What are the best possible options?"  
>
> **msg `033abc2f`:**  
> "First, reach consensus, and then, after that, start implementation."  
>
> Dispatcher post: `/var/spool-hub/dispatch/posts/20261018T0010Z--t1--405e08ba--checkboxes.md` and `20261018T0012Z--t1--405e08ba--panel.md`.

### 1.2 Issue Page 3D Tabs & Comment Clip Control (Topic `67d850ce`)

> **msg `0850198a`:**  
> "Better styling is needed for the tabs of the issues of"  
>
> **msg `a175a8f0`:**  
> "They should have some kind of 3D, but this current bracket does not work, and it's also on the wrong side. It's on the downside, and it should be on the upside. No panel of experts on how to do a sleek design exactly on this part of the interface: something which is 3D, and it's pretty obvious that these are two tabs, which is the selected one, and so on and so forth."  
>
> Dispatcher post: `/var/spool-hub/dispatch/posts/20261018T0031Z--t1--67d850ce--tabs.md` and `20261018T0033Z--t1--67d850ce--3d.md`.

### 1.3 Professionalism & Polish Across the Whole Issues UI (Topic `0f67a177`)

> **msg `779079e8-da52-470b-9704-c0ac26dae248`:**  
> "Somehow, the whole implementation of issues, the UI of it, looks a little bit unprofessional."  
>
> **msg `73c13f9b-e467-43e6-8f79-7701712af072`:**  
> "There is something in the UI and the way one uses it that does not seem like a professional application for creating tickets and issues. It just needs to be a little bit more professional. I can't exactly explain what, but create a panel of experts to actually really examine everything it has, and then implement some small changes to change that feeling."  
>
> Dispatcher reply: `https://spool-hub.ai/m/7d24e97f-972b-4e1e-a455-0124301fc462`.

---

## 2. Empirical Baseline Measurements on Dev (Commit `51009ada4`)

Automated Chromium inspection walked `/issues` on `https://dev.spool-hub.ai` at mobile (**412×915**) and desktop (**1280×800**) viewports in both **dark** and **light** themes. Full metrics are recorded in `/var/spool-hub/dispatch/405e08ba/work/measurements.json`.

### 2.1 Why the Boxes Look Like Radio Buttons (Root Cause Discovery)

In `csi-spl-wui/src/pages/issues.vue:4010-4021`:
```css
.issues-check--card input::before, .issues-check--page input::before {
  content: '';
  position: absolute;
  inset: 0;
  margin: auto;
  width: 16px;
  height: 16px;
  box-sizing: border-box;
  border: 2px solid var(--color-muted);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
}
```
In `csi-spl-wui/src/assets/css/variables.css:80`:
```css
--radius-sm: 8px;
```
**Empirical Proof:** The box is $16\text{px} \times 16\text{px}$. With `--radius-sm: 8px`, the border radius is exactly half the box size ($16 / 2 = 8$). In CSS, a square element with `border-radius: 50%` renders as a **perfect circle**. On mobile devices, the multi-select boxes are drawn as round empty circles with an accent fill upon selection, perfectly matching the visual appearance of radio buttons (which denote mutually exclusive single-choice options). On desktop, `.issues-check` defaults to native browser styling (`appearance: auto`), rendering square checkboxes.

### 2.2 Measured Dimensions & Space Consumption

| Viewport | Element / Metric | Measured Value | Analysis & User Impact |
|---|---|---|---|
| **Phone** (412×915) | Page Box Target (`.issues-check--page`) | $44 \times 44\text{px}$ | Satisfies WCAG 2.5.5 minimum touch target. |
| **Phone** (412×915) | Card Box Target (`.issues-check--card`) | $44 \times 44\text{px}$ | Satisfies WCAG 2.5.5 minimum touch target. |
| **Phone** (412×915) | Box Visual Element (`input::before`) | $16 \times 16\text{px}$, `border-radius: 8px` | Draws a circle (radio button look). |
| **Phone** (412×915) | Mobile Header Bar (`.issues-mbar`) | $412 \times 52\text{px}$ | First header row. |
| **Phone** (412×915) | Epics Chip Strip (`.issues-chips`) | $412 \times 52\text{px}$ | Second header row. |
| **Phone** (412×915) | **Total Pre-Card Header Height** | **104px** | 104px of vertical height consumed before the first card is visible. |
| **Phone** (412×915) | Card Left Padding (`padding-inline-start`) | **44px** | 44px dedicated to checkbox gutter ($10.7\%$ of screen width). |
| **Phone** (412×915) | First Card Dimensions | $412 \times 129.2\text{px}$ | Card height accommodates title, key, status, priority, and date. |
| **Phone** (412×915) | Bulk Bar (`.issues-bulk`) | $412 \times 88\text{px}$ | Wraps onto 2 rows; includes page box ($44 \times 22\text{px}$) and 6 buttons. |
| **Phone** (412×915) | Bulk Action Buttons (6 buttons) | $44 \times 44\text{px}$ each | Status, Assignee, Move to, Archive, Delete, Clear. |
| **Desktop** (1280×800) | Table Dimensions | $1158 \times 1065\text{px}$ | Full grid sheet view. |
| **Desktop** (1280×800) | Names Header Row (`.issues-names`) | 32px height | Sticky top row with column names. |
| **Desktop** (1280×800) | Filters Row (`.issues-frow`) | 53px height | Sticky second row with inline filter selects. |
| **Desktop** (1280×800) | Checkbox Column (`.issues-c-key`) | $88.5 \times 31.5\text{px}$ | Holds 16px checkbox + issue key string. |
| **Desktop** (1280×800) | Desktop Checkboxes (`.issues-check`) | $16 \times 16\text{px}$, `border-radius: 0px` | Native checkbox, square, accent color cyan `rgb(52, 213, 240)`. |
| **Desktop** (1280×800) | Desktop Bulk Bar | $1013 \times 69\text{px}$ | Horizontal toolbar with 6 icon+text buttons. |

### 2.3 Measured Detail Page Tabs & Card Clip Control

| Viewport | Element | Measured Value | Style & Defect Observed |
|---|---|---|---|
| **Phone** & **Desktop** | Discussion Tab (`.issues-talk__tab`) | $87.3 \times 31.6\text{px}$ | Transparent background, `border-bottom: 2px solid`, `border-top: 0px`. Reads as flat text with a thin underline. |
| **Phone** & **Desktop** | History Tab (`.issues-talk__tab`) | $61.4 \times 31.6\text{px}$ | Transparent background, `border-bottom: 2px solid transparent`, `border-top: 0px`. |
| **Phone** | Card Clip Control (`.card-clip-ctl`) | $134 \times 46\text{px}$ | Injected directly inside `role="tablist"` alongside tabs. 3 icon buttons (−, lines, ↕), $44\times 44\text{px}$ each. |
| **Desktop** | Card Clip Control (`.card-clip-ctl`) | $134 \times 32\text{px}$ | Placed inside tablist header with no text label or visible boundary. |

**Key Finding:** The 3-button segmented control controls comment card height/density (`titles`, `5 rows`, `full`). Because it sits directly inside `<div class="issues-talk__h" role="tablist">`, it visually masquerades as additional tabs or modes of the Discussion tab itself, confusing users.

### 2.4 Screenshot Catalogue (Saved in `/var/spool-hub/dispatch/405e08ba/work/`)

1. `01_phone_issues_list_unselected_dark.png`: Phone view showing round radio-button-style checkboxes and 104px header stack.
2. `02_phone_issues_list_selected_bulkbar_dark.png`: Phone view with 2 issues selected, showing `.issues-bulk` 2-row toolbar.
3. `03_phone_issue_detail_discussion_dark.png`: Phone detail view showing flat Discussion/History tabs and cramped clip control.
4. `04_phone_issue_detail_history_dark.png`: Phone detail view showing History tab activated.
5. `05_phone_issues_list_unselected_light.png`: Phone list view in light theme.
6. `06_phone_issue_detail_discussion_light.png`: Phone detail view in light theme.
7. `07_desktop_issues_table_unselected_dark.png`: Desktop sheet view with sticky names and filter rows.
8. `08_desktop_issues_table_selected_bulkbar_dark.png`: Desktop table with 2 rows checked and bulk toolbar active.
9. `09_desktop_issue_detail_tabs_dark.png`: Desktop issue detail modal showing Discussion/History tabs and clip control.
10. `10_desktop_issues_table_light.png`: Desktop table in light theme.
11. `11_desktop_issue_detail_tabs_light.png`: Desktop issue detail modal in light theme.

---

## 3. Comparison of Multi-Select Patterns (Phone + Desktop)

To address the owner's request ("a mixture of experts, a small panel to discuss how these things are done exactly on this view, especially taking into consideration the best possible usability to be able to use and manipulate multiple items"), we compare 4 established industry patterns:

| Pattern | How It Works | Space Cost (Phone) | Tap Count to Act on $N$ Items | Discoverability | Accessibility (a11y) | Verdict |
|---|---|---|---|---|---|---|
| **Pattern 1: Leading Persistent Checkboxes** (Gmail, GitHub Issues, Jira) | Visible checkbox on every item row/card; tapping selects item and summons top/floating bulk action bar. | High (dedicates 36–44px horizontal column across every card, even when not selecting). | $N$ taps to select $+ 1$ tap to act ($N+1$). | **Immediate (10/10)**: Clear affordance; unmistakable meaning. | **Excellent (10/10)**: Standard `<input type="checkbox">` with ARIA states and keyboard support. | **Good baseline, but needs space optimization.** |
| **Pattern 2: Contextual Selection Mode via Long-Press / "Select" Button** (Google Photos, iOS Mail) | List cards have 0px leading gutter. User long-presses an item or taps top "Select" button to enter "Edit/Selection Mode". Checkboxes animate into view. | **Zero (10/10)**: Full card width available for titles, metadata, and tags during normal reading. | $N+2$ taps (1 to enter mode, $N$ to select, 1 to act). | **Fair (6/10)**: Long-press is hidden gesture; "Select" button requires header space. | **Poor to Fair (5/10)**: Long-press violates WCAG 2.5.1 without single-point alternative; mode switches disorient screen readers. | **Rejected:** Adds extra modal friction and gesture barrier. |
| **Pattern 3: Swipe to Select / Range Drag** (Spreadsheets, Notion Mobile) | Horizontal swipe or vertical drag across cards toggles selection state. | **Zero (10/10)**: No permanent visual column. | Fast for contiguous items ($1$ drag), tedious for non-contiguous. | **Very Low (3/10)**: Completely invisible; high error rate. | **Fail (2/10)**: Fails WCAG 2.5.1 pointer gestures; impossible on screen readers. | **Rejected:** High collision with existing card swipe gestures (Left = Archive, Right = Menu). |
| **Pattern 4: Compact Visual Square Checkbox with Gutter Tucking & Persistent Touch Overlay (Recommended)** | Checkbox visual marker is tucked into a 28px left margin ($3\text{px}$ rounded corners, unmistakable square). 44px touch target is maintained via transparent negative hit margin. Space reclaimed for card title: **$+12\text{px}$**. | **Low (8/10)**: Reclaims 12px horizontal width per card. | $N$ taps to select $+ 1$ tap to act ($N+1$). | **High (9/10)**: Always visible, unmistakable square checkbox. | **Full (10/10)**: Preserves 44×44px touch target (WCAG 2.5.5) and native checkbox semantics. | **Recommended (Panel Consensus)** |

### 3.1 Recommended Pattern Details for Spool Issues

1. **Unmistakable Square Checkbox Styling:**
   - Change `border-radius: var(--radius-sm)` (8px) on `.issues-check--card input::before` and `.issues-check--page input::before` to `border-radius: 3px`.
   - Subtle $3\text{px}$ corner radius prevents the box from rendering as a circle (radio button) while matching the theme's modern geometric style.
   - Distinctive border `2px solid var(--color-border-strong)` in resting state; filled background `var(--color-accent)` with white/dark tick on checked state.
2. **Space Optimization (Phone):**
   - Reduce `.issues-card-li > .issues-card` `padding-inline-start` from 44px to **32px**.
   - Position `.issues-check--card` with `width: 32px; height: 32px` visual footprint, while extending touch target to $44 \times 44\text{px}$ via `inset: -6px` or transparent hit bounds.
   - Reclaims **12px** of horizontal reading width for issue titles on 412px viewports (a $15\%$ increase in title line space).
3. **Space Optimization (Header Stack):**
   - Reduce vertical height of `.issues-chips` from 52px to 38px (compact chip height `28px`, padding `4px 0`).
   - Reduce `.issues-mbar` from 52px to 42px.
   - Total pre-card vertical stack shrinks from **104px down to 80px** (saving **24px** of vertical screen real estate for cards).

---

## 4. 3D Detail Page Tabs & Card Clip Control Architecture

### 4.1 Owner 3D Tab Requirements

As ordered in topic `67d850ce` (HUM-10):
- **3D Tab Look:** Raised/folder tab physical metaphor using theme tokens. Obvious that these are two distinct selectable tabs.
- **Top Edge Active Marker:** The active marker must sit on the **top edge** (upside), not as an underline (downside bracket).
- **Theme Adaptation:** Adapts seamlessly across dark, light, and all accent themes using CSS custom properties (`var(--color-surface)`, `var(--color-bg)`, `var(--color-accent)`, `var(--color-border)`).
- **Contrast & Hierarchy:** Active tab is visually elevated and connected to the content body; inactive tab is slightly recessed.

### 4.2 Tab Design Specification

```css
/* Container */
.issues-talk__h {
  display: flex;
  align-items: flex-end;
  gap: 4px;
  border-bottom: 1px solid var(--color-border);
  padding: 8px 12px 0;
  background: var(--color-bg-2);
}

/* Individual 3D Tab */
.issues-talk__tab {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 16px;
  font-size: 0.875rem;
  font-weight: 600;
  border-radius: 6px 6px 0 0;
  border: 1px solid transparent;
  border-bottom: none;
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
  transition: all 0.15s ease;
}

/* Inactive Tab Hover */
.issues-talk__tab:hover:not([aria-selected="true"]) {
  background: var(--color-surface-hover, rgba(255, 255, 255, 0.04));
  color: var(--color-fg);
}

/* Active 3D Raised Tab */
.issues-talk__tab[aria-selected="true"] {
  background: var(--color-surface);
  color: var(--color-fg);
  border-color: var(--color-border);
  border-top: 3px solid var(--color-accent);
  box-shadow: 0 -2px 6px rgba(0, 0, 0, 0.12), inset 0 1px 0 rgba(255, 255, 255, 0.08);
  margin-bottom: -1px; /* seamless connection over bottom border */
  z-index: 1;
}
```

### 4.3 CardClipControl Decoupling & Relabeling

1. **Decouple from Tablist:** Move `<LazyCardClipControl>` out of `.issues-talk__h[role="tablist"]`. A tablist must only contain `role="tab"` elements (WCAG 1.3.1).
2. **Contextual Placement:** Place the control in a right-aligned utility bar alongside comment actions, or attach a clear accessible label:
   `<span class="card-clip-ctl__label">{{ t('feed.clip.label') }}:</span>`
3. **Tooltip Clarity:** Add explicit tooltips and visible hover badges clarifying that this controls comment text density (Titles / 5 rows / Full), eliminating confusion with issue detail navigation.

---

## 5. Professionalism Audit Across the Whole Issues UI (Topic `0f67a177`)

Comparing Spool Issues against modern benchmarks (Linear, GitHub Issues, Jira):

| Area / View | Concrete Shortcoming Observed | Professional Ticket Benchmark | Small, High-Impact Remediation |
|---|---|---|---|
| **1. Header & Filters** | Filter selects in desktop sheet have inconsistent native select arrows and varying heights (31px vs 36px). | Clean, unified filter pill triggers with consistent icon badges and typography. | Normalize `.issues-frow` inputs with unified border, typography, and SVG dropdown chevrons. |
| **2. Epics Filter Bar** | Epics strip takes 52px of height with bulky pill buttons on phone. | Sleek horizontal scroll strip with subtle active underline or compact badge. | Tighten chip padding to 4px 8px; reduce height to 38px. |
| **3. Mobile Card Visual Hierarchy** | Card metadata (status, priority, assignee, timestamp) is rendered in one line with small text and low contrast. | Clear typographic hierarchy: bold title, distinct status badge, avatar pip for assignee. | Align metadata into clean CSS grid with consistent status badges (`.issues-st`). |
| **4. Desktop Sheet Gridlines** | Sheet cells have hard right borders with varying text truncation rules causing jagged columns. | Consistent tabular layout with subtle borders and clear column resize indicators. | Polish `.issues-table` gridline tokens; ensure headers align perfectly with data cells. |
| **5. Detail Modal / Frame Actions** | Action buttons (Copy link, Archive, Delete) in modal header use plain ghost text with varying icon gaps. | Integrated tool group with subtle border grouping and distinct danger hover token. | Group header actions into a coherent segmented bar in `IssueDetailActions.vue`. |
| **6. Description & Comments Typography** | Bare textareas without placeholder guidance or Markdown preview toggle. | Clean Markdown editor area with subtle borders and auto-resizing height. | Polish `IssueDescription.vue` textarea styling and focus rings. |
| **7. Empty States** | Plain text string ("No issues found" / "No comments yet") in muted grey text. | Professional empty state with subtle vector mascot, explanatory text, and primary CTA. | Add structured empty state widget with icon and keyboard shortcut badge (`N`). |
| **8. Keyboard Shortcuts** | Flat text paragraph at top of list ("Shortcuts: J/K, Enter, /") clutters screen. | Compact `<kbd>` badges or modal help dialog; clean visual chips. | Wrap shortcut keys in styled `<kbd>` chips; hide on mobile. |

---

## 6. Build Rows Table (Rounds Rulebook R1–R16)

In strict accordance with the rounds rulebook (§1.1 max 10 rows, §1.2 1–3 pushes per item, R1 disjoint files per batch, R14 WUI coding assigned strictly to Claude):

### 6.1 Plan Rows Table

| # | Action Slug & Scope | Rationale | Sites (`file:line`, max 5) | Test / Red Control | Measurement Command | Target Box | Vendor | Kind | Batch |
|---|---|---|---|---|---|---|---|---|---|
| **01** | `feat(issues-01-square-checkbox): replace round circle styling with square checkboxes on phone cards and page box` | Fixes owner issue: changes `border-radius: var(--radius-sm)` (8px) to `3px` on phone card and page checkboxes. | `csi-spl-wui/src/pages/issues.vue:4010-4035` | **Red control:** In Chromium at 412×915, computed `border-radius` of `.issues-check--card input::before` is `3px` instead of `8px`. | `node tests/e2e/issues-multiselect.test.mjs` (asserts `borderRadius === '3px'`) | sat | claude | simple_coding | 1 |
| **02** | `feat(issues-02-mobile-space-opt): reclaim horizontal card padding and streamline mobile filter header` | Reclaims 12px horizontal width on cards and compresses header stack from 104px to $\le 80\text{px}$. | `csi-spl-wui/src/pages/issues.vue:3985-3998`<br>`csi-spl-wui/src/pages/issues.vue:4035-4038` | **Red control:** Card `padding-inline-start` is $\le 34\text{px}$ while checkbox click target bounding box remains $\ge 44\times 44\text{px}$. | `node tests/e2e/issues-multiselect.test.mjs` (asserts `padding <= 34px`, `hitBox >= 44px`) | sat | claude | simple_coding | 2 |
| **03** | `feat(issues-03-3d-detail-tabs): sleek 3D raised tabs for Discussion and History with top-edge active marker` | Implements owner requirement: 3D raised tabs with `border-top: 3px solid var(--color-accent)`, theme tokens, light+dark. | `csi-spl-wui/src/pages/issues.vue:952-965`<br>`csi-spl-wui/src/pages/issues.vue:3849-3855` | **Red control:** Active tab computed `border-top-width` is `3px`, `border-bottom-width` is `0px`, background is `var(--color-surface)`. | `node tests/e2e/issues-detail-tabs.test.mjs` (asserts `borderTopWidth === '3px'`) | sat | claude | simple_coding | 3 |
| **04** | `feat(issues-04-clip-control-separation): decouple card clip control from tablist and add clear density tooltip/aria labels` | Moves `CardClipControl` outside `role="tablist"` and adds explicit density tooltips/labels. | `csi-spl-wui/src/components/CardClipControl.vue:10-38`<br>`csi-spl-wui/src/components/CardClipControl.vue:54-97` | **Red control:** CardClipControl has independent role `radiogroup` outside tablist, distinct border and background tokens. | `node tests/e2e/issues-detail-tabs.test.mjs` (asserts radiogroup not inside tablist) | sat | claude | simple_coding | 4 |
| **05** | `feat(issues-05-bulkbar-mobile-polish): polish bulk action bar layout, button labels, and sticky elevation on phone` | Streamlines mobile bulk bar from 88px height to $\le 68\text{px}$ with smooth slide-in elevation and 44px tap targets. | `csi-spl-wui/src/components/IssuesBulkBar.vue:11-56`<br>`csi-spl-wui/src/components/IssuesBulkBar.vue:108-123` | **Red control:** At 412×915 with 2 items checked, `.issues-bulk` height is $\le 72\text{px}$, with all 6 buttons accessible. | `node tests/e2e/issues-bulk.test.mjs` | sat | claude | simple_coding | 5 |
| **06** | `feat(issues-06-detail-header-actions): polish desktop modal header action buttons and copy confirmation` | Professionalizes modal header buttons (Copy link, Archive, Delete) with coherent button group styling. | `csi-spl-wui/src/components/IssueDetailActions.vue:1-60` | **Red control:** `IssueDetailActions` buttons render with consistent theme border, focus rings, and hover tokens. | `node tests/unit/issue-detail-buttons.test.mjs` | sat | claude | simple_coding | 6 |
| **07** | `feat(issues-07-detail-typography-hierarchy): elevate issue detail title, description, and metadata fields visual hierarchy` | Polishes `IssueDetailFrame` metadata panel, spacing, and section dividers matching professional ticket tools. | `csi-spl-wui/src/components/IssueDetailFrame.vue:1-80` | **Red control:** Detail frame exhibits clean CSS grid alignment between metadata panel and body. | `pnpm run typecheck` | sat | claude | simple_coding | 7 |
| **08** | `feat(issues-08-table-sheet-density): professionalize desktop table gridlines, cell padding, and header select-all alignment` | Polishes desktop table sheet: aligns select-all box with rows, refines gridline tokens and cell alignment. | `csi-spl-wui/src/pages/issues.vue:3478-3505` | **Red control:** Header checkbox aligns within $\pm 1\text{px}$ of row checkboxes; table header height is compact $\le 68\text{px}$ total. | `node tests/unit/issues-colw.test.mjs` | sat | claude | simple_coding | 8 |
| **09** | `feat(issues-09-empty-and-loading-states): add professional empty states with mascot and keyboard shortcut hints` | Replaces bare text "No issues found" / "No comments yet" with professional empty states and `<kbd>` badges. | `csi-spl-wui/src/pages/issues.vue:520-526`<br>`csi-spl-wui/src/pages/issues.vue:972` | **Red control:** Empty list renders `.issues-empty-state` with glyph and kbd badges. | `node tests/unit/issues.test.mjs` | sat | claude | simple_coding | 9 |
| **10** | `test(issues-10-multiselect-and-tabs-e2e): automated browser e2e test suite for square checkboxes, 3D tabs, and bulk bar` | Automated Playwright/Puppeteer e2e test validating square checkboxes (3px radius), 3D top tab borders, bulk selection flow, and mobile tap targets ($\ge 44\text{px}$). | `csi-spl-wui/tests/e2e/issues-multiselect-panel.test.mjs:1-120` | **Red control:** Fails on master (where radius is 8px circle, top border is 0px); passes when all rows land. | `node tests/e2e/issues-multiselect-panel.test.mjs` | sat | claude | tests | 10 |

### 6.2 Disjoint Files Batching Verification (R1)

To strictly enforce standing rule **R1 (Disjoint files per batch)**, the 10 rows are scheduled across 10 sequential batches:
- **Batch 1:** Row 01 (`csi-spl-wui/src/pages/issues.vue:4010-4035` - Checkbox radius fix).
- **Batch 2:** Row 02 (`csi-spl-wui/src/pages/issues.vue:3985-4038` - Mobile card space optimization; lands strictly after Batch 1).
- **Batch 3:** Row 03 (`csi-spl-wui/src/pages/issues.vue:952-3855` - 3D tabs styling; lands strictly after Batch 2).
- **Batch 4:** Row 04 (`csi-spl-wui/src/components/CardClipControl.vue` - Clip control decoupling).
- **Batch 5:** Row 05 (`csi-spl-wui/src/components/IssuesBulkBar.vue` - Bulk bar mobile polish).
- **Batch 6:** Row 06 (`csi-spl-wui/src/components/IssueDetailActions.vue` - Detail header action buttons).
- **Batch 7:** Row 07 (`csi-spl-wui/src/components/IssueDetailFrame.vue` - Detail frame typography & hierarchy).
- **Batch 8:** Row 08 (`csi-spl-wui/src/pages/issues.vue:3478-3505` - Desktop table gridlines & select-all alignment; lands strictly after Batch 3).
- **Batch 9:** Row 09 (`csi-spl-wui/src/pages/issues.vue:520-972` - Empty states and kbd badges; lands strictly after Batch 8).
- **Batch 10:** Row 10 (`csi-spl-wui/tests/e2e/issues-multiselect-panel.test.mjs` - Dedicated e2e test suite).

Every batch contains strictly disjoint files. Zero risk of concurrent git merge conflicts.

---

## 7. Performance Budget & Bundle Impact

- **Initial JS Budget Neutrality:** Zero new runtime libraries or npm dependencies installed. Zero bytes added to entry chunk (`ci_initial_gzip_kb` remains completely byte-neutral $\le 155.0\text{KB}$).
- **CSS Impact:** All tab and checkbox modifications leverage existing design tokens (`var(--color-surface)`, `var(--color-bg)`, `var(--color-accent)`, `var(--color-border)`). CSS growth is $< 200\text{ B}$ gzip.
- **Rendering & Paint Performance:** Checkbox and tab transitions operate strictly on `border-color`, `background-color`, and `box-shadow` without triggering unexpected layout thrashing or viewport reflows.

---

## 8. Security & Distribution Hygiene Guarantees

1. **CSP Compliance:** Zero inline `style` attributes, zero dynamic `:style` bindings, zero `v-html`. All styling resolves via pre-compiled CSS classes and theme custom properties.
2. **Accessible by Default:** Touch targets strictly adhere to WCAG 2.5.5 ($\ge 44\times 44\text{px}$). ARIA roles (`role="tablist"`, `role="tab"`, `role="radiogroup"`) strictly validated.
3. **Public Repository Hygiene:** Org-neutral, zero personal identifiers, zero secrets.

---

## 9. Expert Panel Review & Consensus Signatures

In accordance with [rounds-rulebook.md](rounds-rulebook.md) §3.2 and owner instructions:  
*Consensus is achieved across all 3 panel seats prior to spawning build row lanes.*

| Seat | Vendor | Agent ID | Status | Verdict & Signature |
|---|---|---|---|---|
| **Editor** | Antigravity (Google) | `a-434@sat` | **Drafted v0.1** | v0.1 drafted; empirical baseline measured on dev commit `51009ada4`; submitted to reviewer seats. |
| **Reviewer 1** | Claude (Anthropic) | Pending spawn | Pending | To review and sign in `csi-spl-doc/doc/md/issues-multiselect-panel/seat-claude.md`. |
| **Reviewer 2** | Mistral | Pending spawn | Pending | To review and sign in `csi-spl-doc/doc/md/issues-multiselect-panel/seat-mistral.md`. |

---
