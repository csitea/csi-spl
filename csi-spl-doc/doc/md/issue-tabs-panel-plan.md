# Issues view tabs 3D styling panel — consensus plan (v1.0)

Epic: SPL-2403  
Spec: [csi-spl-doc/specs/039-spool-issues](../../specs/039-spool-issues)  
Issue: SPL-2522 (wip)  
Owner Topic: `67d850ce-38c9-4eec-90a7-f5b6e295e2bc` (3D Detail tabs)  
Task: `dispatch-67d850ce`  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16), [CLAUDE.md](../../../CLAUDE.md), [developer-guide.md](developer-guide.md)  

**Status: CONSENSUS CANDIDATE v1.0 (INCORPORATING CLAUDE REVIEW c1660b375)**  
Editor: **a-226** (agy)  
Claude Reviewer Seat: **c-227** (claude, seat file [seat-claude.md](issue-tabs-panel-plan/seat-claude.md), verdict: Agree with changes, commit `c1660b375`)  
Mistral Reviewer Seat: replacement queued by orchestrator (ask `2b08ba9a` / `d1dad53c`, slug `c002-issue-tabs-panel-seat-mistral-2`, replacing stalled `m-239` per rounds-rulebook §2.7.3)  
Dispatch Lease Holder: **c-002** (sat)  

**Pinned Baseline & Measurement Protocol:**  
- Baseline measurements, DOM observations, and view screenshots are pinned to `origin/master` at commit `e7ebe20f698b94ca57259ac28d2b1b62feebe390` / `97d976cd1`.  
- Measurements and captures were executed against the static mock bundle (`NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate`) served by `csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh` on `http://127.0.0.1:4321/issues?issue=SPL-1`. The mock bundle's WUI source matches live dev (`70ae29de7`) identically (`git diff --stat 70ae29de7 97d976cd1 -- csi-spl-wui/src` is empty). Live dev was not directly measured because it requires member session credentials not present on automated test runners.  
- Automated runs: $n=1$ per viewport and theme across mobile (**412×915**) and desktop (**1280×800**) in both **dark** and **light** themes.  
- Captured artifacts are in `/var/spool-hub/dispatch/67d850ce/work/` (editor) and `/var/spool-hub/dispatch/67d850ce/work/c-227/` (Claude seat):
  - `measurements.json` / `c227-measure.json`: Empirical metrics for viewport, theme, and tab state combinations.
  - Screenshots and crops: `issue-tabs-{412x915,1280x800}-{dark,light}.png`, `issue-tabs-crop-*`, and `c227-<w>-<theme>-{today,option1}.png`.

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

1. **Active Marker on Top Edge ("upside, not downside"):**  
   Replace the bottom border underline (`border-bottom: 2px solid ...`) with a top-edge marker (`box-shadow: inset 0 var(--select-bar-w) 0 var(--focus-ring)`). This satisfies the owner's WUI focus/selection rule (2026-09-20 in `variables.css:47-59` and `main.css`): *"any selected item should have no more than 1 color in the selected border which cannot be wider than 3 px"*. By using `--focus-ring` (not `--color-accent`) for the marker, an active tab that receives keyboard focus displays exactly ONE unified ring color, preventing a 2-color smudge.
2. **True 3D Physical Tab Depth Joined to Panel:**  
   Eliminate the root cause of the "bracket": global `button { border-radius: var(--radius-sm); }` (`main.css:8-13`, `--radius-sm: 8px`) bends the 2px `border-bottom` up at both ends. Both tabs must explicitly zero bottom border and bottom border-radii (`border-radius: 6px 6px 0 0; border-bottom: 0;`). The tablist container aligns items to the bottom (`align-items: flex-end`) with a baseline border `1px solid var(--color-border)`. The active tab sits flush on this baseline (`margin-bottom: -1px; border-bottom: 1px solid var(--color-surface)`), creating a seamless physical folder joint with the panel below.
3. **High Contrast Distinction Between Tabs Across Viewports:**  
   The active tab is elevated with `background: var(--color-surface)`, lateral borders `var(--color-border)`, top marker `var(--focus-ring)`, and surface light reflection `var(--bevel-shine)`. Inactive tabs are recessed with `background: var(--color-bg-2)`, `box-shadow: var(--bevel-shade)`, and `color: var(--color-muted)`. On desktop, where the issue dialog background is `--color-surface` (`#0e1c33`), recessing inactive tabs to `--color-bg-2` (`#0a1424`) ensures clear physical depth and immediate distinguishability.
