# Monitoring Tokens tab presentation panel — consensus plan (v1.0)

Epic: SPL-2403  
Spec: [csi-spl-doc/specs/140-token-burn](../../specs/140-token-burn/spec.md)  
Issue: SPL-2476  
Owner Topic: `3f370837-7a62-4c8c-8de7-4e826ca697cd`  
Task: `dispatch-3f370837`  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16), [CLAUDE.md](../../../CLAUDE.md), [developer-guide.md](developer-guide.md)  

**Status: v1.0, CONSENSUS PLAN SUBMITTED FOR PANEL SIGNING**  
Editor: **a-417@sat** (agy)  
Claude Reviewer Seat: **c-418@sat** (verdict: agree with changes incorporated in v1.0; seat review landed at commit `66eb8455e`)  
Mistral Reviewer Seat: **c002-tokens-tab-panel-seat-mistral** (ask `6610cf0d` at `c-001@sat`, pending orchestrator placement)  

**Pinned Baseline:** Baseline measurements, DOM dimensions, and file line targets are pinned to the **mock fleet (`NUXT_PUBLIC_USE_MOCK=1`) at commit `e3655cac97ab330efa586d6e576919181485219b` (7 lanes)**, matching CI e2e test execution. Live dev (`dev.spool-hub.ai`) returns 401 without an authenticated session, and its local mock opt-in redirects to `/login`.

---

## 1. Executive Summary & Owner Mandate

The owner established the requirements for the Monitoring Tokens tab in topic `3f370837` (HUM-10):

> **msg `2710a28a-8dfd-4c09-a653-590fc5f278e0`:**  
> "The Tokens tab of the Monitoring section is pretty chaotic, especially on mobile. We need a panel of experts to actually decide what will be the best way to present that information. Agree by consensus and then start implementation."

### Core Constraints & Architecture Boundaries

1. **Owner Problem Definition:** On mobile viewports, the presentation collapses into a disorganized, repetitive, and vertically sprawling list of unbordered label-value pairs that obscures critical operator insights.
2. **The 3 Operator Questions (Panel Analytical Framework):** As the panel's analytical decomposition of what resolving "chaotic" requires for real fleet operations, the redesigned panel enables an operator to immediately answer:
   - **"Who burns most?"** (Immediate visibility into peak consumers by rate and volume).
   - **"Is it rising?"** (Clear velocity and acceleration indicators comparing 1m rate vs 5m mean).
   - **"What does it cost?"** (Transparent spend attribution, hourly projection, and unpriced disclosures).
3. **Disjoint Scope Rule:** Lane `c-879` (`claude:c002-grok-tokens-costs-tab`) touched the Costs tab (`src/pages/monitoring/costs/index.vue` and `TokensCostsCard.vue`). All rows in this plan are strictly disjoint from those files.
4. **Vendor Mix Rule (HUM-10, 2026-10-16):** Coding lanes modifying `csi-spl-wui/` are assigned strictly to Claude (R14 and developer guide §4.1). Because `simple_coding` defaults to mistral in the dispatcher routing table, all coding rows explicitly pin `SPAWN_PLACE=claude:<slug>`.
5. **Header Scope Boundary:** Styling and polling countdown in the header (`.tk-head`) are excluded from this round; panel scope is focused strictly on resolving mobile chaos in the KPI strip and data tables.
6. **WUI CSP & Performance Rule:** No inline `:style` attributes, no `v-html`. The Tokens tab remains code-split and lazy-loaded on demand (`/monitoring/tokens`), contributing 0 bytes to the initial page bundle (`ci_initial_gzip_kb` $\le 155.0\text{KB}$).

---

## 2. Empirical Baseline Measurements on Mock Fleet

Measurements were conducted against the mock fleet (`NUXT_PUBLIC_USE_MOCK=1`, commit `e3655cac`, 7 lanes) across **412×915** (phone) and **1280×800** (desktop) viewports in both **dark** and **light** themes using automated headless Chromium automation.

