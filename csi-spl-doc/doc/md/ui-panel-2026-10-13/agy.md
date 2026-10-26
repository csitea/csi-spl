# UI Panel: Lowest-Hanging Fruit Proposals (agy Seat)

> Generated from qto doc `042b5a8d-f2c6-42bc-8b27-76e6b9d61e89`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

- **Date:** 2026-10-13
- **Author:** a-953 (agy seat, 5-vendor UI panel: claude, grok, mistral, agy, qwen)
- **Task:** `ui-panel-34f4da14`
- **Tracked Issue:** `SPL-1726`
- **Scope:** `csi-spl-wui` (excluding `login.vue`, `src/layouts/login.vue`, `LoginFeatures.vue`, `LoginLinks.vue` under SPL-1722 / `c-451`)

---

<a id="ws-doc-e07554ba-4a1d-445b-a47e-0cb8c049de0d"></a>
## 1. Baseline Measurements

Measurements conducted directly on host `sat` (load average: ~2.70):

| Metric | Measured Value | Notes & Scope |
|---|---|---|
| **`ci_initial_gzip_kb`** | **154.3 KB** | **452.1 KB raw** across the 3 critical entry chunks: <br>• `dist/client/_nuxt/VaoSVFew.js`: **95.8 KB gz** (298.7 KB raw) <br>• `dist/client/_nuxt/CY8eL6tV.js` (vendor-vue): **47.5 KB gz** (142.1 KB raw) <br>• `dist/client/_nuxt/B7v08V11.js` (vendor-i18n): **11.0 KB gz** (11.3 KB raw) |
| **`ci_home_gzip_kb`** | **344.2 KB** | **962.9 KB raw** across 83 preloaded chunks in `dist/index.html` |
| **First Paint / FCP** | **112 ms** | Headless Chrome (1440×900) on `sat`. Median of 3 consecutive runs: 104 ms, 112 ms, 116 ms (DOMContentLoaded: 115 ms; wall load: 1122 ms) |

<a id="ws-doc-b0bbbd84-f4fc-498f-8df0-e27312a3db33"></a>
### Measurement Commands Used

1. **Initial and Home Chunk Sizes:**
   ```bash
   cd csi-spl-wui && npm run build:spa && node -e '
   const fs = require("fs");
   const zlib = require("zlib");
   const html = fs.readFileSync("dist/index.html", "utf8");
   const preloads = [...html.matchAll(/href="([^"]+\.js)"/g)].map(m => m[1].replace(/^\//, "dist/"));
   let gz = 0, raw = 0;
   for (const p of preloads) {
     if (fs.existsSync(p)) {
       const buf = fs.readFileSync(p);
       raw += buf.length;
       gz += zlib.gzipSync(buf).length;
     }
   }
   console.log("Preload chunks:", preloads.length);
   console.log("Raw KB:", (raw / 1024).toFixed(1));
   console.log("Gzip KB:", (gz / 1024).toFixed(1));
   '
   ```

2. **First Paint via Performance Observer:**
   ```bash
   node -e '
   const puppeteer = require("puppeteer");
   (async () => {
     const browser = await puppeteer.launch({ headless: "new", args: ["--no-sandbox"] });
     const page = await browser.newPage();
     await page.goto("http://127.0.0.1:4000");
     const timing = await page.evaluate(() => {
       const [fp] = performance.getEntriesByName("first-paint");
       const [fcp] = performance.getEntriesByName("first-contentful-paint");
       const nav = performance.getEntriesByType("navigation")[0];
       return { fp: fp?.startTime, fcp: fcp?.startTime, dcl: nav?.domContentLoadedEventEnd };
     });
     console.log(timing);
     await browser.close();
   })();
   '
   ```

---

<a id="ws-doc-dbee0f8a-aa40-44d4-86b6-6f1137dd1da8"></a>
## 2. Executive Summary: 12 Ranked Proposals

The 12 lowest-hanging fruits across **Speed**, **Aesthetics**, and **Clean Code**, ranked by impact-to-effort ratio:

| Rank | Group | Proposal | Expected Gain | Effort |
|:---:|:---|---|---|:---:|
| **1** | Speed | Lazy-load `TopicPane` and `LiveTopicPane` via `defineAsyncComponent` | -50 to -60 KB gzip from initial home bundle; -20 ms FCP | S (1-2h) |
| **2** | Speed | Defer rich composer features in `MessageComposer.vue` until user focus | -12 to -15 KB gzip from initial view; faster hydration | S (2-3h) |
| **3** | Speed | Consolidate duplicate startup plugins (`theme` & `preferred-theme`) | -1.5 KB gzip; eliminates redundant listeners & DOM mutation | XS (1h) |
| **4** | Speed | Partition `uiIcons.ts` SVG dictionary into core and extended sets | -8 to -12 KB raw (~3-4 KB gzip) shaved from entry chunk | S (2h) |
| **5** | Aesthetics | Themed thin scrollbars across desktop sidebars and feeds | Consistent dark navy aesthetic; eliminates clunky 16px grey OS bars | XS (30m) |
| **6** | Aesthetics | Standardize micro-transitions and focus rings on interactive controls | Tactile feel; eliminates visual snapping; WCAG focus visibility | S (2h) |
| **7** | Aesthetics | Skeleton placeholder card state in `LiveFeed.vue` | Eliminates Cumulative Layout Shift (CLS) on channel switch | S (2-3h) |
| **8** | Aesthetics | Elevated empty states with contextual icons and guidance | Replaces bare text; guides new users in empty channels/search | S (2h) |
| **9** | Clean Code | Delete orphaned component `CheckoutHostStatus.vue` | Removes 34 lines of dead unreferenced code; zero regression risk | XS (15m) |
| **10** | Clean Code | Decompose 2,225-line monolith `ChannelSidebar.vue` into focused components | Reduces complexity from 2,225 to ~400 LOC in main file | M (4-6h) |
| **11** | Clean Code | Unify fragmented ISO date and time formatting utilities | Eliminates duplicate regex/timezone parsing across 3 modules | S (2-3h) |
| **12** | Clean Code | Migrate core feed controllers (`channel-feed.mjs`, `feed.mjs`) to TypeScript | Full compile-time type verification for reactive message streams | M (3-4h) |

---

<a id="ws-doc-36d011e0-3515-4a37-822e-8af162f4f501"></a>
## 3. Detailed Proposals

<a id="ws-doc-7cdd5195-b607-469e-8a6a-09b0b7cd9db3"></a>
### Group 1: Speed (First Paint & Bundle Size)

<a id="ws-doc-35261e2d-8d2e-4f0f-a275-0ed7acf4f023"></a>
#### Item 1: Lazy-load `TopicPane` and `LiveTopicPane` via `defineAsyncComponent` in `layouts/default.vue`
- **What:** In `csi-spl-wui/src/layouts/default.vue`, `TopicPane.vue` and `LiveTopicPane.vue` are statically imported at the top of the file. Because Nuxt and Vite generate `<link rel="modulepreload">` tags for all static imports of the root layout, the browser eagerly downloads `TopicPane`, `LiveTopicPane`, `MessageCard.vue` (27.9 KB gzip / 88.5 KB raw), `MessageComposer.vue` (47.7 KB gzip), and over 20 sub-chunks on initial page load, even when the user lands on an unthreaded feed or home view where `section === PaneSection.NONE`. Switching these imports to `defineAsyncComponent(() => import('@/components/TopicPane.vue'))` and `defineAsyncComponent(() => import('@/components/LiveTopicPane.vue'))` cleanly defers loading until a topic thread is actually opened.
- **Files:**
  - `csi-spl-wui/src/layouts/default.vue`
- **Expected Gain:** **-50 to -60 KB gzip** off the initial home preload bundle (`ci_home_gzip_kb` drops from 344.2 KB to ~285 KB). Shaves ~15–25 ms off DOMContentLoaded on 3G/4G connections.
- **Effort:** **S** (1–2 hours).
- **Exact Measurement Command:**
  ```bash
  cd csi-spl-wui && npm run build:spa && node -e '
  const fs = require("fs");
  const zlib = require("zlib");
  const html = fs.readFileSync("dist/index.html", "utf8");
  const preloads = [...html.matchAll(/href="([^"]+\.js)"/g)].map(m => m[1].replace(/^\//, "dist/"));
  let totalGz = 0;
  for (const p of preloads) if (fs.existsSync(p)) totalGz += zlib.gzipSync(fs.readFileSync(p)).length;
  console.log("Preload bundle gzip KB:", (totalGz / 1024).toFixed(1));
  '
  ```

---

