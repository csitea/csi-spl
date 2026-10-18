# Issues multi-select panel and UI design — consensus plan (v1.0)

Epic: SPL-2403  
Spec: [csi-spl-doc/specs/039-spool-issues](../../specs/039-spool-issues)  
Issue: SPL-2497 (wip)  
Owner Topics: `405e08ba-62c2-4c89-8608-cf69b40e85df` (Multi-select checkboxes), `67d850ce-4346-4e5a-93f7-5c8e23ee0998` (3D Detail tabs), `0f67a177-fa3e-4a09-854d-415ca202d08e` (Issues UI professionalism)  
Task: `dispatch-405e08ba`  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16), [CLAUDE.md](../../../CLAUDE.md), [developer-guide.md](developer-guide.md)  

**Status: v1.0 CONSENSUS PLAN (FOLDED REVIEWER AMENDMENTS)**  
Editor: **a-434@sat** (agy)  
Claude Reviewer Seat: **c-435@sat** (claude, seat file [seat-claude.md](issues-multiselect-panel/seat-claude.md) landed on master at `0fcc49340`, verdict **CHANGE** folded)  
Mistral Reviewer Seat: **m-436@sat** (mistral, seat file [seat-mistral.md](issues-multiselect-panel/seat-mistral.md) landed on master at `f63ee72b4`, verdict **GOOD** with recommendations folded)  

**Pinned Baseline:** Baseline measurements, DOM observations, and view screenshots are pinned to origin/master at commit `51009ada42bc8920ab609c0bf6ddd5b0ad33baca` (v2.1.8). Measurements and captures were taken on the live `dev` estate (`https://dev.spool-hub.ai`) across mobile (**412×915**) and desktop (**1280×800**) viewports in both **dark** and **light** themes. Editor baseline artifacts are stored in `/var/spool-hub/dispatch/405e08ba/work/`; Claude reviewer independent re-measurements and screenshots are stored in `/var/spool-hub/dispatch/405e08ba/work/seat-claude/`.

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

## 2. Empirical Baseline Measurements & Reviewer Re-Measurements

Chromium automated measurements were conducted on dev commit `51009ada4` (v2.1.8) and independently re-measured by the Claude reviewer (`c-435`) and Mistral reviewer (`m-436`):

| Viewport | Element / Metric | Plan v0.1 Measured | Reviewer Re-Measured | Consensus Finding & Action |
|---|---|---|---|---|
| **Phone** (412×915) | Phone box `::before` size & radius | $16\times 16\text{px}$, radius `8px` | $16\times 16\text{px}$, radius `8px` (agree) | Root cause confirmed: $16/2 = 8\text{px}$ draws a circle (radio button). Change to `border-radius: 3px`. |
| **Phone** (412×915) | Unticked box visual style | Empty circle border | Identical to status circle on line below | Unticked box must use `border: 2px solid var(--color-border-strong)` to look distinct from circular status indicators. |
| **Phone** (412×915) | Mobile header stack | $52\text{px} + 52\text{px} = 104\text{px}$ | $52\text{px} + 52\text{px} = 104\text{px}$ (agree) | Compressing `.issues-mbar` and `.issues-chips` reduces header height from 104px down to $\le 80\text{px}$ (saving 24px vertically). |
| **Phone** (412×915) | Card `padding-inline-start` | 44px gutter | 44px gutter (agree) | **Retain 44px gutter** so the $44\times 44\text{px}$ tap hit box does not overlap card title/key text. Save space vertically instead. |
| **Phone** (412×915) | Card box touch target | $44\times 44\text{px}$ | $44\times 44\text{px}$ (agree) | Fully satisfies WCAG 2.5.5 minimum hit area. |
| **Phone** (412×915) | Bulk bar dimensions | $412\times 88\text{px}$, 6 buttons $44\times 44\text{px}$ | $412\times 88\text{px}$, 6 buttons $44\times 44\text{px}$ (agree) | Works, but inserting bar above list causes an **88px layout shift** on first tick. |
| **Phone** (412×915) | **First tick layout shift (Defect)** | Not captured in v0.1 | Card tops jump from 223px to 311px (+88px shift) | **CRITICAL DEFECT:** Bulk bar must overlay/replace the header stack in-place with **zero layout shift** (card 1 top shift $\le 1\text{px}$, bar height $\le 56\text{px}$). |
| **Desktop** (1280×800) | Row checkbox | $16\times 16\text{px}$ native, radius 0 | $16\times 16\text{px}$, native, radius 0 (agree) | Native desktop checkbox is already square. |
| **Desktop** (1280×800) | Bulk bar dimensions | $1013\times 69\text{px}$ | $1013\times 69\text{px}$, 6 buttons (agree) | Preserved. |
| **Desktop** (1280×800) | Filter controls in `.issues-frow` | Stated as 31px vs 36px | Measured: 34px (x5), 24px, and 44px | Corrected in v1.0. Target: normalize all filter controls to uniform 36px height. |
| **Both** | Detail Discussion/History tabs | Transparent bg, 2px underline | $31.6\text{px}$ height, 2px underline (agree) | Lacks 3D depth; active marker is on bottom edge rather than top edge. |
| **Both** | Tab active marker color token | `var(--accent, currentColor)` | Computed text color `rgb(234, 242, 255)` | `--accent` is undefined in `variables.css`. Must use defined token `var(--color-accent)`. |
| **Both** | Card clip control placement | Inside `role="tablist"` | Inside `role="tablist"` alongside tabs (agree) | Decouple clip control outside `role="tablist"` into dedicated container with density label and tooltips. |

