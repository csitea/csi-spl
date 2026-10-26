# UI Panel Consensus: Lowest-Hanging Fruit Proposals (2026-10-13)

> Generated from qto doc `c93968fb-aeed-4830-9abf-7abe52c1f361`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

- **Topic:** Owner t1 `34f4da14-adc0-4670-891e-02e26e72eed0` (dispatch task `dispatch-34f4da14`, panel task `ui-panel-34f4da14`, tracked issue `SPL-1748`)
- **Mandate:** HUM-10 verbatim:
  > "panel of 1 of every kind of agent - what should be implemented in the current code base to make the UI faster, more aesthetic and the code cleaner - 10 subtasks"
  > "reach a consensus first and than just start implementation - do not ask me anything"
  > "run at least 2 tasks in parallel"
- **Participating Seats:**
  - Claude seat (`c-951`, `claude.md`, 11 proposals, issue `SPL-1724`)
  - Grok seat (`g-952`, `grok.md`, 8 proposals, issue `SPL-1725`)
  - AGY seat (`a-953`, `agy.md`, 12 proposals, issue `SPL-1726`)
  - Mistral seat (`m-454`, `mistral.md`, 12 proposals, issue `SPL-1727`)
  - *(No Qwen seat: qwen cannot sign in on either box)*

---

<a id="ws-doc-b63b1c63-5c75-4a1c-8dd0-903dafa7e4f9"></a>
## 1. Baseline Measurements & Constraints

<a id="ws-doc-5734e972-135f-483d-abf7-1bafc3f98e83"></a>
### 1.1 Empirical Baselines (`sat`, commit `4ac30d59b` / `06a9ecb8`)

Across seats, empirical measurements on host `sat` (node 20, Chrome 1440x900 headless, `csi-spl-wui` 8.1.3) establish:

| Metric | Measured Value | Ceiling / Budget | Margin / Status |
|---|---|---|---|
| **Initial JS (`200.html` / `/lobby`)** | **154.3 KB gzip**, 3 chunks (452.1 KB raw) | **155.0 KB** (`ci_initial_gzip_kb`) | **+0.7 KB headroom** (Razor-thin) |
| **Home document (`index.html`)** | **344.2 KB gzip**, 83 chunks (962.9 KB raw) | 352.1 KB (`ci_home_gzip_kb`) | +7.9 KB headroom |
| **First Contentful Paint (FCP)** | **88–112 ms** (`.spl-boot` skeleton) | — | Snaps when shell loads |

*(Note: Mistral seat bundle numbers disagree with the other three seats; the measured 154.3 KB gzip / 155.0 KB ceiling on origin/master is the authoritative ground truth).*

<a id="ws-doc-f7b4d1e2-eeab-4872-8aa6-60edbcb1e87e"></a>
### 1.2 Non-Negotiable Constraints

1. **Bundle Ceiling (`ci_initial_gzip_kb 155.0`):**
   With only 0.7 KB headroom remaining on the initial entry chunk, **any item that adds to the entry chunk must be paired with an equal or greater saving**, or follow an entry-reducing change.
2. **Exclusion of Sign-in Redesign (SPL-1722):**
   Active redesign under lane `c-451` (`pages/login.vue`, `src/layouts/login.vue`, `LoginFeatures.vue`, `LoginLinks.vue`, and `auth.login.*` locale keys) is strictly excluded from all subtasks and build lanes.
3. **Disjoint Build Lanes:**
   Subtasks must be grouped into build lanes whose **file sets are strictly disjoint**, enabling at least 2 lanes (and up to 6) to run and land concurrently without file or git conflicts.

---

<a id="ws-doc-041574ac-d81e-44d8-b4a6-2e391e11f9ce"></a>
## 2. Ranked List of the 10 Consensus Subtasks

Ranked by impact-to-effort ratio, lowest-hanging certainty first:

| Rank | Subtask | Category | Seats in Agreement | Effort | Expected Gain |
|:---:|---|---|---|:---:|---|
| **1** | Lazy-load shell interaction dialogs and off-screen layout panes | Speed | Claude (S1), AGY (1), Grok (3) | **S** | -50 to -65 KB gzip home bundle |
| **2** | Win back entry chunk headroom (0.7 KB left) via deferred startup modules & plugin merge | Speed | Claude (S2), AGY (3, 4), Mistral (3, 8) | **M** | -3 to -5 KB gzip initial chunk |
| **3** | Skeleton width alignment & `<ClientOnly>` shell fallback | Speed / Aesthetic | Grok (1, 2), Mistral (6), AGY (7) | **S** | 0 layout shift (CLS); smooth 88 ms paint |
| **4** | High-performance message feed via `content-visibility: auto` | Speed | Claude (S3), AGY (2) | **S** | Large style/layout drop on 200+ topics |
| **5** | Desktop hover-reveal row actions & phone header readability | Aesthetic | Claude (A1, A2), AGY (6) | **S** | Calmer feed; full sender name on 390px |
| **6** | Standard `@font-face` loading & font-size token scale | Aesthetic | Grok (5), Mistral (7), Claude (A4) | **S** | Zero FOUT; 53 font sizes -> <=10 tokens |
| **7** | Fix undefined `--color-text` & add CSS token gate | Clean Code | Claude (C1), Mistral (9) | **XS** | Fixes 13 styling bugs; CI regression gate |
| **8** | Extract unified `useDismiss` click-outside composable | Clean Code | Claude (C2), AGY (11), Mistral (10) | **S** | Deduplicates 6 event handlers; no idle listeners |
| **9** | Decompose monolithic `ChannelSidebar.vue` (tabs & footer) | Clean / Speed | Claude (S4), Grok (7), AGY (10) | **M** | -700 LOC from monolith; -3 to -5 KB gzip |
| **10** | Automate `.mjs` type declaration shims (`mjs-shims.d.ts`) | Clean Code | Claude (C3), Grok (8), AGY (12), Mistral (11) | **M** | Eliminates drift across 133 ambient modules |

---

<a id="ws-doc-dc9628da-af96-460e-997c-01f62874f9ab"></a>
## 3. Subtask Details & Measurement Verification

<a id="ws-doc-5fd0887b-e4cc-4ef1-8b8a-65a2f7643808"></a>
### Item 1: Lazy-Load Shell Interaction Dialogs and Off-Screen Layout Panes (Speed)
- **Proposed By:** Claude (S1: lazy toasts & confirm dialogs), AGY (Item 1: async `TopicPane` & `LiveTopicPane`), Grok (Item 3: async import `TopBar` / defer composer graph).
- **Files:**
  - `csi-spl-wui/src/layouts/default.vue`
- **What:** In `src/layouts/default.vue`, static imports eagerly bundle `TopicPane.vue`, `LiveTopicPane.vue`, `TopBar.vue`, `MoveUndoToast.vue`, `ArchiveUndoToast.vue`, `DeleteUndoToast.vue`, `MentionDirectToast.vue`, `OpenMessageToast.vue`, and `MergeConfirmDialog.vue` into the root layout closure. Convert interaction toasts and modal dialogs to dynamic/lazy components, and wrap off-screen topic panes in `defineAsyncComponent`.
- **Expected Gain:** **-50 to -65 KB gzip** off the initial home preload bundle (`ci_home_gzip_kb` 344.2 KB drops to ~280–290 KB); removes 20+ static chunk preloads on initial paint.
- **Effort:** **S**
- **Measurement Command:**
  ```bash
  cd csi-spl-wui && NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate && python3 ../csi-spl-orc/src/bash/scripts/perf-budget.py bundle --pub .output/public --budgets ../csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json
  ```

---

<a id="ws-doc-c80627ff-8e2f-44cc-9353-0d554ddda018"></a>
### Item 2: Win Back Entry Chunk Headroom (0.7 KB Left) via Deferred Startup Modules & Plugin Merge (Speed)
- **Proposed By:** Claude (S2: defer non-critical startup modules), AGY (Item 3: consolidate duplicate theme plugins; Item 4: partition icon dictionary), Mistral (Item 3: locale lazy loading; Item 8: theme flicker).
- **Files:**
  - `csi-spl-wui/src/plugins/theme.client.ts`
  - `csi-spl-wui/src/plugins/preferred-theme.client.ts`
  - `csi-spl-wui/src/plugins/pwa.client.ts`
  - `csi-spl-wui/src/utils/tenant-switcher.mjs`
  - `csi-spl-wui/src/utils/uiIcons.ts`
  - `csi-spl-wui/src/components/UiIcon.vue`