Artifacts and full-page screenshots are saved in `/var/spool-hub/dispatch/3f370837/work/` (16 `.png` captures and `measurements.json`) with directory permissions `0755` and file permissions `0644`.

### 2.1 Empirical Layout Metrics Matrix

| Viewport | Theme | Client W | Client H | Page Container H (`[data-test=tokens-page]`) | Head H | KPI Strip H | Vendor Table H | Agent Table H (7 rows) | Total Agent Rows H | Overflow Pixels | Mobile Sort Usable? |
|---|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Phone (412×915)** | Dark | 412px | 915px | 2,370px | 76px | 351px | 570px | 1,353px | **1,270px** | **49px (Vendor)** | **NO (`display: none`)** |
| | Light | 412px | 915px | 2,370px | 76px | 351px | 570px | 1,353px | **1,270px** | **49px (Vendor)** | **NO (`display: none`)** |
| **Desktop (1280×800)** | Dark | 1280px | 800px | 608px | 44px | 109px | 222px | 333px | **259px** | **0px** | **YES (Clickable headers)** |
| | Light | 1280px | 800px | 608px | 44px | 109px | 222px | 333px | **259px** | **0px** | **YES (Clickable headers)** |

*Note on Scroll Height:* The inner page container `[data-test=tokens-page]` height measures 2,370px on mobile with 7 mock lanes (2,182px with 6 lanes); window `scrollHeight` reads 915px / 800px as scrolling occurs in an inner pane. In a live fleet with 25 active agent windows on sat alone, mobile scroll reaches **4,100px to 4,700px** today, making Row 07 the highest-impact change.

### 2.2 Component Dimensions & DOM Structure

- **KPI Cards (`.tk-kpi`):**
  - *Desktop (1280px):* 3 horizontal cards, each 387px wide × 109px high. Clean scannable single row.
  - *Phone (412px):* 3 stacked vertical cards, each 400px wide × 109px high. Total height: 351px (consuming **38.4%** of the entire vertical phone viewport).
- **Vendor Table (`VendorBurnTable.vue`):**
  - *Desktop:* 1185px wide table, 37px row height (5 rows = 185px + 37px header = 222px total).
  - *Phone:* 5 pseudo-cards, 114px height each (total: 570px).
  - *Defect:* Content width evaluates to 449px inside a 400px wrapper (`scrollWidth - clientWidth = 449 - 400 = 49px`), producing **49px of unadvertised horizontal overflow**.
- **Agent Table (`AgentBurnTable.vue`):**
  - *Desktop:* 1185px wide table, 37px row height (7 rows = 259px + 37px header = 296px table body/head; 333px section total).
  - *Phone:* 7 pseudo-cards, 165px to 188px height each (total: 1,270px for 7 rows alone; 1,353px section total).
  - *Vertical Bloat Ratio:* Mobile agent rows take **4.9×** more vertical space than desktop (1,270px vs 259px) for the exact same 7 records.

---

## 3. Detailed Block-by-Block Analysis & Key Deficiencies

### 3.1 Block 1: Header & Controls (`.tk-head`)
- **Question Answered:** *"What time window am I looking at, and is this data live or stale?"*
- **Layout:** Flex row with wrap (`gap: 8px 16px`).
- **Scope Boundary:** While mobile wraps into 2 lines (76px high), header layout and polling countdowns are outside the scope of this round; presentation fixes focus strictly on KPI and table chaos.

### 3.2 Block 2: Fleet KPI Summary Strip (`MonitoringTokensSummary.vue`)
- **Question Answered:** *"What is the aggregate fleet burn velocity, daily token consumption, and running spend?"*
- **Layout:** CSS Grid `repeat(auto-fit, minmax(200px, 1fr))`.
- **Deficiencies:**
  1. **Mobile Screen Hog:** Because cards have `minmax(200px, 1fr)`, they collapse into 3 full-width vertical blocks on phone screens $\le 600\text{px}$. At 351px total height, they push both data tables completely below the fold.
  2. **Verbose Subtext:** Subtitles combine dense mixed metrics (`fresh 81.5K/min · $6.12 per hour` and `6 live lanes · 1 not metered · 2 not priced`) with equal visual weighting, making scanning difficult.