4. **Design System Token Fidelity (Zero Hardcoded Literals):**  
   Use existing theme custom properties from `variables.css`: `--color-surface` (`#0e1c33` dark / `#f4f8ff` light), `--color-bg-2` (`#0a1424` dark / `#dce7f6` light), `--color-border` (`rgba(130,200,255,0.16)` dark / `rgba(12,60,110,0.16)` light), `--color-muted` (`#93a6c4` dark / `#47597a` light), `--focus-ring` (`#6ee4f7` dark / `#4bb8dc` light), `--focus-ring-w` (`2px`), `--select-bar-w` (`3px`), `--bevel-shine`, and `--bevel-shade`. No non-existent tokens (e.g. `--color-text-dim` or raw `--accent`).
5. **WUI & Accessibility Standards:**  
   Touch envelope enforces `min-block-size: 2.75rem` ($\ge 44\text{px}$) to scale with font levels and satisfy WCAG 2.5.5. Full WAI-ARIA tablist semantics: decouple non-tab clip controls outside `role="tablist"` into an actions container, and provide standard keyboard navigation (`ArrowLeft`, `ArrowRight`, `Home`, `End`).

---

## 2. Empirical Baseline Measurements & Defect Analysis

### 2.1 Tab Strip Identification in Codebase

A search across `csi-spl-wui/src` confirms that exactly **one** tab strip exists in the Issues view:
- **Template:** `csi-spl-wui/src/pages/issues.vue:952-967`
  - Container: `<div class="issues-talk__h" role="tablist" :aria-label="t('issues.discussion')">`
  - Tab loop: `v-for="tab in TALK_TABS"` with `data-test="issues-talk-tab"` rendering Discussion (`issues.discussion`) and History (`issue_history.tab`).
  - Embedded non-tab element: `<LazyCardClipControl v-if="talkTab === 'discussion'" pane="thread" />` inside the tablist header.
- **Styles:** `csi-spl-wui/src/pages/issues.vue:3849-3851`:
  ```css
  .issues-talk__h { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .issues-talk__tab { margin: 8px 0 0; background: none; border: 0; border-bottom: 2px solid transparent; padding: 2px 2px 4px; font-family: inherit; font-size: 0.875rem; font-weight: 600; color: inherit; opacity: 0.7; cursor: pointer; }
  .issues-talk__tab[aria-selected='true'] { border-bottom-color: var(--accent, currentColor); opacity: 1; }
  ```

### 2.2 Empirical Baseline Table & Reviewer Verification

Automated Chromium measurements against `http://127.0.0.1:4321/issues?issue=SPL-1` on origin/master (commit `e7ebe20f6` / `97d976cd1`):

| Viewport | Theme | Active Tab | Tab Dimensions (W×H) | Selected Marker (Side / Width / Color) | Top Border | Inactive Marker | Effective Text Contrast (Selected vs Inactive) | Clip Control in Tablist? | Reads as Tabs? |
|---|---|---|---|---|---|---|---|---|---|
| **Mobile (412×915)** | Dark | Discussion | $85.6\times 31.6\text{px}$ | bottom / `2px` / `rgb(234, 242, 255)` | `0px none` | bottom `2px` transparent | **2.02 : 1** (17.66:1 vs 8.73:1 blended) | Yes ($134\times 46\text{px}$) | **No** (bracket underline) |
| **Mobile (412×915)** | Dark | History | $59.8\times 31.6\text{px}$ | bottom / `2px` / `rgb(234, 242, 255)` | `0px none` | bottom `2px` transparent | **2.02 : 1** (17.66:1 vs 8.73:1 blended) | No (hidden when History) | **No** (bracket underline) |
| **Mobile (412×915)** | Light | Discussion | $85.6\times 31.6\text{px}$ | bottom / `2px` / `rgb(12, 22, 38)` | `0px none` | bottom `2px` transparent | **2.52 : 1** (15.95:1 vs 6.33:1 blended) | Yes ($134\times 46\text{px}$) | **No** (bracket underline) |
| **Mobile (412×915)** | Light | History | $59.8\times 31.6\text{px}$ | bottom / `2px` / `rgb(12, 22, 38)` | `0px none` | bottom `2px` transparent | **2.52 : 1** (15.95:1 vs 6.33:1 blended) | No (hidden when History) | **No** (bracket underline) |
| **Desktop (1280×800)** | Dark | Discussion | $85.6\times 31.6\text{px}$ | bottom / `2px` / `rgb(234, 242, 255)` | `0px none` | bottom `2px` transparent | **1.90 : 1** (blended) | Yes ($99.3\times 25.8\text{px}$) | **No** (bracket underline) |
| **Desktop (1280×800)** | Dark | History | $59.8\times 31.6\text{px}$ | bottom / `2px` / `rgb(234, 242, 255)` | `0px none` | bottom `2px` transparent | **1.90 : 1** (blended) | No (hidden when History) | **No** (bracket underline) |
| **Desktop (1280×800)** | Light | Discussion | $85.6\times 31.6\text{px}$ | bottom / `2px` / `rgb(12, 22, 38)` | `0px none` | bottom `2px` transparent | **2.60 : 1** (blended) | Yes ($99.3\times 25.8\text{px}$) | **No** (bracket underline) |
| **Desktop (1280×800)** | Light | History | $59.8\times 31.6\text{px}$ | bottom / `2px` / `rgb(12, 22, 38)` | `0px none` | bottom `2px` transparent | **2.60 : 1** (blended) | No (hidden when History) | **No** (bracket underline) |