- **What:** Consolidate `theme.client.ts` and `preferred-theme.client.ts` into a single lightweight client plugin. Partition the 60-icon `uiIcons.ts` SVG dictionary into core essentials (~15 icons) and an async extended catalogue. Defer `tenant-switcher.mjs` and non-critical PWA event listeners until after `onNuxtReady`.
- **Expected Gain:** **-3 to -5 KB gzip** off `ci_initial_gzip_kb`, expanding headroom from 0.7 KB to ~4–5 KB safely below the 155.0 KB budget; eliminates redundant DOM mutations and hydration event listeners.
- **Effort:** **M**
- **Measurement Command:**
  ```bash
  cd csi-spl-wui && NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate && python3 ../csi-spl-orc/src/bash/scripts/perf-budget.py bundle --pub .output/public --budgets ../csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json
  ```

---

<a id="ws-doc-73c5b9b4-381e-4d37-9aa9-0978b0003132"></a>
### Item 3: Skeleton Width Alignment & `<ClientOnly>` Shell Fallback (Speed / Aesthetic)
- **Proposed By:** Grok (Item 1: align `.spl-boot__side` width and strip `spool-hub` text; Item 2: `<ClientOnly>` fallback in default layout), Mistral (Item 6: reduce CLS / layout shift), AGY (Item 7: skeleton placeholders).
- **Files:**
  - `csi-spl-wui/src/spa-loading-template.html`
  - `csi-spl-wui/src/layouts/default.vue`
- **What:** Fix `.spl-boot__side` width from 240px to 260px in `spa-loading-template.html` to match shell token `--sidebar-w: 260px`. Remove outdated `spool-hub` brand text from skeleton boot header. Add a `<ClientOnly>` fallback template in `layouts/default.vue` that renders matching `shell-late` placeholder outlines during prerender and initial hydration.
- **Expected Gain:** Eliminates Cumulative Layout Shift (CLS) on frame mount; 88 ms skeleton paint aligns seamlessly with the loaded shell without visual twitching.
- **Effort:** **S**
- **Measurement Command:**
  ```bash
  python3 -c '
  import re
  boot=open("csi-spl-wui/src/spa-loading-template.html").read()
  var=open("csi-spl-wui/src/assets/css/variables.css").read()
  w=re.search(r"--sidebar-w:\s*(\d+)px", var).group(1)
  b=re.search(r"spl-boot__side\{[^}]*width:(\d+)px", boot).group(1)
  print("sidebar", w, "boot", b)
  print("brand", "spl-boot__brand" in boot)
  '
  ```

---

<a id="ws-doc-0d886cd9-424a-4f3d-aebc-7eb182561ada"></a>
### Item 4: High-Performance Message Feed via `content-visibility: auto` (Speed)
- **Proposed By:** Claude (S3: `content-visibility` on cards), AGY (Item 2: skip offscreen card rendering).
- **Files:**
  - `csi-spl-wui/src/components/MessageCard.vue`
- **What:** Apply `content-visibility: auto` and `contain-intrinsic-size: auto 72px` to the message card root element in `MessageCard.vue`. The browser skips styling, layout, and rendering calculations for off-screen cards in long channel feeds and topic views. Verify that scroll anchoring and jump-to-message remain accurate.
- **Expected Gain:** Marked reduction in main-thread layout and style recalculation duration during fast scrolling across 200+ message topics.
- **Effort:** **S**
- **Measurement Command:**
  Headless Chrome CDP `Performance.getMetrics` (`LayoutDuration` + `RecalcStyleDuration`) on a 300-message mock topic before and after.
- **Built (SPL-1750, then SPL-1762):** the rule shipped in b4ebb24eb and was dropped in 2b0beeda4. A newest-last feed that drops rows at the top as it adds rows at the bottom can end a frame at the same list height. The list's ResizeObserver then never fired, the new row grew from its 72px estimate after the feed had followed it, and the feed stopped 57-69px short of the bottom (`message-order.test.mjs` A5, 3 of 3 widths). SPL-1762 has `useScrollAnchor.ts` observe every row (`[data-key]`) after each patch as well as the list, so a row that grows re-follows the bottom, and puts the card rule back. Mock bundle: A5 passes 3 of 3 widths with both changes and fails 3 of 3 with the rule alone.

---

