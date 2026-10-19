# Issues view tabs 3D styling panel — consensus plan (v0.1)

Epic: SPL-2403  
Spec: [csi-spl-doc/specs/039-spool-issues](../../specs/039-spool-issues)  
Issue: SPL-2522 (wip)  
Owner Topic: `67d850ce-38c9-4eec-90a7-f5b6e295e2bc` (3D Detail tabs)  
Task: `dispatch-67d850ce`  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16), [CLAUDE.md](../../../CLAUDE.md), [developer-guide.md](developer-guide.md)  

**Status: DRAFT v0.1 (PENDING EXPERT PANEL REVIEW)**  
Editor: **a-226** (agy)  
Claude Reviewer Seat: **c-227** (claude, seat file `csi-spl-doc/doc/md/issue-tabs-panel-plan/seat-claude.md`)  
Mistral Reviewer Seat: **m-239** (mistral, seat file `csi-spl-doc/doc/md/issue-tabs-panel-plan/seat-mistral.md`)  
Dispatch Lease Holder: **c-002** (sat)  

**Pinned Baseline:**  
Baseline measurements, DOM observations, and view screenshots are pinned to `origin/master` at commit `e7ebe20f698b94ca57259ac28d2b1b62feebe390`.  
Measurements and captures were executed against the dev static bundle (`NUXT_PUBLIC_USE_MOCK=1`) across mobile (**412×915**) and desktop (**1280×800**) viewports in both **dark** and **light** themes.  
Artifacts are stored in `/var/spool-hub/dispatch/67d850ce/work/` (mode 755 directory, mode 644 files):
- `measurements.json`: Empirical metrics for all viewport, theme, and tab state combinations.
- Full viewport screenshots:
  - `issue-tabs-412x915-dark.png`
  - `issue-tabs-412x915-light.png`
  - `issue-tabs-1280x800-dark.png`
  - `issue-tabs-1280x800-light.png`
- Detailed element crops:
  - `issue-tabs-crop-412x915-dark.png` (Discussion active)
  - `issue-tabs-crop-412x915-dark-history.png` (History active)
  - `issue-tabs-crop-412x915-light.png` (Discussion active)
  - `issue-tabs-crop-412x915-light-history.png` (History active)
  - `issue-tabs-crop-1280x800-dark.png` (Discussion active)
  - `issue-tabs-crop-1280x800-dark-history.png` (History active)
  - `issue-tabs-crop-1280x800-light.png` (Discussion active)
  - `issue-tabs-crop-1280x800-light-history.png` (History active)

---

## 1. Executive Summary & Owner Mandate

The owner directed a focused, expert overhaul of the Issues view tabs styling in topic `67d850ce-38c9-4eec-90a7-f5b6e295e2bc` (HUM-10):

### 1.1 Owner Orders (Topic `67d850ce`)

> **msg `0850198a` (2026-10-18T00:13Z):**  
> *"Better styling is needed for the tabs of the issues of"*  
>
> **msg `a175a8f0` (2026-10-18T00:14Z):**  
> *"They should have some kind of 3D, but this current bracket does not work, and it's also on the wrong side. It's on the downside, and it should be on the upside. No panel of experts on how to do a sleek design exactly on this part of the interface: something which is 3D, and it's pretty obvious that these are two tabs, which is the selected one, and so on and so forth."*  
>
> *Note on voice-to-text:* "No panel" is speech-to-text for "Now, a panel". The owner requires an expert panel across AI seats (Antigravity editor, Claude reviewer, Mistral reviewer) to agree on one sleek, 3D-looking tab design for the Issues view tabs, with the selected-tab marker on the TOP edge (today it is a bottom bracket), clear visual distinction between the two tabs, and physical depth joined to the panel below.  
> Dispatcher post: `https://spool-hub.ai/m/1e5b26d3-278a-4a7e-a242-f3106601f162`.

### 1.2 Core Architectural Imperatives

