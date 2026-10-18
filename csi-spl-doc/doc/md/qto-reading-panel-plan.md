# Qto reading panel — consensus plan (v0.1)

Epic: SPL-2403  
Spec: [csi-spl-doc/specs/137-qto-only-doc-editor](../../specs/137-qto-only-doc-editor/spec.md)  
Issue: SPL-2493 (status: wip)  
Owner Topic: `a1b42c34-3e46-4f97-8b8f-76c90513a8f4` (HUM-10, t1)  
Task: `dispatch-a1b42c34`  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16), [CLAUDE.md](../../../CLAUDE.md), [developer-guide.md](developer-guide.md)  

**Status: v0.1, DRAFT SUBMITTED FOR PANEL REVIEW**  
Editor: **a-428@sat** (Antigravity / Google)  
Claude Reviewer Seat: **c002-qto-reading-panel-seat-claude** (waiting for v0.1 sha)  
Mistral Reviewer Seat: **c002-qto-reading-panel-seat-mistral** (waiting for v0.1 sha)  

**Pinned Baseline:** Commit `a28394183e9ce81091ceca96d01f2f17d2ba6816` on `origin/master` (2026-10-18). Measurements taken on live dev (`https://dev.spool-hub.ai`, served commit `b59bef308c37b4398e856f12813c376f7e932b09`, WUI v2.1.6) and repository component trees at 412×915 (phone) and 1280×800 / 1440×900 (desktop).

---

## 1. Executive Summary & Owner Mandate

The owner established the requirements for the Qto document reading panel in topic `a1b42c34` (HUM-10, 2026-10-17 23:59Z+), verbatim:

> **msg `080e8375`:**  
> "Make the QTO mobile version actually usable."  
> *(Accompanied by phone screenshot `/var/spool-hub/dispatch/posts/c002-a1b42c34-shot.jpg`: Android Chrome, 1080×2340 px, v2.1.2, /docs Outline view of a runbook).*
>
> **msg `02749694`:**  
> "Check how much extra space there is taken on mobile. For example, this whole thing document is unneeded. The icons could be taken up, so it could be just one small stripe up, and now it's basically unusable."
>
> **msg `2f96da97`:**  
> "Create a panel of experts so that they will discuss how this should be modified to achieve the best possible visibility and usability. Be able to read long documentation for the type of documents that the QTO is supposed to be producing."

### 1.1 The Two Concrete Owner Directives

1. **Remove the `< Documents` Title Row on Phone (msg `02749694`):** The header block containing the title "Documents" (or `< Documents`) is unneeded vertical waste on a mobile reading screen. The Back navigation action must fold into the single control strip below.
2. **ONE Small Stripe at the Top (msg `02749694`):** Consolidate document navigation, document title/picker, Outline/Grid toggle, and toolbar actions into **one single compact top stripe** (40–44 px height) rather than 4 stacked rows.

### 1.2 Target Performance Goal