<a id="ws-doc-d38b81e8-6e99-4ca9-81e8-1573a87981ba"></a>
### Item 5: Desktop Hover-Reveal Row Actions & Phone Header Readability (Aesthetic)
- **Proposed By:** Claude (A1: phone author name truncation; A2: desktop hover/focus reveal for action buttons), AGY (Item 6: standardized interactive states).
- **Files:**
  - `csi-spl-wui/src/components/MessageCard.vue`
- **What:** On desktop, reveal message row action buttons (`>>`, emoji button, menu trigger) only on `:hover` or `:focus-within` (remaining always visible under `@media (hover: none)`). On mobile (<=820px), move emoji and kind buttons into the action sheet menu and show reply count `n >>` only when `n > 0`, freeing space so author names are never truncated to `HU…`.
- **Expected Gain:** Produces a calm, uncluttered Slack-like desktop feed; restores full sender name readability on mobile viewport widths (390px).
- **Effort:** **S**
- **Measurement Command:**
  Headless browser check at 390x844 on mock `/channel/lobby`: `.msg-author` satisfies `scrollWidth <= clientWidth`; action buttons visible on keyboard `:focus-within`.

---

<a id="ws-doc-048f2c4d-f3cd-4533-b72f-5a2d343211d5"></a>
### Item 6: Standard `@font-face` Loading & Font-Size Token Scale (Aesthetic)
- **Proposed By:** Grok (Item 5: `@font-face` definition & latin subset for IBM Plex Sans), Mistral (Item 7: eliminate FOUT), Claude (A4: type scale from 53 scattered sizes to `--fs-*` tokens).
- **Files:**
  - `csi-spl-wui/src/assets/css/variables.css`
  - `csi-spl-wui/src/assets/css/main.css`
  - `csi-spl-wui/nuxt.config.ts`
  - Font assets in `csi-spl-wui/src/assets/fonts/`
- **What:** Add `@font-face` rules for `"IBM Plex Sans"` (regular & semibold latin subsets) with `font-display: swap` so the font family specified in `--font-stack` actually loads across all client operating systems. Map the 53 scattered literal `font-size` declarations in `src` to standardized design tokens (`--fs-2xs` through `--fs-xl`) in `variables.css`.
- **Expected Gain:** Ensures visual consistency across Linux, macOS, and Windows without FOUT; harmonizes typography into a predictable typographic hierarchy.
- **Effort:** **S**
- **Measurement Command:**
  Headless check `document.fonts.check("16px \"IBM Plex Sans\"")` returns true; `grep -rhoE "font-size:\s*[^;]+" csi-spl-wui/src --include=*.css | sort -u | wc -l` drops to <= 10.

---

<a id="ws-doc-bdb185ca-6723-4053-8ec8-022804d992f5"></a>
### Item 7: Fix Undefined `--color-text` & Add CSS Token Gate (Clean Code)
- **Proposed By:** Claude (C1: replace 13 occurrences of undefined `--color-text` with `--color-fg`), Mistral (Item 9: remove dead/broken CSS declarations).
- **Files:**
  - `csi-spl-wui/src/assets/css/main.css`
  - `csi-spl-wui/src/components/EmojiPicker.vue`
  - `csi-spl-wui/src/components/KindPicker.vue`
  - `csi-spl-wui/src/components/SettingsDialog.vue`
  - `csi-spl-wui/src/components/CalendarEventDialog.vue`
  - `csi-spl-wui/src/components/DisplayNameSetting.vue`
  - `csi-spl-wui/src/components/SignInEmailsPanel.vue`
  - `csi-spl-wui/src/pages/docs.vue`
  - `csi-spl-wui/src/pages/help/[[page]].vue`
  - `csi-spl-wui/src/pages/tenant-settings.vue`
  - `csi-spl-wui/tests/unit/css-vars-defined.test.mjs` (new)
- **What:** Replace 13 instances of invalid `var(--color-text)` (defined nowhere in CSS variables) with the standard token `--color-fg`. Standardize the fallback value in `var(--radius-sm, 6px)` to `8px`. Add a unit gate `tests/unit/css-vars-defined.test.mjs` validating that every `var(--*)` references a declared token.
- **Expected Gain:** Eliminates 13 silent styling defects where text color falls back to browser default; guards against future design token typos in CI.
- **Effort:** **XS**
- **Measurement Command:**
  ```bash
  grep -rho "var(--color-text)" csi-spl-wui/src | wc -l
  node csi-spl-wui/tests/unit/css-vars-defined.test.mjs
  ```
  *(Grep count drops from 13 to 0; unit test passes).*