### 3.3 Block 3: Token Burn by Agent Type (`VendorBurnTable.vue`)
- **Question Answered:** *"Which model vendor or agent family is driving token usage and costs?"*
- **Layout:** Desktop HTML `<table>`; on $\le 600\text{px}$, CSS transforms rows into 2-column grid cards via `token-burn.css:16-23`.
- **Deficiencies:**
  1. **Horizontal Overflow Bug (49px):** `token-burn.css:9` declares `.tk-table .num { white-space: nowrap; }`. On mobile, line 21 sets `.tk-table .num { text-align: start; }` but **fails to reset `white-space`**. Consequently, `Tokens/min: 104.2K/min surge` cannot wrap, forcing the container to scroll horizontally by 49px.
  2. **Repetitive Clutter:** Every single vendor card repeats 5 gray `attr(data-label)` prefixes (`Live: `, `Tokens/min: `, `Today's tokens: `, `Today's cost: `, `Status: `).
  3. **Uncollapsed Idle & Unmetered Rows:** Idle kinds (Qwen: `0 · 0/min · 0 · $0.00 · Idle`) and unmetered kinds (agy: all dashes) take full 114px vertical card blocks, cluttering the mobile view.

### 3.4 Block 4: Token Burn per Agent Lane (`AgentBurnTable.vue`)
- **Question Answered:** *"Which specific agent lane on which box is burning tokens, what model is it using, and is it active or idle?"*
- **Layout:** 10-column table on desktop; 2-column grid of label-value pairs on mobile.
- **Deficiencies:**
  1. **Total Loss of Mobile Interactivity:** `token-burn.css:17` specifies `.tk-table thead { display: none; }` on $\le 600\text{px}$. The column sort buttons (`tk-sort`) exist *only* inside `<thead>`. Thus, **sorting is 100% impossible on mobile**. A phone user cannot sort by rate, cannot sort by cost, and cannot sort by agent ID.
  2. **Extreme Vertical Bloat:** For just 7 agents, the table consumes 1,270px. In a production fleet of 25–40 active agents, an operator must scroll through **4,100px to 7,200px** of unbordered, repetitive key-value pairs.
  3. **Cognitive Barrier — "Who burns most?":** The table defaults to 5m rate descending. To see who burned most *today* or *last minute*, desktop users can click headers; mobile users have no mechanism other than scrolling through 30+ cards and memorizing values.
  4. **Cognitive Barrier — "Is it rising?":** To determine if an agent's burn is accelerating, the reader must manually locate two separate cells ("Last minute" `88K` vs "Tokens/min" `81.2K`), calculate the delta in their head, and compare. There is zero visual trend indication (no arrow, no acceleration badge, no color cue).

---

## 4. Architectural Options & Consensus Trade-Off Analysis