<a id="ws-doc-1be6eab8-58dd-4305-936f-d4c42f5217b2"></a>
#### Item 2: Defer rich composer features until user focus in `MessageComposer.vue`
- **What:** `MessageComposer.vue` is statically included in the channel feed. It eagerly loads markdown preview tools, attachment file drop handlers, search operator modals, and emoji trigger handlers. By wrapping the attachment preview drawer, drop zone, and rich formatting toolbar in `v-if="isFocused || hasDraft"` or dynamic imports, the initial feed mount only renders the lightweight textarea shell and action buttons.
- **Files:**
  - `csi-spl-wui/src/components/MessageComposer.vue`
- **Expected Gain:** **-12 to -15 KB gzip** from initial feed view bundle; reduces initial Vue hydration execution time by ~12 ms.
- **Effort:** **S** (2–3 hours).
- **Exact Measurement Command:**
  ```bash
  cd csi-spl-wui && npm run build:spa && ls -lh dist/client/_nuxt/*Composer*
  ```

---

<a id="ws-doc-2bcce472-0363-4191-bd0d-6406c2350a90"></a>
#### Item 3: Consolidate duplicate startup plugins (`theme.client.ts` and `preferred-theme.client.ts`)
- **What:** `src/plugins/theme.client.ts` and `src/plugins/preferred-theme.client.ts` both run during client hydration. Both inspect `localStorage.getItem('csi-theme')`, query `window.matchMedia('(prefers-color-scheme: dark)')`, and attach mutation listeners. Furthermore, `buildEarlyThemeScript` in `nuxt.config.ts` already synchronously injects the initial `data-theme` attribute into `<html>` inside the SSR `<head>` to prevent flash of unstyled content (FOUC). Merging these two client plugins into a single unified `theme.client.ts` removes redundant listeners, simplifies theme toggle reactivity, and eliminates duplicate code.
- **Files:**
  - `csi-spl-wui/src/plugins/theme.client.ts`
  - `csi-spl-wui/src/plugins/preferred-theme.client.ts`
- **Expected Gain:** **-1.5 KB gzip** bundle savings; eliminates redundant DOM attribute mutations and duplicated event listeners during the critical hydration window.
- **Effort:** **XS** (1 hour).
- **Exact Measurement Command:**
  ```bash
  cd csi-spl-wui && npm run build:spa && node -e '
  const fs = require("fs");
  const zlib = require("zlib");
  const manifest = JSON.parse(fs.readFileSync("dist/client/_nuxt/manifest.json", "utf8"));
  for (const [k, v] of Object.entries(manifest)) {
    if (k.includes("theme")) {
      const p = "dist/client/" + v.file;
      console.log(v.file, "gz:", zlib.gzipSync(fs.readFileSync(p)).length, "B");
    }
  }
  '
  ```

---

<a id="ws-doc-fd5d1d23-2cd2-4ca1-aa6f-262d9a64e2be"></a>
#### Item 4: Partition `uiIcons.ts` SVG dictionary into core and extended sets
- **What:** `src/utils/uiIcons.ts` is a single static dictionary of SVG path data containing ~60 icons across 17.1 KB of raw source code. Because `UiIcon.vue` references `uiIcons.ts` directly, any chunk that uses an icon bundles all 60 icons. Splitting the dictionary into `coreIcons` (~15 essential icons: hash, lock, chevron, send, search, close, check, alert) and dynamic or lazy-loaded extended sets (settings, admin, external integrations) keeps the entry chunk minimal.
- **Files:**
  - `csi-spl-wui/src/utils/uiIcons.ts`
  - `csi-spl-wui/src/components/UiIcon.vue`
- **Expected Gain:** **-8 to -12 KB raw (~3–4 KB gzip)** removed from the primary entry chunk `VaoSVFew.js` (currently 95.8 KB gzip / 298.7 KB raw).
- **Effort:** **S** (2 hours).
- **Exact Measurement Command:**
  ```bash
  cd csi-spl-wui && npm run build:spa && ls -lh dist/client/_nuxt/VaoSVFew.js
  ```

---

<a id="ws-doc-19bb0cc5-ffc5-4830-b9f2-31f60fbfbbb2"></a>
### Group 2: Aesthetics (Visual Consistency, Micro-interactions & Polish)

<a id="ws-doc-421b4393-50ac-4c6a-aeec-daf8b77279ca"></a>
#### Item 5: Themed thin scrollbars across desktop panels
- **What:** Currently, scrolling containers in `ChannelSidebar.vue`, `LiveFeed.vue`, and `TopicPane.vue` rely on default browser scrollbars. On Linux and Windows desktops, this displays thick 16px light-grey scrollbar tracks and thumbs that visually clash with the dark navy background (`#060912`, `#0c1220`). Adding standardized CSS scrollbar properties in `base.css` (`scrollbar-width: thin; scrollbar-color: var(--color-border-strong) transparent;` alongside `::-webkit-scrollbar` vendor rules) creates sleek, modern, unobtrusive scrollbars that match the theme.
- **Files:**
  - `csi-spl-wui/src/assets/css/base.css`
  - `csi-spl-wui/src/assets/css/theme.css`