---

<a id="ws-doc-a525a82c-e1cc-4525-9246-16f45871bc7d"></a>
### Item 8: Extract Unified `useDismiss` Click-Outside Composable (Clean Code)
- **Proposed By:** Claude (C2: replace 6 duplicate `onDocPointer` implementations), AGY (Item 11: utility consolidation), Mistral (Item 10: consolidate duplicate utils).
- **Files:**
  - `csi-spl-wui/src/composables/useDismiss.ts` (new)
  - `csi-spl-wui/src/components/EmojiPicker.vue`
  - `csi-spl-wui/src/components/KindPicker.vue`
  - `csi-spl-wui/src/components/UserMenu.vue`
  - `csi-spl-wui/src/components/SidebarRowMenu.vue`
  - `csi-spl-wui/src/components/ThemeToggle.vue`
  - `csi-spl-wui/src/pages/issues.vue`
- **What:** Replace 6 duplicate implementations of `function onDocPointer` with a single composable `useDismiss(targetRef, onDismiss, { ignore })`. Ensure the `pointerdown` document listener is only attached when the target dropdown/menu is active, eliminating idle global listeners.
- **Expected Gain:** Deduplicates ~60 lines of boilerplate; prevents memory leaks and idle event thrashing; unifies touch-sheet and desktop dismiss behaviors.
- **Effort:** **S**
- **Measurement Command:**
  `grep -rn "function onDocPointer" csi-spl-wui/src | wc -l` (drops from 7 to 1, retained in `usePointMenu.ts`); all menu and dropdown unit/e2e tests remain green.

---

<a id="ws-doc-98ec6db3-ddd7-4d3d-ae40-5c0e5ba24c70"></a>
### Item 9: Decompose Monolithic `ChannelSidebar.vue` (Tabs & Footer) (Clean / Speed)
- **Proposed By:** Claude (S4: split off-screen sidebar panels: People, Agents, Boxes, Events), Grok (Item 7: extract version/reload footer to `SidebarVersion.vue`), AGY (Item 10: modularize sidebar).
- **Files:**
  - `csi-spl-wui/src/components/ChannelSidebar.vue`
  - `csi-spl-wui/src/components/sidebar/SidebarVersion.vue` (new)
  - `csi-spl-wui/src/components/sidebar/SidebarPanels.vue` (new)
- **What:** `ChannelSidebar.vue` is a 2,224-line monolith containing rail navigation, tab panels, and version footer logic. Extract the off-screen panels (People, Agents, Boxes, Events) into lazy async child components, and move footer version/reload logic into `SidebarVersion.vue`.
- **Expected Gain:** Reduces `ChannelSidebar.vue` from 2,224 to < 1,500 lines (-700+ lines); trims -3 to -5 KB gzip from the home document closure.
- **Effort:** **M**
- **Measurement Command:**
  ```bash
  wc -l csi-spl-wui/src/components/ChannelSidebar.vue
  cd csi-spl-wui && node src/node/test/run-unit-tests.mjs
  ```

---

<a id="ws-doc-95c27ae8-46d9-463c-b21a-b8261c4d084c"></a>
### Item 10: Automate `.mjs` Type Declaration Shims (`mjs-shims.d.ts`) (Clean Code)
- **Proposed By:** Claude (C3: generate type shims from JSDoc/tsc), Grok (Item 8: automated generator / drift test for 133 ambient modules), AGY (Item 12: utility type safety), Mistral (Item 11: TypeScript strictness).
- **Files:**
  - `csi-spl-wui/src/types/mjs-shims.d.ts`
  - `csi-spl-wui/src/node/generate-mjs-shims.mjs` (or `tests/unit/mjs-shims-drift.test.mjs`)
- **What:** Replace manual synchronization of the 2,647-line `src/types/mjs-shims.d.ts` (133 `declare module` blocks) with an automated export-scanning generator script or strict parity test that fails in CI if `.mjs` exports drift from declared types.
- **Expected Gain:** Eliminates manual maintenance of 2,647 lines of ambient declarations; prevents delayed typecheck breakage on utility modifications.
- **Effort:** **M**
- **Measurement Command:**
  ```bash
  grep -c '^declare module' csi-spl-wui/src/types/mjs-shims.d.ts
  cd csi-spl-wui && pnpm run typecheck
  ```