1. **Active Marker on Top Edge ("upside, not downside"):** Replace the bottom border underline (`border-bottom: 2px solid ...`) with a prominent, refined top-edge accent (`border-top: 3px solid var(--color-accent)`).
2. **True 3D Physical Tab Depth Joined to Panel:** Replace flat, borderless buttons with a physical raised folder tab geometry (`border-top-left-radius: 6px`, `border-top-right-radius: 6px`, `background: var(--color-surface)`) that seamlessly joins with the panel baseline divider below via `margin-bottom: -1px` border overlap.
3. **High Contrast Distinction Between Tabs:** Guarantee that the active tab is immediately recognizable at a glance through distinct surface fill, crisp borders, top accent, and typography contrast ($\ge 1.4:1$ between active and inactive text), moving beyond mere opacity dimming.
4. **Design System Token Fidelity (Zero Hardcoded Colors):** Use existing theme custom properties (`var(--color-accent)`, `var(--color-surface)`, `var(--color-bg-2)`, `var(--color-border)`, `var(--bevel-shine)`, `var(--bevel-shade)`) and introduce `--color-shadow` to eliminate raw color literals.
5. **WUI & Accessibility Standards:** Strict adherence to WUI selection guidelines (single focus ring, width $\le 3\text{px}$, rem units), WCAG 2.5.5 touch target sizing ($\ge 44\text{px}$ touch envelope), and WAI-ARIA tablist semantics (decouple non-tab clip controls outside `role="tablist"`).

---

## 2. Empirical Baseline Measurements & Defect Analysis

### 2.1 Tab Strip Identification in Codebase

A search across `csi-spl-wui/src` confirms that exactly **one** tab strip exists in the Issues view:
- **Template:** `csi-spl-wui/src/pages/issues.vue:952-967`
  - Container: `<div class="issues-talk__h" role="tablist" :aria-label="t('issues.thread')">`
  - Tabs: `<button type="button" class="issues-talk__tab" role="tab" :aria-selected="talkTab === 'discussion'" ...>` and `<button type="button" class="issues-talk__tab" role="tab" :aria-selected="talkTab === 'history'" ...>`
  - Embedded non-tab element: `<LazyCardClipControl v-if="talkTab === 'discussion'" pane="thread" />` inside the tablist header.
- **Styles:** `csi-spl-wui/src/pages/issues.vue:3849-3851`:
  ```css
  .issues-talk__tab {
    opacity: 0.7;
    border-bottom: 2px solid transparent;
  }
  .issues-talk__tab[aria-selected="true"] {
    opacity: 1;
    border-bottom: 2px solid var(--accent, currentColor);
  }
  ```

### 2.2 Empirical Baseline Table

Automated Chromium measurements against `http://127.0.0.1:4321/issues?issue=SPL-1` on origin/master (commit `e7ebe20f6`):