- **Expected Gain:** Instant visual elevation and desktop polish across all main navigation and feed surfaces without layout shifts.
- **Effort:** **XS** (30 mins).
- **Exact Measurement Command:**
  ```bash
  grep -n "scrollbar-width" csi-spl-wui/src/assets/css/*.css
  ```

---

<a id="ws-doc-97a3a868-d5a1-4999-bac1-50f6c8ada662"></a>
#### Item 6: Standardize micro-transitions and focus rings on interactive controls
- **What:** Buttons (`UiButton.vue`), sidebar channel items (`ChannelSidebar.vue`), and message action bars currently transition abruptly between idle, hover, and active states (`transition: none` or uncoordinated timings). Introducing unified micro-transitions (`transition: color 120ms ease, background-color 120ms ease, border-color 120ms ease, box-shadow 120ms ease`) and standardized `:focus-visible` outline rings gives the interface a responsive, tactile desktop-app feel while meeting WCAG 2.1 focus visibility standards.
- **Files:**
  - `csi-spl-wui/src/assets/css/base.css`
  - `csi-spl-wui/src/components/UiButton.vue`
  - `csi-spl-wui/src/components/ChannelSidebar.vue`
- **Expected Gain:** Eliminates perceived UI "jank" on hover/clicks; improves keyboard navigation accessibility and visual refinement.
- **Effort:** **S** (2 hours).
- **Exact Measurement Command:**
  ```bash
  grep -rn "transition:" csi-spl-wui/src/components/UiButton.vue csi-spl-wui/src/assets/css/base.css
  ```

---

<a id="ws-doc-b715d0ac-49ec-426d-8139-303f39c2b339"></a>
#### Item 7: Skeleton placeholder card state in `LiveFeed.vue`
- **What:** When `LiveFeed.vue` initializes or switches channels, if `loading === true` and `rows.length === 0`, the viewport displays a blank container or a single spinner before populating with message cards. Reusing the pulse animation and placeholder structure from `spa-loading-template.html` to render 3–4 skeleton card outlines during initial channel retrieval prevents Cumulative Layout Shift (CLS) and delivers immediate visual feedback.
- **Files:**
  - `csi-spl-wui/src/components/LiveFeed.vue`
  - `csi-spl-wui/src/assets/css/base.css` (or `SkeletonCard.vue`)
- **Expected Gain:** Eliminates visual jarring and layout shift during channel transitions; improves perceived loading speed.
- **Effort:** **S** (2–3 hours).
- **Exact Measurement Command:**
  ```bash
  grep -rn "skeleton" csi-spl-wui/src/components/LiveFeed.vue
  ```

---

<a id="ws-doc-f833e5d8-7b0f-4bc5-a679-caf48d9f902f"></a>
#### Item 8: Elevated empty states with contextual icons and actionable guidance
- **What:** In empty channels or zero-result search views, `LiveFeed.vue` and `TopicPane.vue` render a bare `<p class="muted empty">No messages yet</p>`. Replacing this with an elevated empty state component containing a subtle muted icon, a friendly headline, and helpful guidance (e.g., "Send the first message to kick off discussion" or search filter hints like `is:topic`) transforms blank views into informative moments.
- **Files:**
  - `csi-spl-wui/src/components/LiveFeed.vue`
  - `csi-spl-wui/src/components/TopicPane.vue`
  - `csi-spl-wui/src/components/UiEmptyState.vue` (new reusable component)
- **Expected Gain:** Substantial improvement in first-time user experience and visual warmth in unpopulated channels.
- **Effort:** **S** (2 hours).
- **Exact Measurement Command:**
  ```bash
  grep -rn "class=\"empty" csi-spl-wui/src/components/
  ```

---

<a id="ws-doc-7e7efe9c-65b7-4acf-8888-dbbdfd4fb737"></a>
### Group 3: Clean Code (Maintainability, Architecture & Safety)