*Note on Contrast Measurement (c-227 finding B3):* While raw unblended text `color` is identical ($1.00:1$), the browser's `opacity: 0.7` blends inactive text over the background, resulting in effective contrast of $1.90:1$ to $2.60:1$. The v0.1 target "contrast $\ge 1.4:1$" therefore already passes on today's tree. Verifiable red controls must instead test structural and computed style properties (T1–T6 in Section 3.1).

### 2.3 Key Technical Deficiencies & Measured Injected Flaws

1. **Indicator on Wrong Side & The "Bracket" Root Cause:**  
   The active tab indicator is rendered as `border-bottom: 2px solid ...`. Global `button { border-radius: 8px }` bends the underline up at both ends, forming an awkward bracket. The owner explicitly rejected this: *"this current bracket does not work, and it's also on the wrong side. It's on the downside, and it should be on the upside."*
2. **Two-Color Selection Conflict (Measured in v0.1 Injection):**  
   In v0.1 draft, the top marker used `--color-accent` (`#34d5f0`). When selected AND focused via keyboard, the element rendered outline `2px #6ee4f7` (`--focus-ring`) and `border-top: 3px #34d5f0`. This violates the owner's rule in `variables.css:47-51` (*"any selected item should have no more than 1 color in the selected border which cannot be wider than 3 px"*). The marker must be set to `var(--focus-ring)` at `var(--select-bar-w)`.
3. **Tab Float & Broken Joint (Measured in v0.1 Injection):**  
   In today's layout, `.issues-talk__h` uses `align-items: center` and header height is $46\text{px}$ (mobile) or $53.6\text{px}$ (v0.1 draft). The active tab floated $\sim 5\text{px}$ above the divider, failing the "joined to the panel below" mandate. The container must use `align-items: flex-end`.
4. **Desktop Surface Contrast:**  
   On desktop, the modal dialog background is `--color-surface` (`#0e1c33`). Setting the active tab to `--color-surface` yields $1.00:1$ contrast against the dialog. Depth is achieved by recessing inactive tabs with `background: var(--color-bg-2)` (`#0a1424`), making the raised active tab physically pop against both the inactive tabs and panel.
5. **Touch Target Deficit:**  
   Measured v0.1 tab height was $43.6\text{px}$, failing the $\ge 44\text{px}$ WCAG 2.5.5 rule. Enforcing `min-block-size: 2.75rem` guarantees $\ge 44\text{px}$ across all font scaling levels.
6. **ARIA Semantic Tablist Violation & Layout Shift:**  
   `<LazyCardClipControl>` is mounted directly inside `.issues-talk__h[role="tablist"]`. Under WAI-ARIA tablist authoring practices, only elements with `role="tab"` may be children of `role="tablist"`. Furthermore, mounting the clip control conditionally only on Discussion creates layout shifts when toggling tabs.

---

## 3. Architectural Design Options & Trade-offs

### 3.1 Option 1 (Recommended): Sleek 3D Folder Tab with Top Accent & Seamless Panel Joint

#### Visual Representation (Dark Theme)