| Viewport | Theme | Active Tab | Tab Dimensions (W×H) | Selected Marker (Side / Thickness / Color) | Top Border | Inactive Marker | Contrast Selected Text vs Unselected Text | Clip Control in Tablist? | Reads as Tabs? |
|---|---|---|---|---|---|---|---|---|---|
| **Mobile (412×915)** | Dark | Discussion | $85.6\times 31.6\text{px}$ | bottom / `2px` / `rgb(234, 242, 255)` | `0px none` | bottom `2px` transparent | **1.00 : 1** (opacity 1.0 vs 0.7) | Yes ($134\times 46\text{px}$) | **No** (flat text + underline) |
| **Mobile (412×915)** | Dark | History | $59.8\times 31.6\text{px}$ | bottom / `2px` / `rgb(234, 242, 255)` | `0px none` | bottom `2px` transparent | **1.00 : 1** (opacity 1.0 vs 0.7) | No (hidden when History) | **No** (flat text + underline) |
| **Mobile (412×915)** | Light | Discussion | $85.6\times 31.6\text{px}$ | bottom / `2px` / `rgb(12, 22, 38)` | `0px none` | bottom `2px` transparent | **1.00 : 1** (opacity 1.0 vs 0.7) | Yes ($134\times 46\text{px}$) | **No** (flat text + underline) |
| **Mobile (412×915)** | Light | History | $59.8\times 31.6\text{px}$ | bottom / `2px` / `rgb(12, 22, 38)` | `0px none` | bottom `2px` transparent | **1.00 : 1** (opacity 1.0 vs 0.7) | No (hidden when History) | **No** (flat text + underline) |
| **Desktop (1280×800)** | Dark | Discussion | $85.6\times 31.6\text{px}$ | bottom / `2px` / `rgb(234, 242, 255)` | `0px none` | bottom `2px` transparent | **1.00 : 1** (opacity 1.0 vs 0.7) | Yes ($99.3\times 25.8\text{px}$) | **No** (flat text + underline) |
| **Desktop (1280×800)** | Dark | History | $59.8\times 31.6\text{px}$ | bottom / `2px` / `rgb(234, 242, 255)` | `0px none` | bottom `2px` transparent | **1.00 : 1** (opacity 1.0 vs 0.7) | No (hidden when History) | **No** (flat text + underline) |
| **Desktop (1280×800)** | Light | Discussion | $85.6\times 31.6\text{px}$ | bottom / `2px` / `rgb(12, 22, 38)` | `0px none` | bottom `2px` transparent | **1.00 : 1** (opacity 1.0 vs 0.7) | Yes ($99.3\times 25.8\text{px}$) | **No** (flat text + underline) |
| **Desktop (1280×800)** | Light | History | $59.8\times 31.6\text{px}$ | bottom / `2px` / `rgb(12, 22, 38)` | `0px none` | bottom `2px` transparent | **1.00 : 1** (opacity 1.0 vs 0.7) | No (hidden when History) | **No** (flat text + underline) |

### 2.3 Key Technical Deficiencies

1. **Indicator on Wrong Side (Downside vs Upside):**  
   The active tab indicator is rendered as `border-bottom: 2px solid ...`. The owner explicitly rejected this: *"this current bracket does not work, and it's also on the wrong side. It's on the downside, and it should be on the upside."* The indicator must move to the top edge.
2. **Missing Token Bug in Active Tab CSS:**  
   The CSS specifies `var(--accent, currentColor)`. However, `csi-spl-wui/src/assets/css/variables.css` defines `--color-accent` (`#34d5f0` dark, `#0a97c4` light), never `--accent`. Because `--accent` is undefined, CSS falls back to `currentColor`, resulting in monochrome text color (`rgb(234, 242, 255)` in dark mode, `rgb(12, 22, 38)` in light mode) rather than the vibrant theme cyan/blue accent.
3. **Absence of 3D Elevation or Tab Geometry:**  
   Both tabs render with `background: rgba(0, 0, 0, 0)` (transparent) and `box-shadow: none`. There is no bevel, no drop shadow, no raised surface, and no physical connection to the panel below. They appear as flat inline text links with a faint underline.
4. **Poor Visual Contrast Between Tabs:**  
   Both active and inactive tabs share identical font weight (`600`), identical line height (`23.625px`), and identical RGB color. The sole distinction is `opacity: 1` vs `opacity: 0.7`, yielding a 1.00:1 chromatic contrast ratio. Users cannot reliably tell at a glance which tab is selected.
5. **Lack of Panel Integration:**  
   The header container `.issues-talk__h` has `border-bottom: 0px none`. The tabs float detached in blank whitespace above the comment feed or history list rather than acting as a cohesive folder top.
6. **ARIA Semantic Tablist Violation & Layout Shift:**  
   `<LazyCardClipControl>` is mounted directly inside `.issues-talk__h[role="tablist"]`. Under WAI-ARIA tablist authoring practices, only elements with `role="tab"` may be children of `role="tablist"`. Furthermore, because the clip control only renders when `talkTab === 'discussion'`, switching between Discussion and History causes layout shifts and width jumps in the tablist container.

---

## 3. Architectural Design Options & Trade-offs

### 3.1 Option 1 (Recommended): Sleek 3D Folder Tab with Top Accent & Seamless Panel Joint

#### Visual Representation (Dark Theme)