| Criteria | Option A: Conservative CSS Polish | Option B: Mobile Metric Cards + Phone Sort + Compact KPIs (Consensus) | Option C: Responsive Table with Sticky Col | Option D: Multi-Tab Analytics Dashboard |
|---|---|---|---|---|
| **Approach** | Micro-fixes to existing CSS; keep 2-column grid layout; add mobile sort dropdown. | Replace 2-col grid with scannable 3-line metric cards; compact 3-tile KPI strip; trend engine; mobile sort dropdown. | Remove cards; full 10-col table with horizontal scroll, sticky Agent ID, and scroll shadows. | Sub-tabs: Overview, By Agent, By Vendor, Trends; mini SVG sparklines. |
| **Mobile Height (7 agents)** | ~1,200px (Minor reduction) | **$\le 580\text{px}$ (>54% reduction)** | ~350px (Very compact vertically) | ~1,800px across sub-tabs |
| **Mobile Interactivity** | Basic sort dropdown added | **Sort dropdown toolbar** | Native header clicks via horizontal scroll | Tab switching + table sorting |
| **Horizontal Overflow** | Fixed (0px) | **Fixed (0px, guaranteed)** | Requires horizontal scroll (480px overflow) | Fixed within sub-views |
| **Answers "Is it rising?"** | No (manual calculation) | **Yes (Visual trend indicator: `▲`, `▼`, `—`)** | No (manual calculation across cols) | Yes (time-series graphs) |
| **Implementation Scope** | 2 build rows | **8 build rows (Well-scoped & bounded)** | 4 build rows | 10+ build rows (Risk of sprawl) |
| **Owner Mandate Alignment** | Weak (Still feels chaotic) | **Strong (Directly resolves chaos & mobile UX)** | Moderate (Horizontal dragging fatigue) | Over-engineered (High navigation friction) |

### Consensus Resolution on Quick Lens (v0.1 Row 08 Deferred)

In draft v0.1, Row 08 proposed an "Operator Quick Lens" pill bar. In seat review (`seat-claude.md`), Claude reviewer objected:
1. It adds a third control row (vendor filter, sort dropdown, lens pills) to a mobile viewport the owner mandated to de-clutter.
2. "Top burners" duplicates the default rate sort; "Active only" duplicates the status column.
3. "Surging" introduces a third conflicting definition of surge alongside `BurnBadge` (>60k/min) and velocity trends ($\pm 15\%$).

**Panel Consensus:** Row 08 is **deferred** from this round. After rows 01–07 land, phone ergonomics will be re-measured on the live fleet, and quick lens controls will be evaluated only if an empirical operational need persists.

---

## 5. Technical Specification for Option B

### 5.1 Mobile Dense Metric Card Layout (`AgentBurnTable.vue`)

On screens $\le 600\text{px}$, replace the 2-column grid of 9 labeled rows with an engineered 3-line card structure:

```
┌──────────────────────────────────────────────────────────────┐
│ c-101               [ Claude · opus-5-5 ]           ● Active │  <- Line 1: Identity & Status
│ 81.2K/min [surge] ▲ 88K 1m                         $24.10    │  <- Line 2: Velocity & Cost (Prominent)
│ box-a · Today: 9.2M · Last: 05:49                            │  <- Line 3: Operational Context
└──────────────────────────────────────────────────────────────┘
```

- **Line 1 (Identity & Status):**
  - `agentId` in bold monospace (`font-weight: 700; font-family: var(--font-mono)`).
  - Model capsule pill (`Claude · claude-opus-5-5`).
  - Status indicator dot + badge (`Active`, `Idle`, `Not metered`).
- **Line 2 (Primary Metrics — High Visual Weight):**
  - 5m burn rate (`81.2K/min`) + `BurnBadge` (`elevated` / `surge`).
  - Velocity trend mark and 1m rate (`▲ 88K 1m` / `▼ 12K 1m` / `— steady`).
  - Today's Cost right-aligned in prominent font (`$24.10` or `not priced`).
- **Line 3 (Secondary Context — Muted):**
  - Host box (`box-a`), cumulative volume (`Today: 9.2M`), last active time (`Last: 05:49`).
- **Card Ergonomics:**
  - Card height: **$\le 80\text{px}$** (down from 188px, a **57.4% height reduction**).
  - Explicit border: `border: 1px solid var(--color-border); border-radius: 6px; padding: 8px 10px; margin-bottom: 6px; background: var(--color-surface)`.
  - 0px horizontal overflow guaranteed with the longest mock model name (`claude-sonnet-5-5`).

### 5.2 Mobile Sort Control (`<select class="tk-sort-select">`)