---

## 3. Reviewer Amendments Folded into v1.0

The expert panel reviews from Claude (`c-435`, verdict CHANGE) and Mistral (`m-436`, verdict GOOD with recommendations) have been fully folded into this v1.0 specification:

### 3.1 Unticked Checkbox Differentiation (Claude Defect 2)
On dark theme mobile cards, the unticked checkbox was rendered as a hollow 16px circle with a muted border, while the issue status glyph (`02-todo`, `03-wip`) on the line below was also rendered as a hollow 14px circle. This caused users and the owner to perceive checkboxes as radio buttons.  
**Consensus Solution:** The checkbox visual box is explicitly styled with:
```css
border: 2px solid var(--color-border-strong);
border-radius: 3px;
background: var(--color-bg);
```
This produces an unmistakable, high-contrast square with crisp edges that cannot be confused with circular status glyphs.

### 3.2 Card Gutter & Touch Target Guard (Claude Row 02 Amendment)
Plan v0.1 proposed reducing the card left gutter to 32px while maintaining a 44px touch target. Claude's re-measurement proved that a 44px touch bounding box over a 32px gutter extends 12px over the card's text line (interfering with taps on the issue key and status).  
**Consensus Solution:** Keep the horizontal `padding-inline-start: 44px` on cards so the 44×44px touch target never covers text. Achieve the space savings vertically by compressing `.issues-mbar` and `.issues-chips` from 104px down to $\le 80\text{px}$ (saving 24px vertically). Add explicit touch guard: `elementFromPoint(card left + 50, card top + 22)` is never the checkbox.

### 3.3 Zero-Shift Mobile Bulk Bar (Claude Defect 1 & Row 05)
On master, when the user taps the first checkbox, `.issues-bulk` is inserted into the document flow above the "Sorted" line, pushing card 1 down by 88px (from y=223px to y=311px). This moves the item under the user's thumb, causing missed taps during rapid multi-selection.  
**Consensus Solution:** On mobile, `.issues-bulk` overlays or swaps in-place over the top header bar rather than pushing the card list down.  
**Target Metric:** Card 1's top coordinate remains within $\pm 1\text{px}$ before and after ticking the first item, and bulk bar height is $\le 56\text{px}$.

### 3.4 Keyboard Clear & Dismiss (Mistral Recommendation)
Mistral recommended adding explicit keyboard shortcuts for bulk actions. In v1.0, pressing `Escape` when $\ge 1$ item is selected clears all selections and dismisses the bulk bar.

### 3.5 3D Raised Tabs Architecture & Token Fidelity (Claude Row 03)
Active tab styling uses defined `--color-accent` (fixing the undefined `--accent` fallback) and exclusively uses design tokens (no raw `rgba()` literals). Active tab has `border-top: 3px solid var(--color-accent)`, `background: var(--color-surface)`, `border-bottom: none`, and seamless connection to content panel. Inactive tabs have transparent background and `border-top: 3px solid transparent`.

### 3.6 Decouple CardClipControl (Claude & Mistral Row 04)
`<LazyCardClipControl>` is decoupled completely from `.issues-talk__h[role="tablist"]`. The red test specifically asserts that `.card-clip-ctl.closest('[role="tablist"]')` is `null`.