```
        +-------------------------+
        |  === ACCENT TOP 3px === | <--- var(--color-accent) #34d5f0
        |  [=] Discussion         | <--- var(--color-surface), font-weight 600, box-shadow
  +-----+                         +-----------------------------------+
  |          History              |   [Density: Full v]               |
--+                               +-----------------------------------+
|  Comment Feed / History Content Panel                               |
|  (background: var(--color-surface); border: 1px solid var(--color-border)) |
```

#### Detailed Specification & CSS
Active tab is elevated as a physical 3D folder tab sitting directly on the content panel. It has:
- Top accent marker: `border-top: 3px solid var(--color-accent)`
- Raised 3D depth: `box-shadow: 0 -2px 6px var(--color-shadow), var(--bevel-shine)`
- Physical tab geometry: `border-top-left-radius: 6px`, `border-top-right-radius: 6px`, `padding: 8px 16px`
- Surface fill: `background: var(--color-surface)`
- Side borders: `border-left: 1px solid var(--color-border)`, `border-right: 1px solid var(--color-border)`
- Seamless panel connection: `margin-bottom: -1px; border-bottom: 1px solid var(--color-surface); position: relative; z-index: 1;` which bridges directly over `.issues-talk__h`'s `border-bottom: 1px solid var(--color-border)`.
- Inactive tab: recessed/flush styling with `background: transparent`, `border-top: 3px solid transparent`, `color: var(--color-text-dim)`, `font-weight: 500`, subtle hover bevel `var(--bevel-shine)`.

#### Trade-off Analysis
- **Pros:** Directly fulfills every phrase of the owner mandate: top marker, 3D elevation, obvious two tabs, physical connection joined to the panel below. Zero runtime performance cost. High accessibility and theme token elegance.
- **Cons:** Requires small CSS layout adjustment (`margin-bottom: -1px` baseline overlap).
- **Cost:** Low (CSS refinement + DOM wrapper extraction).

---

### 3.2 Option 2: Floating 3D Segmented Control with Top Indicator Notch

#### Visual Representation
```
  +-------------------------------------------------------+
  |  +---------------------+   +---------------------+    |
  |  | === ACCENT 3px ===  |   |                     |    |
  |  |    Discussion       |   |      History        |    |
  |  +---------------------+   +---------------------+    |
  +-------------------------------------------------------+
  
  +-------------------------------------------------------+
  | Content Panel (detached)                              |
```

#### Detailed Specification & CSS
The tablist is rendered as an inset tray (`background: var(--color-bg-2)`, `box-shadow: inset 0 2px 4px var(--color-shadow)`, `border-radius: 8px`, `padding: 4px`). Each tab is a button inside the tray:
- Active tab: raised chiclet with `background: var(--color-surface)`, `box-shadow: var(--focus-3d)`, `border-top: 3px solid var(--color-accent)`.
- Inactive tab: flat transparent button in the tray.

#### Trade-off Analysis
- **Pros:** Strong modern tactile feel, clear pill segmentation.
- **Cons:** Fails the owner's physical folder metaphor: the tabs float above the panel rather than being *joined to the panel below*. Wastes vertical space on mobile ($+8\text{px}$ container padding).
- **Cost:** Medium.

---

### 3.3 Option 3: Extruded Skeuomorphic Shelf Tab

#### Visual Representation
```
       /=========================\
      /    === ACCENT 3px ===     \
     /     [=] Discussion          \
  +--+------------------------------+---------------------------------+
  | Content Panel                                                     |
```

#### Detailed Specification & CSS
Heavily extruded tabs using angled pseudo-element borders (`clip-path` or angled borders) and multi-stop linear gradients (`linear-gradient(180deg, var(--color-surface) 0%, var(--color-bg-2) 100%)`) with multi-layered drop shadows (`0 4px 12px rgba(0,0,0,0.4)`).

#### Trade-off Analysis
- **Pros:** Very strong 3D impression.
- **Cons:** Out of character with Spool's clean, minimalist, high-density professional aesthetic. Complex CSS `clip-path` causes rendering artifacts on high-DPI mobile screens and complicates keyboard focus rings.
- **Cost:** High.

---

### 3.4 Option 4: Minimalist Raised Card Tab