<a id="ws-doc-f39c8e19-2d6f-4977-a9b1-e72cea41f8ff"></a>
#### Item 9: Delete orphaned component `CheckoutHostStatus.vue`
- **What:** `csi-spl-wui/src/components/CheckoutHostStatus.vue` is a 34-line component that is completely unreferenced across all pages, layouts, components, and tests in the repository. It is obsolete dead code left behind by earlier checkout host prototypes. Removing it cleans up the component registry and prevents confusion.
- **Files:**
  - `csi-spl-wui/src/components/CheckoutHostStatus.vue` (delete)
- **Expected Gain:** Clean dead code elimination (-34 LOC); zero regression risk; removes maintenance overhead.
- **Effort:** **XS** (15 mins).
- **Exact Measurement Command:**
  ```bash
  grep -rn "CheckoutHostStatus" csi-spl-wui/src/
  ```

---

<a id="ws-doc-9d47df57-9b04-41e9-a9f5-4e873138959f"></a>
#### Item 10: Decompose 2,225-line monolith `ChannelSidebar.vue` into focused sub-components
- **What:** `ChannelSidebar.vue` is 2,225 lines long. It currently handles workspace switching tabs, channel category folding, direct message listings, unread badge calculation, drag reordering, and keyboard shortcut handling within one single component. Decomposing it into 3 clean sub-components (`SidebarRailTabs.vue`, `SidebarChannelList.vue`, `SidebarDmList.vue`) under `src/components/sidebar/` restores clean single-responsibility boundaries.
- **Files:**
  - `csi-spl-wui/src/components/ChannelSidebar.vue`
  - `csi-spl-wui/src/components/sidebar/SidebarRailTabs.vue` (new)
  - `csi-spl-wui/src/components/sidebar/SidebarChannelList.vue` (new)
  - `csi-spl-wui/src/components/sidebar/SidebarDmList.vue` (new)
- **Expected Gain:** Reduces `ChannelSidebar.vue` line count from 2,225 to ~400 lines; drastically cuts merge conflicts and simplifies unit testing of sidebar navigation.
- **Effort:** **M** (4–6 hours).
- **Exact Measurement Command:**
  ```bash
  wc -l csi-spl-wui/src/components/ChannelSidebar.vue
  ```

---

<a id="ws-doc-ac4642fd-c80e-47f1-9dfb-fd5d842633bc"></a>
#### Item 11: Unify fragmented ISO date and time formatting utilities
- **What:** Date and time formatting logic is fragmented across multiple utility files: `date-iso.mjs`, `date-iso-zone.mjs`, `iso-seconds.mjs`, `body-times.mjs`, and `topic-time.mjs`. Regex checks for ISO-8601 strings and UTC/local offset math are duplicated with slight discrepancies. Consolidating these utilities into a single cohesive module (`src/utils/datetime.ts`) centralizes formatting rules and safeguards against timezone calculation drift.
- **Files:**
  - `csi-spl-wui/src/utils/date-iso.mjs`
  - `csi-spl-wui/src/utils/date-iso-zone.mjs`
  - `csi-spl-wui/src/utils/iso-seconds.mjs`
- **Expected Gain:** Eliminates ~120 lines of duplicate utility code; guarantees unified ISO/timezone rendering across chat posts and topic headers.
- **Effort:** **S** (2–3 hours).
- **Exact Measurement Command:**
  ```bash
  wc -l csi-spl-wui/src/utils/*date*.mjs csi-spl-wui/src/utils/*iso*.mjs
  ```

---

<a id="ws-doc-4270908a-4604-40af-b071-3c9af21838b0"></a>
#### Item 12: Migrate core feed controllers (`channel-feed.mjs` and `feed.mjs`) to TypeScript
- **What:** 260 out of 272 files in `csi-spl-wui/src/utils/` are untyped `.mjs` scripts. The core feed state machines—`channel-feed.mjs` (412 lines) and `feed.mjs` (338 lines)—orchestrate critical real-time message stream ingestion, cursor pagination, deduplication, and update dispatching. Converting these two core files to `.ts` with formal interfaces matching backend Go message payloads prevents runtime property access bugs and provides IDE autocompletion for feed state consumers.
- **Files:**
  - `csi-spl-wui/src/utils/channel-feed.mjs` -> `channel-feed.ts`
  - `csi-spl-wui/src/utils/feed.mjs` -> `feed.ts`
- **Expected Gain:** Full static type safety across the central message streaming pipeline; catches message shape discrepancies at compile time.
- **Effort:** **M** (3–4 hours).
- **Exact Measurement Command:**
  ```bash
  npx tsc --noEmit -p csi-spl-wui/tsconfig.json
  ```