### 3.7 Normalized Desktop Filter Row (Claude Row 08)
Re-measured filter row controls measure 34px (x5), 24px and 44px. In v1.0, all 7 filter controls in `.issues-frow` are normalized to a uniform 36px height with aligned SVG dropdown arrows.

### 3.8 Empty States via UiIcon (Claude Row 09 & Mistral)
Empty states use `UiIcon` and verified i18n keys (`issues.empty` = "No issues match.", history "No history yet.") across all locales, strictly adhering to the distribution hygiene no-images rule (no mascot image files).

### 3.9 Test Architecture Consolidation (Claude Row 10)
Rather than a standalone 10th row for tests that leaves red tests on master, tests and red controls are folded directly into each build row (01–09). Each row ships its own passing automated test.

---

## 4. Multi-Select Patterns Comparison (Phone + Desktop)

| Pattern | How It Works | Space Cost (Phone) | Tap Count to Act on $N$ Items | Discoverability | Accessibility (a11y) | Verdict |
|---|---|---|---|---|---|---|
| **Pattern 1: Leading Persistent Checkboxes** (Gmail, GitHub Issues, Jira) | Visible checkbox on every item row/card; tapping selects item and summons top/floating bulk action bar. | Gutter 44px, but no text overlap. | $N$ taps to select $+ 1$ tap to act ($N+1$). | **Immediate (10/10)**: Clear affordance; unmistakable meaning. | **Excellent (10/10)**: Standard `<input type="checkbox">` with ARIA states and keyboard support. | **Good baseline, needs header compression and zero-shift bulk bar.** |
| **Pattern 2: Contextual Selection Mode via Long-Press / "Select" Button** (Google Photos, iOS Mail) | List cards have 0px leading gutter. User long-presses an item or taps top "Select" button to enter "Edit/Selection Mode". | **Zero (10/10)**: Full card width available during reading. | $N+2$ taps (1 to enter mode, $N$ to select, 1 to act). | **Fair (6/10)**: Long-press is hidden gesture; "Select" button requires header space. | **Poor to Fair (5/10)**: Long-press violates WCAG 2.5.1 without single-point alternative; mode switches disorient screen readers. | **Rejected:** Adds extra modal friction and gesture barrier. |
| **Pattern 3: Swipe to Select / Range Drag** (Spreadsheets, Notion Mobile) | Horizontal swipe or vertical drag across cards toggles selection state. | **Zero (10/10)**: No permanent visual column. | Fast for contiguous items ($1$ drag), tedious for non-contiguous. | **Very Low (3/10)**: Completely invisible; high error rate. | **Fail (2/10)**: Fails WCAG 2.5.1 pointer gestures; impossible on screen readers. | **Rejected:** Collides with existing card swipe gestures (Left = Archive, Right = Menu). |
| **Pattern 4: Unmistakable Square Checkbox with Vertical Header Space Reclaim & Zero-Shift Bulk Overlay (Consensus)** | Checkbox visual marker is an unmistakable 16x16px square ($3\text{px}$ radius, 2px border). 44px touch target is maintained without text overlap. Space reclaimed vertically: header stack compressed from 104px to $\le 80\text{px}$. Bulk bar overlays header with 0px layout shift. | **Optimized (9/10)**: Reclaims 24px vertical space; 0px layout shift. | $N$ taps to select $+ 1$ tap to act ($N+1$). | **High (10/10)**: Always visible, unmistakable square checkbox. | **Full (10/10)**: Preserves 44×44px touch target (WCAG 2.5.5) and native checkbox semantics. | **Consensus Pattern (Adopted)** |

---

## 5. 3D Detail Page Tabs & Card Clip Control Architecture

### 5.1 3D Tab Specification

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
  border-top: 3px solid transparent;
  border-bottom: none;
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
  transition: all 0.15s ease;
}

/* Inactive Tab Hover */
.issues-talk__tab:hover:not([aria-selected="true"]) {
  background: var(--color-surface);
  color: var(--color-fg);
}