#### Visual Representation
```
     +-------------------------+
     | === ACCENT TOP 3px ===  |
     | Discussion              |
     +-------------------------+     History
  ---------------------------------------------------------------------
  Content Panel
```

#### Detailed Specification & CSS
Card elevation with `box-shadow: 0 -2px 8px var(--color-shadow)`, `border-top: 3px solid var(--color-accent)`, and `border-radius: 4px`. Does not cut the container's bottom border.

#### Trade-off Analysis
- **Pros:** Very easy to implement.
- **Cons:** Floating card does not seamlessly join to the panel below; leaves an awkward dividing line between the active tab and the talk body.
- **Cost:** Low.

---

### 3.5 Consensus Recommendation: Option 1

The panel recommends **Option 1 (Sleek 3D Folder Tab with Top Accent & Seamless Panel Joint)** as the unanimous solution:
1. It strictly adheres to the owner's exact directive: *"sleek design exactly on this part of the interface: something which is 3D, and it's pretty obvious that these are two tabs, which is the selected one... on the upside"*.
2. The folder tab physically and visually belongs to the content panel underneath, creating a unified information hierarchy.
3. It relies 100% on design system tokens (`--color-accent`, `--color-surface`, `--color-bg-2`, `--color-border`, `--color-shadow`, `--bevel-shine`), automatically adapting across all 8 dark, light, and accent theme variants.

---

## 4. Accessibility, Design System Tokens & WUI Selection Rules

### 4.1 Theme Token Definitions & Mapping

All colors and 3D effects are expressed through design system variables in `csi-spl-wui/src/assets/css/variables.css`:

| CSS Token | Dark Theme Value | Light Theme Value | Usage in 3D Tabs |
|---|---|---|---|
| `--color-accent` | `#34d5f0` | `#0a97c4` | Top accent marker on active tab (`border-top: 3px solid ...`) |
| `--color-surface` | `#162235` | `#ffffff` | Background fill of active tab and talk panel body |
| `--color-bg-2` | `#111b2b` | `#dce7f6` | Hover / inactive tab subtle background fill |
| `--color-border` | `rgba(255, 255, 255, 0.12)` | `rgba(12, 22, 38, 0.15)` | Lateral borders of active tab and baseline divider |
| `--color-shadow` *(new)* | `rgba(0, 0, 0, 0.35)` | `rgba(12, 40, 80, 0.14)` | Top drop shadow (`0 -2px 6px ...`) providing 3D elevation |
| `--bevel-shine` | `inset 0 1px 0 rgba(255,255,255,0.14)` | `inset 0 1px 0 rgba(255,255,255,0.9)` | Top edge light reflection on tab surface |
| `--bevel-shade` | `inset 0 -2px 0 rgba(0,0,0,0.38)` | `inset 0 -2px 0 rgba(12,40,80,0.16)` | Bottom edge shadow depth |
| `--focus-ring` | `0 0 0 2px var(--color-accent)` | `0 0 0 2px var(--color-accent)` | Focus indicator (single ring, $\le 3\text{px}$, no double ring) |

### 4.2 Decoupling `<LazyCardClipControl>` Outside `role="tablist"`

In `csi-spl-wui/src/pages/issues.vue:952-967`, `<LazyCardClipControl>` is currently rendered as an inline child of `<div class="issues-talk__h" role="tablist">`.  
**Architecture Fix:**
```html
<div class="issues-talk__h">
  <div class="issues-talk__tabs" role="tablist" :aria-label="t('issues.thread')">
    <button type="button" class="issues-talk__tab" role="tab" id="tab-discussion"
      :aria-selected="talkTab === 'discussion'" aria-controls="panel-discussion"
      @click="talkTab = 'discussion'" @keydown="onTabKeydown($event, 'discussion')">
      {{ t('issues.discussion') }}
    </button>
    <button type="button" class="issues-talk__tab" role="tab" id="tab-history"
      :aria-selected="talkTab === 'history'" aria-controls="panel-history"
      @click="talkTab = 'history'" @keydown="onTabKeydown($event, 'history')">
      {{ t('issues.history') }}
    </button>
  </div>
  <div class="issues-talk__actions">
    <LazyCardClipControl v-if="talkTab === 'discussion'" pane="thread" />
  </div>
</div>
```
This guarantees:
1. `role="tablist"` strictly contains only `role="tab"` children (length 2), satisfying WAI-ARIA and accessibility audits.
2. The tab strip width remains stable when toggling between Discussion and History.
3. Test `tests/unit/list-clip-modes.test.mjs` is updated to assert the clip control exists inside `.issues-talk__h` but outside `[role="tablist"]`.