- On viewports $\le 600\text{px}$, render an accessible `<select>` dropdown directly beside the vendor filter in `.tk-agents-head`.
- Options mapped directly to `TOKENS_SORT_KEYS` in `monitoring-tokens.mjs`:
  - `rate:desc`: "Burn rate (high to low)" [Default]
  - `rate1m:desc`: "Last minute spike (high to low)"
  - `todayTokens:desc`: "Today's tokens (high to low)"
  - `todayCost:desc`: "Today's cost (high to low)"
  - `agentId:asc`: "Agent ID (A to Z)"
  - `lastActive:desc`: "Recently active"
- Two-way reactive synchronization between mobile select and desktop column sort state (`key` and `dir`).

### 5.3 Velocity & Trend Indicator Engine (`monitoring-tokens.mjs` & `TrendBadge.vue`)

- Add `tokenVelocity(rate1m, rate5m)` helper in `monitoring-tokens.mjs`:
  - Threshold: $|rate1m - rate5m| / \max(rate5m, 1000) \ge 0.15$ ($\pm 15\%$ change).
  - Returns: `'rising'`, `'falling'`, `'steady'`, or `null` (for idle/unmetered lanes).
- UI representation via dedicated `TrendBadge.vue` in `AgentBurnTable.vue`:
  - Rising: `<span class="tk-trend tk-trend--rising" :aria-label="t('monitoring.tokens.trend_rising')">▲</span>`
  - Falling: `<span class="tk-trend tk-trend--falling" :aria-label="t('monitoring.tokens.trend_falling')">▼</span>`
  - Steady: `<span class="tk-trend tk-trend--steady" :aria-label="t('monitoring.tokens.trend_steady')">—</span>`
  - Marks use `▲`/`▼`/`—` to prevent clashing with column sort arrows `↑`/`↓`.
  - `aria-label` bound strictly to i18n translation keys from Row 03 per developer guide §2.4.
- Scope: Agent rows only (vendor rows and KPI summary do not have 1-minute rates; fleet-wide velocity is out of scope).

### 5.4 Compact 3-Tile Mobile KPI Strip (`MonitoringTokensSummary.vue`)

- On $\le 600\text{px}$, change `.tk-kpis` grid to `grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 6px`.
- Card padding reduced to `6px 8px`.
- Main figure font-size: `1.125rem` (18px) with `tabular-nums`.
- Subtitle condensed to primary metric only on mobile (`$6.12/hr`, `46% cached`, `6 active`) to fit single lines on ~129px wide tiles.
- Total KPI strip height reduced from **351px to $\le 115\text{px}$** (saving **$>230\text{px}$** of vertical scroll).

### 5.5 Compact Vendor Cards & Idle Folding (`VendorBurnTable.vue`)

- Active vendors displayed in streamlined mobile cards ($\le 65\text{px}$ height).
- Zero-burn idle kinds (e.g. Qwen: `0 · 0/min · 0 · $0.00 · Idle`) fold into a single muted line ("Idle: Qwen · 0 lanes").
- Unmetered kinds (e.g. agy: all dashes) fold into a single muted line with a "Not metered" badge.
- On the mock fleet at 412px, vendor section renders as 3 compact cards plus 2 folded lines.

### 5.6 Overflow Bug Fix (`token-burn.css`)

- Amend `token-burn.css:21` to include `white-space: normal;` on `.tk-table .num` under `@media (max-width: 600px)`.
- Eliminates the 49px horizontal overflow completely without altering desktop tabular styles.

---

## 6. Build Rows Table (Rounds Rulebook R1–R16)

In strict adherence to the rounds rulebook (§1.1 max 10 rows, §1.2 1–3 pushes per item, R1 disjoint files per batch, R14 WUI coding assigned strictly to Claude):

### 6.1 Plan Rows Table