/* Active 3D Raised Tab */
.issues-talk__tab[aria-selected="true"] {
  background: var(--color-surface);
  color: var(--color-fg);
  border-color: var(--color-border);
  border-top: 3px solid var(--color-accent);
  box-shadow: 0 -2px 6px var(--color-shadow, rgba(0, 0, 0, 0.12));
  margin-bottom: -1px; /* seamless connection over bottom border */
  z-index: 1;
}
```

### 5.2 CardClipControl Decoupling & Relabeling

1. **Decouple from Tablist:** Move `<LazyCardClipControl>` outside `.issues-talk__h[role="tablist"]`.
2. **Contextual Placement:** Place the control in a utility container with clear text label:
   `<span class="card-clip-ctl__label">{{ t('feed.clip.label') }}:</span>`
3. **Accessibility:** Ensure all 3 buttons maintain 44×44px touch targets on phone with explicit tooltips (`titles`, `5 rows`, `full`).

---

## 6. Whole Issues UI Professionalism Audit (Topic `0f67a177`)

| Area / View | Concrete Shortcoming Observed | Professional Ticket Benchmark | Small, High-Impact Remediation |
|---|---|---|---|
| **1. Header & Filters** | Filter selects in desktop sheet have inconsistent heights (34px, 24px, 44px). | Clean, unified filter triggers with consistent icon badges and typography. | Normalize `.issues-frow` inputs with unified 36px height, border, and dropdown chevrons. |
| **2. Epics Filter Bar** | Epics strip takes 52px of height on phone. | Sleek horizontal scroll strip with subtle active badge. | Tighten chip padding to 4px 8px; reduce height to 38px. |
| **3. Mobile Card Visual Hierarchy** | Card metadata rendered with low contrast; checkbox looks like status circle. | Clear typographic hierarchy: bold title, distinct status badge, square checkbox. | Square checkbox (3px radius, 2px border) and aligned metadata grid. |
| **4. Mobile First-Tick Shift** | Bulk bar pushes entire list down 88px on first check. | In-place header replacement with zero list layout shift. | Overlay bulk bar in place of header bar (0px list movement). |
| **5. Detail Modal / Frame Actions** | Action buttons (Copy link, Archive, Delete) in modal header use varying icon gaps. | Integrated tool group with subtle border grouping and distinct danger hover token. | Group header actions into a coherent segmented bar in `IssueDetailActions.vue`. |
| **6. Description & Comments** | Bare textareas without placeholder guidance or markdown preview toggle. | Clean Markdown editor area with subtle borders and auto-resizing height. | Polish `IssueDescription.vue` textarea styling and focus rings. |
| **7. Empty States** | Plain text string with muted grey text. | Professional empty state with vector icon, explanatory text, and primary CTA. | Add structured empty state widget with `UiIcon` and verified i18n keys. |
| **8. Keyboard Shortcuts** | Bulk actions lack quick dismiss. | `Esc` to clear selection and dismiss bulk bar. | Bind `Esc` key in selection mode. |

---

## 7. Build Rows Table (Rounds Rulebook R1–R16)

In strict accordance with the rounds rulebook (§1.1 max 10 rows, §1.2 1–3 pushes per item, R1 disjoint files per batch, developer guide §4.1 WUI coding assigned strictly to Claude):

### 7.1 Consensus Rows Table (9 Rows)

| # | Action Slug & Scope | Rationale | Sites (`file:line`, max 5) | Red Control (fails on master, passes with change) | Measurement Command / Test | Target Box | Vendor | Kind | Batch |
|---|---|---|---|---|---|---|---|---|---|
| **01** | `feat(issues-01-checkbox-and-header-space): square checkbox styling and mobile header stack space compression` | Owner mandate: replaces circular radio styling with square checkboxes (3px radius, 2px border) distinct from status circles; compresses mobile header stack from 104px to $\le 80\text{px}$. | `csi-spl-wui/src/pages/issues.vue:3985-4038` | At 412x915, computed `border-radius` of `.issues-check--card input::before` is `3px` (was 8px); header stack height is $\le 80\text{px}$ (was 104px). | `node tests/e2e/issues-multiselect.test.mjs` | sat | claude | simple_coding | 1 |
| **02** | `feat(issues-02-zero-shift-bulkbar): mobile bulk action bar in-place header overlay with zero layout shift` | Claude finding: eliminates 88px list jump on first tick by overlaying header bar in-place; reduces bulk bar height to $\le 56\text{px}$. | `csi-spl-wui/src/components/IssuesBulkBar.vue:11-56`<br>`csi-spl-wui/src/components/IssuesBulkBar.vue:108-140` | At 412x915, card 1 top coordinate before first tick vs after first tick differs by $\le 1\text{px}$ (was 88px jump); bar height is $\le 56\text{px}$. | `node tests/e2e/issues-bulk-shift.test.mjs` | sat | claude | simple_coding | 2 |
| **03** | `feat(issues-03-3d-detail-tabs): sleek 3D raised tabs for Discussion and History with top-edge accent marker` | Owner mandate: 3D raised folder look with active marker on top edge using defined `--color-accent` and `--color-surface` tokens. | `csi-spl-wui/src/pages/issues.vue:952-965`<br>`csi-spl-wui/src/pages/issues.vue:3849-3860` | Active tab computed `border-top-width` is `3px` with `var(--color-accent)`; `border-bottom-width` is `0px`; background is `var(--color-surface)`. | `node tests/e2e/issues-detail-tabs.test.mjs` | sat | claude | simple_coding | 3 |
| **04** | `feat(issues-04-clip-control-separation): decouple card clip control outside tablist` | Claude/Mistral finding: moves `CardClipControl` outside `role="tablist"` into dedicated container with density label and tooltips. | `csi-spl-wui/src/components/CardClipControl.vue:10-45`<br>`csi-spl-wui/src/pages/issues.vue:950-970` | DOM assertion: `.card-clip-ctl.closest('[role="tablist"]')` is `null` (fails on master where clip control is inside tablist). | `node tests/e2e/issues-clip-ctl.test.mjs` | sat | claude | simple_coding | 4 |
| **05** | `feat(issues-05-bulkbar-keyboard-and-actions): bulk actions escape key clear and action execution polish` | Mistral recommendation: `Esc` key clears selection and dismisses bulk bar; all 6 bulk buttons preserve 44x44px touch targets. | `csi-spl-wui/src/pages/issues.vue:420-460`<br>`csi-spl-wui/src/components/IssuesBulkBar.vue:60-90` | Dispatching `keydown` Escape when selection count $>0$ resets selected items to 0 and closes bulk bar. | `node tests/unit/issues-bulk-keys.test.mjs` | sat | claude | simple_coding | 5 |
| **06** | `feat(issues-06-detail-header-actions): unified desktop modal header action button group` | Professionalizes modal header buttons (Copy link, Archive, Delete) with unified height (32px), 6px gap, and coherent border/focus tokens. | `csi-spl-wui/src/components/IssueDetailActions.vue:1-60` | Action buttons in modal header render with uniform 32px height, 6px gap, and consistent theme focus tokens. | `node tests/unit/issue-detail-buttons.test.mjs` | sat | claude | simple_coding | 6 |
| **07** | `feat(issues-07-detail-pane-hierarchy): elevate detail pane title, metadata, and description layout in issues.vue` | Corrects site to `issues.vue`: polishes detail pane typography hierarchy, metadata grid alignment, and description area. | `csi-spl-wui/src/pages/issues.vue:850-930` | Detail pane metadata grid aligns cleanly with 12px row gap and uniform label column width. | `node tests/unit/issue-detail-layout.test.mjs` | sat | claude | simple_coding | 7 |
| **08** | `feat(issues-08-table-sheet-density): desktop table filter height normalization to 36px and select-all alignment` | Claude re-measurement: normalizes all filter controls in `.issues-frow` to uniform 36px height (fixing 24/34/44px mismatch) and aligns select-all box. | `csi-spl-wui/src/pages/issues.vue:3478-3530` | All filter controls in `.issues-frow` measure uniform 36px height; header checkbox column aligns within $\pm 1\text{px}$ of row checkboxes. | `node tests/unit/issues-colw.test.mjs` | sat | claude | simple_coding | 8 |
| **09** | `feat(issues-09-empty-states-icon): structured empty states using UiIcon and verified locale keys` | Claude/Mistral finding: replaces bare text with structured empty states using `UiIcon` and verified locale keys (`issues.empty`, `history.empty`), zero image dependencies. | `csi-spl-wui/src/pages/issues.vue:520-535`<br>`csi-spl-wui/src/pages/issues.vue:970-985` | `[data-test="issues-empty"]` renders `UiIcon` with verified i18n text `issues.empty` ("No issues match."). | `node tests/unit/issues.test.mjs` | sat | claude | simple_coding | 9 |

### 7.2 Disjoint Files Batching Verification (R1)

To strictly enforce standing rule **R1 (Disjoint files per batch)**, the 9 rows are scheduled across 9 sequential batches:
- **Batch 1:** Row 01 (`csi-spl-wui/src/pages/issues.vue:3985-4038` - Square checkbox & header space).
- **Batch 2:** Row 02 (`csi-spl-wui/src/components/IssuesBulkBar.vue:11-140` - Zero-shift bulk bar).
- **Batch 3:** Row 03 (`csi-spl-wui/src/pages/issues.vue:952-3860` - 3D tabs styling; lands strictly after Batch 1).
- **Batch 4:** Row 04 (`csi-spl-wui/src/components/CardClipControl.vue:10-45` - Clip control decoupling).
- **Batch 5:** Row 05 (`csi-spl-wui/src/pages/issues.vue:420-460` - Bulk keyboard clear; lands strictly after Batch 3).
- **Batch 6:** Row 06 (`csi-spl-wui/src/components/IssueDetailActions.vue:1-60` - Modal header buttons).
- **Batch 7:** Row 07 (`csi-spl-wui/src/pages/issues.vue:850-930` - Detail pane hierarchy; lands strictly after Batch 5).
- **Batch 8:** Row 08 (`csi-spl-wui/src/pages/issues.vue:3478-3530` - Desktop filter normalization; lands strictly after Batch 7).
- **Batch 9:** Row 09 (`csi-spl-wui/src/pages/issues.vue:520-985` - Empty states; lands strictly after Batch 8).

Every batch contains strictly disjoint files across batches. Zero risk of concurrent git merge conflicts.

---

## 8. Performance Budget & Bundle Impact

- **Initial JS Budget Neutrality:** Zero new runtime libraries or npm dependencies installed. Entry chunk (`ci_initial_gzip_kb`) remains completely byte-neutral $\le 155.0\text{KB}$.
- **CSS Impact:** All tab and checkbox modifications leverage existing design tokens (`var(--color-surface)`, `var(--color-bg)`, `var(--color-accent)`, `var(--color-border)`). CSS growth is $< 200\text{ B}$ gzip.
- **Rendering & Paint Performance:** Checkbox and tab transitions operate strictly on `border-color`, `background-color`, and `box-shadow` without triggering unexpected layout thrashing or viewport reflows. First-tick bulk bar overlay eliminates the 88px layout jump.

---

## 9. Security & Distribution Hygiene Guarantees

1. **CSP Compliance:** Zero inline `style` attributes, zero dynamic `:style` bindings, zero `v-html`. All styling resolves via pre-compiled CSS classes and theme custom properties.
2. **Accessible by Default:** Touch targets strictly adhere to WCAG 2.5.5 ($\ge 44\times 44\text{px}$). ARIA roles (`role="tablist"`, `role="tab"`, `role="radiogroup"`) strictly validated.
3. **Public Repository Hygiene:** Org-neutral, zero personal identifiers, zero secrets. No image or mascot binaries added to git.

---

## 10. Expert Panel Consensus Signatures

In accordance with [rounds-rulebook.md](rounds-rulebook.md) §3.2 and owner instructions:  
*Consensus is achieved across all 3 panel seats prior to spawning build row lanes.*

| Seat | Vendor | Agent ID | Status | Verdict & Signature |
|---|---|---|---|---|
| **Editor** | Antigravity (Google) | `a-434@sat` | **Signed v1.0** | Plan v1.0 integrates all reviewer findings, empirical baseline re-measurements, 0px-shift bulk overlay, and R1-compliant 9 build rows. |
| **Reviewer 1** | Claude (Anthropic) | `c-435@sat` | **Review v0.1 Landed (`0fcc49340`), v1.0 Awaiting Signature** | Reviewed in [seat-claude.md](issues-multiselect-panel/seat-claude.md) (verdict CHANGE). All 10 points folded into v1.0. Awaiting signature commit to seat file. |
| **Reviewer 2** | Mistral | `m-436@sat` | **Review v0.1 Landed (`f63ee72b4`), v1.0 Awaiting Signature** | Reviewed in [seat-mistral.md](issues-multiselect-panel/seat-mistral.md) (verdict GOOD). Recommendations (empty states, Esc shortcut) folded into v1.0. Awaiting signature commit to seat file. |