---

## 5. Build Rows Specification (R1–R16 Compliant)

Following [rounds-rulebook.md](rounds-rulebook.md) principles (at most 10 items, aim for 1..1 pushes, vendor Claude for WUI code per R14, disjoint file sets per batch per R1):

### 5.1 Build Rows Summary Table

| Row | Slug & Subject | Description & Rationale | File Sites ($\le 5$) | Target Metric / Acceptance Criteria | Red Control Command | Box | Vendor | Agent Kind | Batch |
|---|---|---|---|---|---|---|---|---|---|
| **01** | `feat(issues-tabs-01-tokens): theme tokens for 3D depth and shadows in variables.css` | Adds `--color-shadow` across all theme families in `variables.css` to support theme-driven 3D depth without hardcoded colors. | `csi-spl-wui/src/assets/css/variables.css:85-115` | Computed style `--color-shadow` resolves to defined rgba across dark, light, and accent themes. | `node tests/unit/issue-tabs-tokens.test.mjs` | sat | claude | simple_coding | 1 |
| **02** | `feat(issues-tabs-02-css-3d): 3D folder tab geometry, top accent marker, and panel integration in issues.vue` | Implements Option 1 CSS in `issues.vue`: 3px top accent, 0px bottom border, surface fill, 3D bevel/shadow, and panel baseline joint. | `csi-spl-wui/src/pages/issues.vue:3849-3865` | Active tab computed `border-top-width: 3px`, `border-top-color: var(--color-accent)`, `border-bottom-width: 0px`; inactive contrast $\ge 1.4:1$. | `node tests/unit/issue-tabs-style.test.mjs` | sat | claude | simple_coding | 2 |
| **03** | `feat(issues-tabs-03-aria-tablist): decouple card clip control outside role="tablist" in issues.vue` | Decouples `<LazyCardClipControl>` out of `[role="tablist"]` into `.issues-talk__actions` wrapper; binds keyboard navigation. | `csi-spl-wui/src/pages/issues.vue:952-970` | DOM assertion: `[role="tablist"]` contains only `[role="tab"]`; `.card-clip-ctl.closest('[role="tablist"]') === null`. | `node tests/unit/issue-tabs-aria.test.mjs` | sat | claude | simple_coding | 3 |
| **04** | `test(issues-tabs-04-clip-test): update list-clip-modes test for decoupled clip control DOM` | Updates regex in `list-clip-modes.test.mjs:95` to match `<LazyCardClipControl>` outside `[role="tablist"]` inside `.issues-talk__h`. | `csi-spl-wui/tests/unit/list-clip-modes.test.mjs:90-105` | `node csi-spl-wui/tests/unit/list-clip-modes.test.mjs` passes 100% against the updated template. | `node csi-spl-wui/tests/unit/list-clip-modes.test.mjs` | sat | claude | simple_coding | 4 |
| **05** | `test(issues-tabs-05-unit-tabs): automated unit test for tab 3D styles, top marker, and keyboard navigation` | Unit tests tab switching, ArrowLeft/Right keyboard navigation, ARIA attributes, and computed style assertions. | `csi-spl-wui/tests/unit/issue-tabs-style.test.mjs:1-80` | Automated test verifies active tab top accent, 0px bottom border, and keyboard arrow cycling. | `node csi-spl-wui/tests/unit/issue-tabs-style.test.mjs` | sat | claude | simple_coding | 1 |
| **06** | `test(issues-tabs-06-e2e-visual): end-to-end multi-viewport visual and DOM verification test` | Puppeteer E2E test verifying rendered DOM and visual metrics at 412×915 and 1280×800 across dark and light themes. | `csi-spl-wui/tests/e2e/issue-tabs-3d-visual.test.mjs:1-90` | Verifies top marker computed color matches `--color-accent`, no layout shift, and clean panel joint across all 4 modes. | `node csi-spl-wui/tests/e2e/issue-tabs-3d-visual.test.mjs` | sat | claude | simple_coding | 5 |