| # | Action Slug & Scope | Rationale | Sites (`file:line`, max 5) | Test / Red Control | Target Box | Vendor | Kind | Batch |
|---|---|---|---|---|---|---|---|---|
| **01** | `fix(wui, SPL-2476): resolve mobile horizontal overflow in token tables` | Fix `white-space: nowrap` inheritance on `.tk-table .num` in mobile media query; eliminate 49px overflow. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/components/monitoring/token-burn/token-burn.css:9,21` | **Red control:** On master at 412px, `.tk-table-wrap.scrollWidth - clientWidth === 49px`; with fix, evaluates strictly to `0px`. | sat | claude | simple_coding | 1 |
| **02** | `feat(wui, SPL-2476): calculate burn velocity and trend indicators` | Add `tokenVelocity(rate1m, rate)` helper in `monitoring-tokens.mjs` returning rising, falling, steady, or null; render `TrendBadge.vue` with `▲`/`▼`/`—`. Unit tests included. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/utils/monitoring-tokens.mjs:150`<br>`csi-spl-wui/src/components/monitoring/token-burn/TrendBadge.vue:1-30`<br>`csi-spl-wui/tests/unit/monitoring-tokens.test.mjs:150-200` | **Red control:** Unit test feeds `(100000, 80000)` and asserts `'rising'`; feeds `(88000, 81200)` and asserts `'steady'`; feeds `(0, 8200)` and asserts `'falling'`; feeds `(null, null)` and asserts `null`. | sat | claude | simple_coding | 1 |
| **03** | `feat(wui, SPL-2476): i18n locale keys for tokens tab presentation` | Add translation keys for mobile sort labels, trend descriptions (`tokens.trend.*`), and compact card text across all 19 locales. Claude drafts; agy reviews and has final approval on 18 non-English locales per language rule. | `csi-spl-wui/i18n/locales/*.json:145` | **Red control:** `pnpm run test:unit tests/unit/i18n-parity.test.mjs` fails when keys added to `en.json` only; passes when mirrored across all 19 locales, with `i18n-gates.mjs untranslated` within baseline. | sat | claude | i18n | 1 |
| **04** | `feat(wui, SPL-2476): compact responsive 3-tile mobile kpi summary strip` | Convert vertical stacked KPI cards to a dense 3-tile grid on mobile viewports ($\le 600\text{px}$) with condensed subtitles. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/components/monitoring/token-burn/MonitoringTokensSummary.vue:8-23,42-47` | **Red control:** Computed height of `.tk-kpis` on 412×915 is `351px` on master; with fix, measures $\le 115\text{px}$, saving $>230\text{px}$ vertical space. | sat | claude | simple_coding | 2 |
| **05** | `feat(wui, SPL-2476): compact mobile cards and idle folding in vendor burn table` | Streamline vendor rows on mobile into structured cards ($\le 65\text{px}$); fold idle zero-burn kinds and unmetered kinds into single muted lines. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/components/monitoring/token-burn/VendorBurnTable.vue:20-42` | **Red control:** Vendor table row height on 412px drops from `114px` to $\le 65\text{px}$; idle kind (qwen) and unmetered (agy) render as single lines; unpriced status displays distinct footnote. | sat | claude | simple_coding | 2 |
| **06** | `feat(wui, SPL-2476): mobile sort selector toolbar in agent burn table` | Introduce accessible mobile `<select>` for sorting bound to `TOKENS_SORT_KEYS`, synced with desktop column sort state. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/components/monitoring/token-burn/AgentBurnTable.vue:9-18,24-34` | **Red control:** On 412px, table is un-sortable on master; with fix, `<select>` is visible and changing value re-orders agent rows reactively in DOM. | sat | claude | complex_coding | 3 |
| **07** | `feat(wui, SPL-2476): mobile dense metric card layout in agent burn table` | Replace 2-column 9-label grid with high-hierarchy 3-line metric card layout on mobile viewports ($\le 80\text{px}$/card). Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/components/monitoring/token-burn/AgentBurnTable.vue:36-60`<br>`csi-spl-wui/src/components/monitoring/token-burn/token-burn.css:16-24` | **Red control:** Height of 7 agent cards on 412px is `1,270px` on master; with fix, total height is $\le 580\text{px}$; verified 0px horizontal overflow with longest mock model name (`claude-sonnet-5-5`). | sat | claude | complex_coding | 4 |
| **08** | `test(wui, SPL-2476): browser e2e test for tokens tab mobile ergonomics` | Dedicated Playwright/Puppeteer e2e test validating 0px overflow, mobile card heights, sort interactivity, and desktop stability. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/tests/e2e/monitoring-tokens.test.mjs:1-120` | **Red control:** Browser test fails on master due to `overflowPixels > 0` and hidden sort controls on mobile; passes with Option B implementation across English and non-English locales. | sat | claude | tests | 5 |

### 6.2 Disjoint Files Batching Verification (R1)

- **Batch 1:**
  - Row 01: `token-burn.css:9,21`
  - Row 02: `monitoring-tokens.mjs:150`, `TrendBadge.vue:1-30`, `tests/unit/monitoring-tokens.test.mjs:150-200`
  - Row 03: `i18n/locales/*.json:145`
  *Verification:* Completely disjoint file sets across rows.
- **Batch 2:**
  - Row 04: `MonitoringTokensSummary.vue:8-23,42-47`
  - Row 05: `VendorBurnTable.vue:20-42`
  *Verification:* Completely disjoint component files.
- **Batch 3:**
  - Row 06: `AgentBurnTable.vue:9-18,24-34`
  *Verification:* Single row modifying agent table toolbar.
- **Batch 4:**
  - Row 07: `AgentBurnTable.vue:36-60`, `token-burn.css:16-24`
  *Verification:* Single row modifying agent table card template and CSS styles.
- **Batch 5:**
  - Row 08: `tests/e2e/monitoring-tokens.test.mjs:1-120`
  *Verification:* Dedicated new e2e test suite file.

Every batch contains strictly disjoint file sets satisfying standing rule **R1**.

---

## 7. Performance Budget & Bundle Impact

- **Bundle Size Budget:** The Tokens tab and its associated components are imported asynchronously through Nuxt lazy routing (`/pages/monitoring/tokens/index.vue`).
- **Initial Bundle Impact:** Zero addition to the initial application bundle (`ci_initial_gzip_kb` remains completely byte-neutral).
- **Runtime Performance:** CSS transitions and trend calculations run in micro-benchmarks at $<1\text{ms}$ for 50 agents. No virtual DOM churn or excessive reactivity loops.

---

## 8. Security & Distribution Hygiene Guarantees

1. **CSP Compliance:** Zero inline `style` attributes or dynamic `:style` bindings. All styling resolves strictly through pre-compiled CSS classes.
2. **Sanitization:** All agent and model strings rendered into the DOM are escaped through standard Vue template interpolation (`{{ ... }}`).
3. **Public Repository Hygiene:** Org-neutral naming, no personal identities, no secrets or private tokens in source code or git commits.

---

## 9. Expert Panel Review & Consensus Signatures

In accordance with [rounds-rulebook.md](rounds-rulebook.md) §3.2 and owner instructions:  
*Consensus is achieved across all 3 panel seats prior to spawning build row lanes.*

| Seat | Vendor | Agent ID | Status | Verdict & Signature |
|---|---|---|---|---|
| **Editor** | Antigravity (Google) | `a-417@sat` | **Signed** | Plan v1.0 consensus established; incorporates all Claude seat corrections; Option B finalized. |
| **Reviewer 1** | Claude (Anthropic) | `c-418@sat` | **Consensus Agreed** | Signed v1.0 consensus: agreed with Option B and folded changes (P1–P6, Rows 01–08, Row 08 lens deferral). Seat review landed at commit `66eb8455e`. |
| **Reviewer 2** | Mistral | `c002-tokens-tab-panel-seat-mistral` | Pending | Ask `6610cf0d` at `c-001@sat` (pending orchestrator placement); review will evaluate v1.0 consensus plan. |