---

<a id="ws-doc-beaa2149-d063-4b0c-9d08-0020cde69fd4"></a>
## 4. Disjoint Build Lanes & Concurrency Matrix

To satisfy the mandate *"run at least 2 tasks in parallel"*, the 10 subtasks are organized into build lanes whose **file sets are strictly disjoint**. Overlapping subtasks queue within the same lane, enabling parallel execution across up to 6 concurrent lanes:

| lane | items | files | can run with |
|---|---|---|---|
| **Lane 1 (Layout & Shell Boot)** | **Item 1** (lazy layout panels)<br>**Item 3** (skeleton & `<ClientOnly>` fallback) | `src/layouts/default.vue`<br>`src/spa-loading-template.html` | Lane 2, Lane 3, Lane 4, Lane 5, Lane 6 |
| **Lane 2 (Feed & Message Cards)** | **Item 4** (`content-visibility: auto`)<br>**Item 5** (hover actions & phone header) | `src/components/MessageCard.vue` | Lane 1, Lane 3, Lane 4, Lane 5, Lane 6 |
| **Lane 3 (Sidebar Modularization)** | **Item 9** (decompose `ChannelSidebar.vue`) | `src/components/ChannelSidebar.vue`<br>`src/components/sidebar/*` | Lane 1, Lane 2, Lane 4, Lane 5, Lane 6 |
| **Lane 4 (Entry Chunks & Startup)** | **Item 2** (win back entry chunk headroom) | `src/plugins/theme.client.ts`<br>`src/plugins/preferred-theme.client.ts`<br>`src/plugins/pwa.client.ts`<br>`src/utils/tenant-switcher.mjs`<br>`src/utils/uiIcons.ts`<br>`src/components/UiIcon.vue` | Lane 1, Lane 2, Lane 3, Lane 5, Lane 6 |
| **Lane 5 (Tokens & Component Polish)** | **Item 6** (`@font-face` & font scale)<br>**Item 7** (`--color-text` & gate)<br>**Item 8** (`useDismiss` composable) | `src/assets/css/variables.css`<br>`src/assets/css/main.css`<br>`nuxt.config.ts`<br>`src/assets/fonts/*`<br>`src/composables/useDismiss.ts`<br>`src/components/EmojiPicker.vue`<br>`src/components/KindPicker.vue`<br>`src/components/SettingsDialog.vue`<br>`src/components/CalendarEventDialog.vue`<br>`src/components/DisplayNameSetting.vue`<br>`src/components/SignInEmailsPanel.vue`<br>`src/components/UserMenu.vue`<br>`src/components/SidebarRowMenu.vue`<br>`src/components/ThemeToggle.vue`<br>`src/pages/docs.vue`<br>`src/pages/help/[[page]].vue`<br>`src/pages/tenant-settings.vue`<br>`src/pages/issues.vue`<br>`tests/unit/css-vars-defined.test.mjs` | Lane 1, Lane 2, Lane 3, Lane 4, Lane 6 |
| **Lane 6 (Type Shims & Tooling)** | **Item 10** (automate `mjs-shims.d.ts`) | `src/types/mjs-shims.d.ts`<br>`src/node/generate-mjs-shims.mjs` | Lane 1, Lane 2, Lane 3, Lane 4, Lane 5 |

---

<a id="ws-doc-af8837d8-8e39-4d9c-847d-677ead325689"></a>
## 5. Summary of Recommended Execution Order

1. **Immediate Concurrent Kickoff:**
   - **Lane 1** (Shell Layout & Boot) and **Lane 2** (Feed & Message Cards) can launch immediately in parallel. Neither touches entry chunk JS.
   - **Lane 4** (Entry Chunks & Startup) should land as early as possible to expand the entry chunk headroom from 0.7 KB to ~4–5 KB, ensuring subsequent changes across other lanes never turn workflow 10 red.
2. **Subsequent Concurrency:**
   - **Lane 3** (Sidebar Modularization) and **Lane 5** (Tokens & Component Polish) run concurrently without file conflicts.
   - **Lane 6** (Type Shims & Tooling) runs independently in parallel with any other lane.