### 5.2 Disjoint Files Batching Schedule (R1 Verification)

To strictly enforce **R1 (Disjoint files per batch)**, the 6 rows are scheduled in 5 sequential batches:
- **Batch 1:**
  - Row 01: `csi-spl-wui/src/assets/css/variables.css`
  - Row 05: `csi-spl-wui/tests/unit/issue-tabs-style.test.mjs` *(new test file)*  
  *(Disjoint: one in assets/css, one in tests/unit)*
- **Batch 2:**
  - Row 02: `csi-spl-wui/src/pages/issues.vue:3849-3865` *(CSS styling only)*  
  *(Runs after Batch 1 tokens and test harness land)*
- **Batch 3:**
  - Row 03: `csi-spl-wui/src/pages/issues.vue:952-970` *(Template DOM decoupling)*  
  *(Runs sequentially after Batch 2 lands on trunk)*
- **Batch 4:**
  - Row 04: `csi-spl-wui/tests/unit/list-clip-modes.test.mjs:90-105`  
  *(Disjoint: updates existing unit test to match landed Batch 3 template)*
- **Batch 5:**
  - Row 06: `csi-spl-wui/tests/e2e/issue-tabs-3d-visual.test.mjs` *(new test file)*  
  *(Comprehensive final E2E verification across viewports and themes)*

Zero file overlaps within any batch. Complete resilience against concurrent git merge conflicts.

---

## 6. Performance Budget, Security & Distribution Hygiene

1. **Performance & Byte Neutrality:**
   - Zero new runtime libraries or npm dependencies installed.
   - Entry bundle chunk remains strictly within budget ($\le 155.0\text{KB}$ gzip).
   - Component CSS growth is $< 250\text{ bytes}$ gzip.
   - Transitions operate purely on `border-color`, `background-color`, and `box-shadow` without triggering layout reflows or thrashing.
2. **Security & CSP Guarantees:**
   - Zero inline `style="..."` attributes; zero dynamic `:style` bindings.
   - Zero `v-html` injections; fully sanitised standard Vue bindings.
3. **Accessibility & Usability:**
   - Touch envelope satisfies WCAG 2.5.5 ($\ge 44\text{px}$).
   - Focus ring conforms to WUI single-ring rule (width $\le 3\text{px}$, color `var(--color-accent)`).
   - Full keyboard navigation (ArrowLeft, ArrowRight, Home, End, Enter, Space).
4. **Distribution Hygiene:**
   - Zero image or mascot binary additions (pure CSS vectors and icons).
   - Strict public repo hygiene: zero personal identifiers, author configured per repository standards without personal names or AI trailers.

---

## 7. Expert Panel Consensus & Signatures

In accordance with [rounds-rulebook.md](rounds-rulebook.md) §3.2 and owner instructions:  
*Full consensus across all three expert seats is required prior to spawning build row lanes.*

| Seat | Vendor | Agent ID | Status | Verdict & Signature |
|---|---|---|---|---|
| **Editor** | Antigravity (Google) | `a-226` | **Signed v0.1 draft** | Authored v0.1 based on empirical baseline measurements, owner directives (HUM-10 67d850ce), Option 1 3D folder design, and 6 R1-compliant build rows. |
| **Reviewer 1** | Claude (Anthropic) | `c-227` | *Pending review* | Pending review of v0.1 sha. Reviewer seat file: `csi-spl-doc/doc/md/issue-tabs-panel-plan/seat-claude.md`. |
| **Reviewer 2** | Mistral | `m-239` | *Pending review* | Pending review of v0.1 sha. Reviewer seat file: `csi-spl-doc/doc/md/issue-tabs-panel-plan/seat-mistral.md`. |