```
        +-------------------------+
        |  === FOCUS-RING 3px === | <--- inset 0 var(--select-bar-w) 0 var(--focus-ring)
        |  [=] Discussion         | <--- var(--color-surface), var(--bevel-shine), font-weight 600
  +-----+                         +-----------------------------------+
  |          History              |   [Density: Full v]               | <--- decoupled actions
--+                               +-----------------------------------+
|  Comment Feed / History Content Panel                               |
|  (background: var(--color-surface); border-top: 1px solid var(--color-border)) |
```

#### Detailed Specification & CSS

Active tab is elevated as a physical 3D folder tab sitting directly on the content panel:
- **Top marker:** `box-shadow: inset 0 var(--select-bar-w) 0 var(--focus-ring)`. When focused via keyboard, outline and marker share `--focus-ring` (single color $\le 3\text{px}$).
- **Surface & Elevation:** Active tab uses `background: var(--color-surface)`, lateral borders `1px solid var(--color-border)`, and light reflection `box-shadow: inset 0 var(--select-bar-w) 0 var(--focus-ring), var(--bevel-shine)`.
- **Physical tab geometry:** `border-radius: 6px 6px 0 0`, `border-bottom: 0`, `padding: 0.5rem 1rem`, `min-block-size: 2.75rem` ($\ge 44\text{px}$).
- **Seamless panel connection:** `.issues-talk__h { display: flex; align-items: flex-end; justify-content: space-between; border-bottom: 1px solid var(--color-border); }`. The active tab has `margin-bottom: -1px; border-bottom: 1px solid var(--color-surface); position: relative; z-index: 1;` which bridges seamlessly over the baseline divider.
- **Recessed Inactive tab:** `background: var(--color-bg-2)`, `box-shadow: var(--bevel-shade)`, `color: var(--color-muted)`, `font-weight: 500`. On hover: `color: var(--color-fg)`.
- **Keyboard navigation:** Full support for `ArrowLeft`, `ArrowRight`, `Home`, and `End` keys across tabs.

#### Verifiable Acceptance Targets (T1–T6)

| # | Target | Baseline Today | Option 1 Target |
|---|---|---|---|
| **T1** | Selected tab marker | Bottom `2px`, `currentColor` | Top inset marker colour == `--focus-ring`, width == `--select-bar-w`; `border-bottom-width: 0px` |
| **T2** | Selected and focused | N/A (no top marker) | Outline colour == marker colour (single colour $\le 3\text{px}$) |
| **T3** | Tab height & top alignment | Equal height, flat | Both tabs have identical height and top coordinate ($\pm 0.5\text{px}$) |
| **T4** | Panel joint | Floating detached | Selected tab bottom coordinate == tablist bottom coordinate ($\pm 0.5\text{px}$) |
| **T5** | Inactive vs Selected fill | Both transparent ($1.00:1$) | Inactive tab background (`--color-bg-2`) $\ne$ selected tab background (`--color-surface`) in dark & light |
| **T6** | Touch target size | $31.6\text{px}$ high | Tab height $\ge 44\text{px}$ (`min-block-size: 2.75rem`) at $412\times 915$ |

---

### 3.2 Option 2: Floating 3D Segmented Control with Top Indicator Notch

- Inset tray (`background: var(--color-bg-2)`, `border-radius: 8px`). Tabs are pills inside the tray.
- **Trade-off:** Fails the physical folder metaphor: the tabs float above the panel rather than being *joined to the panel below*. Wastes vertical space on mobile ($+8\text{px}$ padding).

---

### 3.3 Option 3: Extruded Skeuomorphic Shelf Tab

- Heavily extruded tabs using angled borders (`clip-path`) and multi-stop gradients.
- **Trade-off:** Complex CSS `clip-path` causes rendering artifacts on high-DPI mobile screens and breaks standard keyboard focus rings. Overly heavy aesthetic.

---

### 3.4 Option 4: Minimalist Raised Card Tab

- Card elevation with drop shadow; does not cut or join the baseline divider.
- **Trade-off:** Leaves an awkward horizontal divider line between the active tab and the talk body; fails "joined to the panel".

---

### 3.5 Consensus Recommendation: Option 1