- **Text Viewport Share:** Document text content must occupy **$\ge 75\%$** of the vertical mobile viewport while reading (up from ~50% in the owner's baseline screenshot).
- **Zero Collision Guarantee:** No interface element (toolbar, floating action button, or composer dock) may intersect or cover any document text node.

---

## 2. Empirical Baseline Measurements on Origin/Master

Measurements were conducted on origin/master commit `a28394183e9ce81091ceca96d01f2f17d2ba6816` across **412×915 CSS px** (Android Chrome 1080×2340 physical px, `devicePixelRatio: 2.625`, matching the owner's phone) and **1280×800 / 1440×900 CSS px** (desktop) viewports using automated headless Chromium automation.

Measurements were evaluated against four long public documents representative of the documentation kinds Qto produces:
1. **Runbook Doc:** `DEPLOY.md` (Operational procedures, deployment commands, code blocks).
2. **Tasks Table / UI Layout Doc:** `csi-spl-doc/doc/help/interface-overview.md` (Exported from Qto doc `5f109deb-12fe-4cfd-87f1-4273e518a46e`, featuring Markdown tables, navigation trees, and callouts).
3. **Spec / Guide Doc:** `csi-spl-doc/doc/help/getting-started.md` (Structured technical guide with headings, numbered steps, and links).
4. **Repository Overview Doc:** `README.md` (System overview, feature inventory, tables).

Full-resolution `.png` screenshots are saved in `/var/spool-hub/dispatch/a1b42c34/work/` (8 captures, 2.7 MB total):
- `qto-phone-412-interface-overview.png`
- `qto-desktop-1280-interface-overview.png`
- `qto-phone-412-deploy-runbook.png`
- `qto-desktop-1280-deploy-runbook.png`
- `qto-phone-412-getting-started.png`
- `qto-desktop-1280-getting-started.png`
- `qto-phone-412-readme.png`
- `qto-desktop-1280-readme.png`

### 2.1 Empirical Layout Metrics Matrix

| Document | Kind | Viewport | Top Chrome H | Bottom Chrome H | Available Text H | Text H Share | Avg Words/Line (L0/L1/L2) | Text Width Share | Table Overflow |
|---|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **`interface-overview.md`** | Tasks table (Qto) | **Phone (412×915)** | 111 px | 73 px | 731 px | **79.9%** (repo) / **~50%** (Qto) | 6.0 / 5.9 / 5.1 | 91.5% | 0 px |
| | | **Desktop (1280×800)** | 115 px | 0 px | 685 px | **85.6%** | 10.7 (avg) | 67.3% (861px) | 0 px |
| **`DEPLOY.md`** | Runbook | **Phone (412×915)** | 111 px | 73 px | 731 px | **79.9%** (repo) / **~50%** (Qto) | 5.6 / 5.5 / — | 94.1% | 350 px & 314 px |
| | | **Desktop (1280×800)** | 115 px | 0 px | 685 px | **85.6%** | 10.2 (avg) | 67.3% (861px) | 0 px |
| **`getting-started.md`** | Spec / Guide | **Phone (412×915)** | 111 px | 73 px | 731 px | **79.9%** (repo) / **~50%** (Qto) | 6.0 / 5.4 / — | 93.2% | 0 px |
| | | **Desktop (1280×800)** | 115 px | 0 px | 685 px | **85.6%** | 11.3 (avg) | 67.3% (861px) | 0 px |
| **`README.md`** | Repo overview | **Phone (412×915)** | 111 px | 73 px | 731 px | **79.9%** (repo) / **~50%** (Qto) | 5.4 / 4.0 / — | 95.4% | 153 px |
| | | **Desktop (1280×800)** | 115 px | 0 px | 685 px | **85.6%** | 9.6 (avg) | 67.3% (861px) | 0 px |

*Note on Repo `/docs` vs Qto `/workspace/docs` Chrome Breakdown:*  
In the static repo `/docs` viewer, top chrome is 111 px (top bar 58 px + header 53 px). In the interactive Qto document viewer (`WorkspaceDocsPage.vue` + `WorkspaceDocView.vue`, as shown in the owner's phone screenshot), top chrome balloons to **235 px** (top bar 58 px + `< Documents` header row 48 px + document picker 42 px + Outline/Grid tabs 42 px + sticky 3-icon toolbar 45 px), reducing visible text height to just **604 px / 915 px (66.0% CSS height, ~50% physical height with OS status/nav bars)**.

### 2.2 Identification of Four Critical Layout Overlaps & Obstructions

1. **Overlap 1 — Toolbar Over First Text Line:**  
   In `WorkspaceDocView.vue` (lines 35–58, 1018–1029), `.wsdoc__bar` is rendered with `position: sticky; top: 0; z-index: 3`. On mobile viewports $\le 600\text{px}$, `inHead` evaluates to `false` (via `-doc-headbar.ts:13`), disabling desktop teleportation. When the page renders or scrolls, `.wsdoc__bar` sits directly on top of the document preamble or the first section heading (`.wsdoc__h`). In the owner's screenshot (`c002-a1b42c34-shot.jpg`), the first line of the runbook ("Who: Csitea Oy Ab (VAT") is clipped and unreadable beneath the three toolbar icons (`file-text`, `menu`, `file-code`).
2. **Overlap 2 — Floating Action Button Covering Text Ends:**  
   In `WorkspaceDocsPage.vue` (lines 28–30, 368–377), `.wsdocs-fab` renders as a fixed circular 56×56 px button pinned at `bottom: calc(16px + ...); inset-inline-end: 16px; z-index: 15`. In outline reading mode, paragraph text runs the full width of the container. The floating FAB hovers directly over the right end of the bottom-most visible text lines, obscuring the final words of every paragraph that scrolls behind it.
3. **Overlap 3 — Bottom Composer Dock on Reading Routes:**  
   In `layouts/default.vue` and `MessageComposer.vue` (lines 1079–1115), the OmniBox composer dock renders at the bottom of the mobile viewport (`--composer-dock-h` ~51–73 px) plus the `MobileStatusStrip.vue` (~22 px). On `/docs` and `/workspace/docs`, where reading long technical documentation is the sole activity and messaging is inactive, this bottom chrome consumes **73–95 px** of vertical screen real estate without providing any reading value.
4. **Overlap 4 — Table of Contents Drawer Full Coverage:**  
   In `WorkspaceDocView.vue` (lines 1271–1283), opening the Table of Contents on mobile (`@container (max-width: 760px) .wsdoc__toc`) mounts a fixed drawer `width: min(20rem, 88vw)` covering 88% of the viewport width, completely blocking the reader's view of the text underneath without an ambient backdrop tap-to-dismiss.

### 2.3 Indentation & Words-Per-Line Analysis

- **Container Indent:** In `WorkspaceDocView.vue:1269`, `@container (max-width: 760px) { .wsdoc__doc { padding-inline: 2.75rem 8px; } }` imposes a mandatory **44 px** (`2.75rem`) left margin on mobile to clear the menu grip dots (`.wsdoc__dots`).
- **Heading & List Indent:** Outline numbers (`.wsdoc__num`) consume 35–50 px. Nested lists (`<ul>`, `<ol>`) add browser default padding of 40 px per level.
- **Resulting Width Reduction:** At outline level 2 or list depth 2, total left indentation reaches $44\text{px} + 45\text{px} + 40\text{px} = 129\text{px}$. On a 412 px screen, **31.3% of the screen width is wasted empty white space**, compressing the text column to just 283 px.
- **Reading Speed Degradation:** Average words per line drop to **5.1–6.0 words per line** (and down to 4.0 in nested lists). Standard typographical comfort for technical reading requires 9–12 words per line.

### 2.4 Navigation & View Switching Taps

| Interaction | Current Taps on Mobile | Friction Point | Target Taps in Redesign |
|---|:---:|---|:---:|
| **Switch Document (from view)** | **2 taps** | Tap select -> native wheel/dialog opens -> tap item | **1 tap** (Compact dropdown or strip picker) |
| **Switch Document (from tree)** | **2 taps** | Tap `< Documents` (back to drill-down list) -> tap document | **1 tap** (Direct picker popover) |
| **Toggle Outline / Grid** | **1 tap** | Tap Outline/Grid pill button in second header row | **1 tap** (Compact icon toggle in top strip) |
| **Open Table of Contents** | **1 tap** | Tap menu icon in separate sticky bar | **1 tap** (TOC icon in top strip) |
| **Print / Export Document** | **1 tap** | Tap icon in separate sticky bar | **1 tap** (Integrated action in top strip) |

---

## 3. Target Reading Layout Architecture

### 3.1 Mobile Target Layout ($\le 600\text{px}$ CSS)

```
+-------------------------------------------------------------------+
| TOP BAR: [spool]       [ /search ]       [Lang ▾]   [Avatar ▾]    |  <- 50-58px
+-------------------------------------------------------------------+
| [<]  Handbook ▾                   [≣|⊞]  [🖶] [☰] [⬇]  [+]       |  <- ONE STRIPE: 42px
+-------------------------------------------------------------------+
|                                                                   |
| 1. Introduction                                                   |  <- Text padding: 12px
| Why this document exists: one place for how the team works.       |  <- 9-11 words/line
| Day-to-day operations, releases and the on-call rota.             |
|                                                                   |
| 1.1 Deploy                                                        |
| Every deploy is one command, first to dev and then to prd:        |
|                                                                   |
|   ENV=dev ./run -a do_deploy                                      |  <- Code blocks wrap
|   ENV=prd ./run -a do_deploy                                      |
|                                                                   |
| (No floating button covers this text)                             |
| (No composer dock at the bottom)                                  |
|                                                                   |
+-------------------------------------------------------------------+
```

#### Key Architecture Principles for Mobile Reading:

1. **Elimination of `< Documents` Header Row:**  
   Remove the separate `< Documents` title row. The back chevron (`MobileBack`) moves directly into the unified top strip.
2. **The Consolidated Single Top Strip (40–44 px):**  
   Merge all controls into one horizontal bar:
   - **Back Chevron (`<`):** Navigates back up the folder tree or document stack.
   - **Document Picker:** Compact title with downward chevron (`Handbook ▾`), opening an accessible picker modal or popover on tap.
   - **View Toggle (`[≣|⊞]`):** Single compact toggle button switching between Outline (`list` icon) and Grid (`file-spreadsheet` icon).
   - **Action Icons (`[🖶] [☰] [⬇]`):** Print, Table of Contents, and Markdown Export buttons aligned compactly.
   - **New Action (`[+]`):** Compact inline icon button replacing the 56×56 px floating FAB.
3. **Suppression of Bottom Composer Dock:**  
   On `/docs` and `/workspace/docs` routes on mobile viewports ($\le 600\text{px}$), the OmniBox composer dock and footer strip are collapsed or hidden during reading mode, reclaiming **73–95 px** of bottom screen height.
4. **Halved Outline Indentation:**  
   - Reduce `.wsdoc__doc` left padding from `2.75rem` (44 px) to `12px` (`0.75rem`).
   - Move `.wsdoc__dots` grip button to render inline or on-demand on long-press.
   - Reduce nested list indentation from 40 px to 20 px.
   - Text column width expands to **388 px / 412 px (94.2% width share)**, increasing words per line from 5–7 to **9–11 words per line**.
5. **Re-measured Text Height Share:**  
   $\text{Available Text Height} = 915\text{px} - (58\text{px [top bar]} + 42\text{px [strip]}) = 815\text{px}$.  
   $$\text{Text Viewport Share} = \frac{815\text{px}}{915\text{px}} = \mathbf{89.1\%} \quad (\gg 75\% \text{ target})$$  
   Even if the top bar remains fixed: $815 / 915 = 89.1\%$. If scrolled with header: text expands to **95.4%** of the screen.

### 3.2 Desktop Target Layout ($\ge 821\text{px}$ CSS)

Desktop layout integrity is strictly preserved:
- **Left Pane:** File tree explorer (`QtoFileTree.vue`) with resizable `PaneDivider` (260 px default width).
- **Right Pane:** Document content view (`WorkspaceDocView.vue`) or grid view (`WorkspaceGridView.vue`).
- **Header Tools:** The 3 action buttons (print, TOC, export) remain teleported into `#wsdocs-head-tools` in `.feed-header` (SPL-2094).
- **Text Width:** Document body constrained to `max-width: 52rem` (832 px) with `16px clamp(12px, 6%, 64px)` padding, maintaining 10–12 words per line.

---

## 4. Build Rows Table (Rounds Rulebook R1–R16)

In strict adherence to the rounds rulebook (§1.1 max 10 rows, §1.2 1–3 pushes per item, R1 disjoint files per batch, R14 WUI coding assigned strictly to Claude):

### 4.1 Plan Rows Table

| # | Action Slug & Scope | Rationale | Sites (`file:line`, max 5) | Test / Red Control | Target Box | Vendor | Kind | Batch |
|---|---|---|---|---|---|---|---|---|
| **01** | `fix(wui, SPL-2493): consolidate mobile document header into single stripe` | Remove `< Documents` row on $\le 600\text{px}$; merge Back button, compact doc title/picker, and Outline/Grid toggle into one row. Relocate '+' button into header strip, removing fixed floating FAB. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/components/workspace-docs/WorkspaceDocsPage.vue:18-54,368-377` | **Red control:** On master at 412×915, `.feed-header.wsdocs-head` and `.wsdocs-views` render as two separate stacked rows ($H \ge 88\text{px}$); `.wsdocs-fab` has `position: fixed` covering bottom-right text. With fix, single header measures $\le 46\text{px}$, and `.wsdocs-fab` has `position: static` inside strip. | sat | claude | complex_coding | 1 |
| **02** | `fix(wui, SPL-2493): collapse composer dock and status strip on mobile docs routes` | On $\le 600\text{px}$, hide or collapse the OmniBox composer dock and mobile status strip while viewing `/docs` or `/workspace/docs` routes, reclaiming 73–95px of vertical screen real estate. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/components/MessageComposer.vue:1079-1115`<br>`csi-spl-wui/src/layouts/default.vue:61-73,101-103` | **Red control:** On master at 412×915 on `/workspace/docs`, `form.composer.composer--dock` takes $\ge 50\text{px}$ bottom space; with fix, composer dock evaluates to `display: none` or $H=0\text{px}$ on docs routes unless actively searching. | sat | claude | simple_coding | 1 |
| **03** | `feat(wui, SPL-2493): i18n keys for compact mobile reading controls` | Add translation keys for compact document picker, reading mode toggles, and consolidated action buttons across all 19 locales. Claude drafts; agy reviews and approves 18 non-English locales per language rule. | `csi-spl-wui/i18n/locales/*.json:145` | **Red control:** `pnpm run test:unit tests/unit/i18n-parity.test.mjs` fails when keys added to `en.json` only; passes when mirrored across all 19 locales, with `i18n-gates.mjs untranslated` within baseline. | sat | claude | i18n | 1 |
| **04** | `fix(wui, SPL-2493): integrate toolbar into top stripe and halve outline indent` | On $\le 600\text{px}$, integrate `.wsdoc__bar` (print, TOC, export md) into the single top strip; remove sticky toolbar overlay in document body that clips the first text line. Reduce `.wsdoc__doc` left padding from 44px to 12px; tighten `.wsdoc__dots` and list indents. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/components/workspace-docs/WorkspaceDocView.vue:35-58,1018-1065,1079-1140,1267-1284`<br>`csi-spl-wui/src/components/workspace-docs/-doc-headbar.ts:10-21` | **Red control:** On master at 412×915, `.wsdoc__bar` renders as a sticky bar inside `.wsdoc`, overlapping `.wsdoc__h` on scroll; `.wsdoc__doc` left padding is 44px. With fix, `.wsdoc__bar` renders inside top strip, first text element `top \ge strip.bottom`, and left padding is $\le 16\text{px}$. | sat | claude | complex_coding | 2 |
| **05** | `feat(wui, SPL-2493): align repo docs viewer reading layout with consolidated stripe` | Align `/docs/:path*` repo-docs viewer on mobile: consolidate header with Folders toggle into one thin row; eliminate composer dock; ensure table scrolling does not break page width. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/src/pages/docs.vue:28-48,460-478` | **Red control:** On master at 412px on `/docs/DEPLOY.md`, header and Folders button take 111px; tables overflow viewport width by up to 350px. With fix, header is $\le 46\text{px}$ and tables have contained horizontal scroll. | sat | claude | simple_coding | 2 |
| **06** | `test(wui, SPL-2493): browser e2e test for qto mobile reading geometry` | Dedicated Puppeteer e2e test suite validating text height share $\ge 75\%$, 0 element overlaps (toolbar, FAB, composer), indent $\le 16\text{px}$, words per line $\ge 8$, and desktop stability. Enqueue pins claude (`SPAWN_PLACE=claude:<slug>`). | `csi-spl-wui/tests/e2e/qto-reading-geometry.test.mjs:1-140` | **Red control:** Test fails on master due to text height share $\le 66\%$, toolbar-text intersection, and FAB text obstruction; passes with v1.0 layout implementation across phone and desktop viewports. | sat | claude | tests | 3 |

### 4.2 Disjoint Files Batching Verification (R1)

- **Batch 1 (3 parallel lanes):**
  - Row 01: `WorkspaceDocsPage.vue:18-54,368-377`
  - Row 02: `MessageComposer.vue:1079-1115`, `layouts/default.vue:61-73,101-103`
  - Row 03: `i18n/locales/*.json:145`
  *Verification:* Strictly disjoint file sets across all three rows.
- **Batch 2 (2 parallel lanes):**
  - Row 04: `WorkspaceDocView.vue:35-58,1018-1065,1079-1140,1267-1284`, `-doc-headbar.ts:10-21`
  - Row 05: `pages/docs.vue:28-48,460-478`
  *Verification:* Strictly disjoint component files (`WorkspaceDocView.vue` vs `pages/docs.vue`).
- **Batch 3 (1 lane):**
  - Row 06: `tests/e2e/qto-reading-geometry.test.mjs:1-140`
  *Verification:* Dedicated new e2e test suite file.

Every batch strictly satisfies standing round rule **R1 (disjoint files per batch)**.

---

## 5. Performance Budget, Security & Distribution Hygiene

1. **Performance Budget Impact:**  
   - All component modifications reside within lazily evaluated chunks (`pages/workspace/docs.vue`, `WorkspaceDocsLayout.vue`, `pages/docs.vue`).
   - The initial application bundle remains completely unaffected (`ci_initial_gzip_kb` delta: **0.0 KB**, strictly within the 155.0 KB budget).
2. **CSP Compliance:**  
   - Zero inline `style` attributes. All responsive styling resolves through scoped CSS classes and media queries (`@media (max-width: 600px)`).
3. **Distribution Hygiene:**  
   - Commits strictly under canonical repo owner git author identity.
   - Zero AI trailers, no personal names, no private workspace data.
   - Public repository compliance maintained across all files and tests.

---

## 6. Expert Panel Review & Consensus Signatures

In accordance with [rounds-rulebook.md](rounds-rulebook.md) §3.2, owner instructions, and the panel brief:  
*All 3 panel seats review, fold verdicts, and sign the plan sha before implementation lanes are spawned.*

| Seat | Vendor | Agent ID | Status | Verdict & Signature |
|---|---|---|---|---|
| **Editor** | Antigravity (Google) | `a-428@sat` | **Signed** | Plan v0.1 drafted based on empirical measurements on origin/master `a28394183e9ce81091ceca96d01f2f17d2ba6816`, directly incorporating the owner's two concrete requirements and establishing an 89.1% text viewport share target. |
| **Reviewer 1** | Claude (Anthropic) | `c002-qto-reading-panel-seat-claude` | *Awaiting review* | *Seat file: `csi-spl-doc/doc/md/qto-reading-panel/seat-claude.md`* |
| **Reviewer 2** | Mistral | `c002-qto-reading-panel-seat-mistral` | *Awaiting review* | *Seat file: `csi-spl-doc/doc/md/qto-reading-panel/seat-mistral.md`* |