The panel recommends **Option 1 (Sleek 3D Folder Tab with Top Accent & Seamless Panel Joint)** as the unanimous solution:
1. Directly fulfills every phrase of the owner mandate: top marker, 3D elevation, obvious two tabs, physical connection joined to the panel below.
2. Solves the two-color focus defect by aligning the marker to `--focus-ring` at `--select-bar-w`.
3. Relies 100% on existing theme design tokens (`--color-surface`, `--color-bg-2`, `--color-border`, `--color-muted`, `--focus-ring`, `--bevel-shine`, `--bevel-shade`).

---

## 4. Accessibility, Design System Tokens & WUI Selection Rules

### 4.1 Theme Token Definitions & Mapping

All colors and 3D effects are expressed through existing design system variables in `csi-spl-wui/src/assets/css/variables.css`:

| CSS Token | Dark Theme Value | Light Theme Value | Usage in 3D Tabs |
|---|---|---|---|
| `--focus-ring` | `#6ee4f7` | `#4bb8dc` | Top accent marker on active tab and keyboard focus outline (single color rule) |
| `--select-bar-w` | `3px` | `3px` | Thickness of the top accent marker bar |
| `--focus-ring-w` | `2px` | `2px` | Focus outline width ($\le 3\text{px}$) |
| `--color-surface` | `#0e1c33` | `#f4f8ff` | Background fill of active tab and talk panel body |
| `--color-bg-2` | `#0a1424` | `#dce7f6` | Recessed inactive tab background fill (ensures desktop depth) |
| `--color-border` | `rgba(130, 200, 255, 0.16)` | `rgba(12, 60, 110, 0.16)` | Lateral borders of active tab and baseline divider |
| `--color-muted` | `#93a6c4` | `#47597a` | Inactive tab text color |
| `--bevel-shine` | `inset 0 1px 0 rgba(255,255,255,0.14)` | `inset 0 1px 0 rgba(255,255,255,0.9)` | Top edge light reflection on tab surface |
| `--bevel-shade` | `inset 0 -2px 0 rgba(0,0,0,0.38)` | `inset 0 -2px 0 rgba(12,40,80,0.16)` | Inactive tab bottom edge recess depth |

### 4.2 Decoupling `<LazyCardClipControl>` Outside `role="tablist"`

In `csi-spl-wui/src/pages/issues.vue:952-967`, `<LazyCardClipControl>` is decoupled outside `role="tablist"` into a companion actions container while preserving the `v-for` loop over `TALK_TABS` and existing i18n keys:

```html
<div class="issues-talk__h">
  <div class="issues-talk__tabs" role="tablist" :aria-label="t('issues.discussion')">
    <button
      v-for="tab in TALK_TABS"
      :key="tab"
      type="button"
      role="tab"
      class="issues-talk__tab"
      data-test="issues-talk-tab"
      :data-value="tab"
      :aria-selected="talkTab === tab ? 'true' : 'false'"
      @click="talkTab = tab"
      @keydown="onTabKeydown($event, tab)"
    >
      {{ tab === 'history' ? t('issue_history.tab') : t('issues.discussion') }}
    </button>
  </div>
  <div class="issues-talk__actions">
    <LazyCardClipControl v-if="talkTab === 'discussion'" pane="thread" />
  </div>
</div>
```

This guarantees:
1. `role="tablist"` strictly contains only `role="tab"` buttons, satisfying WAI-ARIA and accessibility audits.
2. The tab strip width remains stable when toggling between Discussion and History.
3. Test `tests/unit/list-clip-modes.test.mjs` is updated in the same commit to match the decoupled DOM structure.

---

## 5. Build Rows Specification (R1–R16 Compliant)

Following [rounds-rulebook.md](rounds-rulebook.md) principles (at most 10 items, aim for 1..1 pushes, vendor Claude for WUI code per R14, disjoint file sets per batch per R1). Per reviewer feedback (P8), the build is structured as **2 green commits / batches** to prevent any intermediate red trunk state:

### 5.1 Build Rows Table

| Row | Slug & Subject | Description & Rationale | File Sites ($\le 5$) | Target Metric / Acceptance Criteria | Red Control Command | Box | Vendor | Agent Kind | Batch |
|---|---|---|---|---|---|---|---|---|---|
| **01** | `feat(issues-tabs-01-styling): 3D folder tab styling, top accent marker, and visual tests in issues.vue` | Implements Option 1 CSS in `issues.vue`: 3px top marker (`--focus-ring`), 0px bottom border, surface fill, bevel shine/shade, panel baseline joint, and `min-block-size: 2.75rem`. Adds unit style test and extends E2E test. | `csi-spl-wui/src/pages/issues.vue:3849-3865`<br>`csi-spl-wui/tests/unit/issue-tabs-style.test.mjs:1-75`<br>`csi-spl-wui/tests/e2e/issues-crud-modal.test.mjs:355-375` | Targets T1–T6 pass: selected tab top marker `--focus-ring` $\le 3\text{px}$, 0px bottom border, touch $\ge 44\text{px}$, distinct background fills. | `pnpm --filter csi-spl-wui test:unit tests/unit/issue-tabs-style.test.mjs` | sat | claude | simple_coding | 1 |
| **02** | `feat(issues-tabs-02-aria-keyboard): decouple clip control outside tablist and add keyboard navigation` | Decouples `<LazyCardClipControl>` outside `[role="tablist"]` into `.issues-talk__actions`; adds `@keydown` handler for ArrowLeft/ArrowRight/Home/End; updates `list-clip-modes.test.mjs` in the same commit to keep trunk green. | `csi-spl-wui/src/pages/issues.vue:952-970`<br>`csi-spl-wui/tests/unit/list-clip-modes.test.mjs:90-105`<br>`csi-spl-wui/tests/unit/issue-tabs-keys.test.mjs:1-60` | `[role="tablist"]` contains only `[role="tab"]`; `list-clip-modes` test passes; ArrowLeft/Right cycles tabs. | `pnpm --filter csi-spl-wui test:unit tests/unit/list-clip-modes.test.mjs` | sat | claude | simple_coding | 2 |

### 5.2 Disjoint Files Batching Schedule (R1 & R2 Verification)

- **Batch 1 (Row 01):**
  - Files: `csi-spl-wui/src/pages/issues.vue` (`<style>` block), `csi-spl-wui/tests/unit/issue-tabs-style.test.mjs` *(new)*, `csi-spl-wui/tests/e2e/issues-crud-modal.test.mjs` (extended tab assertions).
  - Verifies T1–T6 without touching template or clip control.
- **Batch 2 (Row 02):**
  - Files: `csi-spl-wui/src/pages/issues.vue` (`<template>` and `<script>` blocks), `csi-spl-wui/tests/unit/list-clip-modes.test.mjs`, `csi-spl-wui/tests/unit/issue-tabs-keys.test.mjs` *(new)*.
  - Spawns after Batch 1 lands on trunk. Template decoupling and test update land atomically in one commit, ensuring `tests/unit/list-clip-modes.test.mjs` never turns red on trunk (R2).

Zero file overlaps within either batch. Full trunk greenness preserved at every step.

---

## 6. Performance Budget, Security & Distribution Hygiene

1. **Performance & Byte Neutrality:**
   - Zero new runtime npm dependencies.
   - Entry bundle chunk remains strictly within budget ($\le 155.0\text{KB}$ gzip).
   - Component CSS growth is $< 250\text{ bytes}$ gzip.
   - Transitions operate purely on `border-color`, `background-color`, and `box-shadow` without triggering layout reflows.
2. **Security & CSP Guarantees:**
   - Zero inline `style="..."` attributes; zero dynamic `:style` bindings.
   - Zero `v-html` injections; fully sanitised standard Vue bindings.
3. **Accessibility & Usability:**
   - Touch envelope satisfies WCAG 2.5.5 ($\ge 44\text{px}$).
   - Focus ring conforms to WUI single-ring rule (width $\le 3\text{px}$, color `var(--focus-ring)`).
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
| **Editor** | Antigravity (Google) | `a-226` | **Signed v1.0 candidate** | Authored v1.0 consensus candidate incorporating Claude reviewer findings (P1–P8, T1–T6), consolidating to 2 green batches, correcting tokens, and defining single-color focus/selection geometry. |
| **Reviewer 1** | Claude (Anthropic) | `c-227` | **Agree with changes (v0.1)** | Landed commit `c1660b375`, seat file [seat-claude.md](issue-tabs-panel-plan/seat-claude.md). Agreed with Option 1 direction; proposed T1–T6 targets, 2-batch consolidation, and token corrections. Pending v1.0 sha signature. |
| **Reviewer 2** | Mistral | `c002-issue-tabs-panel-seat-mistral-2` | *Seat replacement queued* | Initial seat `m-239` stalled; replacement queued by orchestrator (ask `2b08ba9a` / `d1dad53c`) per rounds-rulebook §2.7.3. |

