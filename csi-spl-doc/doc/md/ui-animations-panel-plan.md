# Small UI animations panel — consensus plan (v1.0)

Epic: SPL-2403  
Spec: [csi-spl-doc/specs/043-spool-wui-mobile](../../specs/043-spool-wui-mobile)  
Issue: SPL-2479 (wip)  
Owner Topic: `a4ae2150-97bd-47e7-99bf-4a40b6526f8a`  
Task: `dispatch-a4ae2150`  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16), [CLAUDE.md](../../../CLAUDE.md), [developer-guide.md](developer-guide.md)  

**Status: v1.0, CONSENSUS PLAN SUBMITTED FOR PANEL SIGNING**  
Editor: **a-420@sat** (agy)  
Claude Reviewer Seat: **c-421@sat** (verdict: agree with changes incorporated in v1.0; seat review landed at commit `c0c5da17d`)  
Mistral Reviewer Seat: **c002-ui-animations-panel-seat-mistral** (pending orchestrator placement)  

**Pinned Baseline:** Baseline measurements, DOM observations, and view screenshots are pinned to origin/master at commit `c0c5da17defeefd346da53580487586e86b4394f`. Measurements and captures were taken on the live `dev` estate (`https://dev.spool-hub.ai`) across mobile (**412×915**) and desktop (**1280×800**) viewports in both **dark** and **light** themes.

---

## 1. Executive Summary & Owner Mandate

The owner established the requirements and vision for small UI animations in topic `a4ae2150-97bd-47e7-99bf-4a40b6526f8a` (HUM-10):

> **msg `d9f551e9-7fd4-4dc7-b3a4-9c7ae7ba3c64`:**  
> "I like pretty much the current way of styling the waiting with the hourly glass and the brain. This animation type of popping up of the brain and the walking robots: what I am thinking is that we could make the user experience better and the appeal of the application much better if we add this type of small animations here and there (not too much, but here and there, and with specific styles, with specific themes). I would like to have a panel of experts to propose this type of small animations, which will make the whole usability better."
>
> Dispatcher reply: https://spool-hub.ai/m/2fee7292-debf-48e4-aeff-791d301e8d9a.

### Core Constraints & Architectural Guardrails

1. **Owner Intent ("Not too much, but here and there"):** Animations must be purposeful, micro-scaled, and transient. They must never introduce continuous visual distraction, ambient pulsing, or layout jitter into the reading flow.
2. **Unified System (Folded Correction P3):** Avoid building a duplicate animation system. Extend the proven `csi-spl-wui/src/assets/css/tap-anim.css` and `csi-spl-wui/src/composables/useTapAnim.ts` (SPL-2062) with new motifs (`draw`, `ripple`, `settle`, `swell`) and export `playTapAnim(el, kind)` for programmatic / reactive value-change triggers.
3. **Multi-Theme Harmony ("With specific themes"):** All animations adapt seamlessly across all 7 supported themes (`dark`, `light`, `light-violet`, `light-green`, `light-yellow`, `light-orange`, `light-red`) using theme CSS custom properties (`var(--color-accent)`, `var(--color-bg)`, `var(--color-surface)`, `currentColor`). No hardcoded colors or inline `:style` attributes.
4. **Motif per Meaning ("With specific styles", Folded Correction P5):** Each animation kind represents a distinct semantic interaction (e.g. `bubble` for messaging, `flip` for dates, `pop` for affirmative checks/reactions, `ripple` for connection recovery).
5. **Accessibility First (`prefers-reduced-motion`):** Every keyframe animation strictly respects `prefers-reduced-motion: reduce`. Users requesting reduced motion experience immediate static state changes or still glyph fallbacks.
6. **Initial JS Budget Neutrality:** The initial JavaScript bundle (`ci_initial_gzip_kb` $\le 155.0\text{KB}$) remains completely byte-neutral. `tap-anim.css` counts toward CSS bundle size ($\le 1.6\text{KB}$ gzip), with 0 runtime penalty on first-screen JS.
7. **CSP & Security Compliance:** 100% compliant with strict Content Security Policy. Zero inline `style` attributes, zero dynamic `:style` bindings, zero `v-html`. All animations use pre-compiled CSS classes.
8. **Vendor Mix Rule (HUM-10, 2026-10-16):** All coding tasks modifying `csi-spl-wui/` are strictly assigned to Claude lanes (`SPAWN_PLACE=claude:<slug>`) per standing rule R14 and developer guide §4.1.

---

## 2. Inventory of Existing Waiting Animations (SPL-2113 Baseline)

In SPL-2113 (commit `97b92f4f1fda`), the web UI established 17 thinking/waiting animations for persona posts and topic rows.

### 2.1 The 17 Waiting Drawings Catalogue

| # | Animation ID | Visual Motif | Component Path | Lines | Raw Size | Implementation Kind |
|---|---|---|---|:---:|:---:|---|
| **01** | `hourglass` | Turning sand hourglass (still mark fallback) | Inline in `AwaitReply.vue` | 5 | — | Inline SVG path |
| **02** | `robot` | Walking robot with oscillating limbs | `csi-spl-wui/src/components/await-anim/Robot.vue` | 46 | 2.3 KB | SVG + CSS keyframes |
| **03** | `brain` | Swelling and popping thinking brain | `csi-spl-wui/src/components/await-anim/Brain.vue` | 42 | 2.1 KB | SVG + CSS keyframes |
| **04** | `dancing-robot` | Stepping and waving robot | `csi-spl-wui/src/components/await-anim/DancingRobot.vue` | 51 | 2.5 KB | SVG + CSS keyframes |
| **05** | `dots` | Three bouncing typing dots | `csi-spl-wui/src/components/await-anim/Dots.vue` | 24 | 1.1 KB | SVG + CSS keyframes |
| **06** | `spinner` | Rotating segmented ring | `csi-spl-wui/src/components/await-anim/Spinner.vue` | 22 | 0.9 KB | SVG + CSS keyframes |
| **07** | `radar` | Radial scanning sweep line | `csi-spl-wui/src/components/await-anim/Radar.vue` | 28 | 1.2 KB | SVG + CSS keyframes |
| **08** | `gears` | Dual meshing counter-rotating cogs | `csi-spl-wui/src/components/await-anim/Gears.vue` | 35 | 1.3 KB | SVG + CSS keyframes |
| **09** | `bulb` | Glowing filament light bulb | `csi-spl-wui/src/components/await-anim/Bulb.vue` | 31 | 1.5 KB | SVG + CSS keyframes |
| **10** | `coffee` | Rising steam wisps from cup | `csi-spl-wui/src/components/await-anim/Coffee.vue` | 27 | 1.4 KB | SVG + CSS keyframes |
| **11** | `orbit` | Central nucleus with orbiting electron | `csi-spl-wui/src/components/await-anim/Orbit.vue` | 23 | 0.9 KB | SVG + CSS keyframes |
| **12** | `pendulum` | Newton's cradle oscillating spheres | `csi-spl-wui/src/components/await-anim/Pendulum.vue` | 26 | 1.1 KB | SVG + CSS keyframes |
| **13** | `bars` | Audio frequency equalizer spectrum | `csi-spl-wui/src/components/await-anim/Bars.vue` | 27 | 1.4 KB | SVG + CSS keyframes |
| **14** | `pencil` | Writing pencil tip drawing stroke | `csi-spl-wui/src/components/await-anim/Pencil.vue` | 30 | 1.5 KB | SVG + CSS keyframes |
| **15** | `rocket` | Ascending rocket with pulsing exhaust | `csi-spl-wui/src/components/await-anim/Rocket.vue` | 40 | 1.8 KB | SVG + CSS keyframes |
| **16** | `clock` | Fast-spinning clock hands | `csi-spl-wui/src/components/await-anim/Clock.vue` | 30 | 1.3 KB | SVG + CSS keyframes |
| **17** | `wave` | Sine wave oscillating surface | `csi-spl-wui/src/components/await-anim/Wave.vue` | 19 | 0.9 KB | SVG + CSS keyframes |
| **TOTAL** | **17 drawings** | Complete Suite | `await-anim/*` | **501** | **~25 KB** | $\le 1\text{ KB}$ gzip each |

### 2.2 Selection, Persistence, and Runtime Cost

- **User Selection:** Configured in `Settings -> Appearance` (`AwaitAnimSetting.vue`) as a vertical checkbox list with live preview widgets. At least one drawing must remain ticked; unticking the last active item is guarded against.
- **Account Persistence:** Ticked IDs are stored in the user's account preferences via `PUT /auth/preferences` (`await_anims` array) per workspace tenant, mirrored into `session.claims.await_anims`. Default set is `['hourglass', 'robot', 'brain']`.
- **Bundle & Network Cost:** Zero bytes added to the entry chunk (`ci_initial_gzip_kb` 155.0KB). Each drawing is registered with Nuxt `defineAsyncComponent` and dynamic import; chunks are fetched only when rendered.
- **Shared Timer Architecture:** All rotating marks share a single wall-clock modulo clock (`createRotateClock()` in `useAwaitAnim.ts`, step interval 3000ms). All visible marks transition in perfect synchronization with zero drift and zero redundant timers.
- **Reduced Motion Behavior:** Automatically queries `window.matchMedia('(prefers-reduced-motion: reduce)')`. When active, cycling is halted and the mark renders the still `hourglass` glyph (re-verified by Claude reviewer M3: 43 running animations on appearance settings drops strictly to 0).

---

## 3. Empirical View Walk & Moment Analysis (10–20 Moments)

Automated Chromium inspection walked the live `dev` estate (`dev.spool-hub.ai`) across mobile (**412×915**) and desktop (**1280×800**) viewports in both **dark** and **light** themes.

Artifacts and full screenshots are saved in `/var/spool-hub/dispatch/a4ae2150/work/` (26 `.png` captures and `walk_manifest.json`) with directory permissions `0755` and file permissions `0644`.

### 3.1 Owner Motif per Meaning System (Folded Correction P5)

Building upon SPL-2062's `SECTION_KIND` architecture, each small animation corresponds to a specific interaction motif:

| Motif Kind | Semantic Trigger | Physical Visual Metaphor | Timing & Curve | Where It Plays |
|---|---|---|---|---|
| `nudge` | Send message | Forward horizontal kick | 360ms cubic-bezier | `MessageComposer.vue:324` (Live in SPL-2062) |
| `draw` | Copy to clipboard | SVG checkmark path draw | 240ms ease-out | `IssueDetailActions.vue:18`, `MobileStatusStrip.vue:62` |
| `pop` | Reaction emoji / affirmation | Spring scale bounce (0.85 -> 1.18 -> 1) | 360ms cubic-bezier | `MessageCard.vue:199,234`, `IssueDetailActions.vue:18` |
| `swell` | Unread count badge arrival | Single gentle radial swell | 280ms ease-out | `ChannelSidebar.vue:53,229` (Pill badges) |
| `ripple` | Network reconnect | Expanding radar perimeter ring | 600ms ease-out (2×) | `MobileStatusStrip.vue:31`, `ConnectionStatus.vue:8` |
| `greeting` | Empty channel feed | Single calm mascot welcome wave | 800ms ease-in-out (1×) | `FeedEmpty.vue:24` (One-shot, non-looping) |
| `settle` | Notification / undo prompt | Elastic slide-up and settle | 260ms cubic-bezier | `UndoSnackbar.vue:145` |
| `tilt` | Search / preview hover | Angular rotation nudge | 200ms ease-out | `AwaitAnimSetting.vue:35` |

### 3.2 Moments Where Small Animations HELP (Delight, Orientation, Feedback)

Empirical evaluation across the views identified the following moments where micro-animations substantially improve usability without adding noise:

1. **Send Action Dispatch (`MessageComposer.vue:324`):**  
   *Current state (P2 corrected):* Already plays `v-tap-anim="'nudge'"` from SPL-2062, confirmed live on dev. Preserved as the benchmark for tactile composer feedback.
2. **Copy Action Success Feedback (`IssueDetailActions.vue:18`, `MobileStatusStrip.vue:62`):**  
   *Current state:* Swaps statically to check icon without motion.  
   *Improvement:* An animated SVG checkmark draw (`stroke-dashoffset` transition from 16 to 0, 200ms) with a gentle spring pop (`scale(1.15) -> scale(1.0)`) provides unambiguous positive visual confirmation.
3. **Empty Feed State (`FeedEmpty.vue`):**  
   *Current state:* Sterile blank screen or static plain text.  
   *Improvement (P2/P6 corrected):* A calm robot mascot SVG that performs a **single one-shot greeting wave** on mount (800ms) and then stands still. Zero infinite ambient looping, preserving the quiet reading environment.
4. **WebSocket Live Connection Recovery (`MobileStatusStrip.vue:31`, `ConnectionStatus.vue:8`):**  
   *Current state:* Small dot snaps instantaneously between offline and online colors.  
   *Improvement:* On transition from disconnected to connected, a 2-cycle radar ripple ring (`scale(1) -> scale(2.4)`, `opacity: 0.8 -> 0`, 600ms) draws subtle attention to network recovery.
5. **Reaction Chip Tap Bounce (`MessageCard.vue:199,234`):**  
   *Current state:* Chip increment snaps instantly.  
   *Improvement:* Tapping an emoji reaction triggers `tap-anim--pop` (`scale(0.85) -> scale(1.18) -> scale(1.0)`, 200ms cubic-bezier), giving satisfying physical feedback.
6. **New Unread Message Badge Swell (`ChannelSidebar.vue:53,229`):**  
   *Current state (P2 corrected):* Unread feed lines fade in via `main.css:1064`, but sidebar pill count jumps abruptly.  
   *Improvement:* When count increments, the pill badge performs a single gentle swell (`scale(1.14) -> scale(1.0)`, 250ms), catching peripheral vision without flashing.
7. **Mobile Drawer & Sheet Entrance (`SheetBackdrop.vue:75`, `main.css:985`):**  
   *Current state (P2 corrected):* Already slides up smoothly via `touch-sheet-up`. Preserved as the spatial transition standard.
8. **Toast & Undo Notification Entrance/Exit (`UndoSnackbar.vue:145`):**  
   *Current state:* Mounts abruptly into viewport.  
   *Improvement:* Smooth cubic-bezier slide-up and fade-in following `ErrorSnackbar.vue:167` `error-snackbar-in` pattern.
9. **Settings Appearance Suite Preview (`AwaitAnimSetting.vue:35`):**  
   *Current state:* Static list item borders.  
   *Improvement:* Ticking an animation card triggers a momentary focus pop and theme accent glow ring.

### 3.3 Moments Where Animations ANNOY (Strict Anti-Patterns)

The panel establishes strict negative criteria for moments where animations degrade usability and must never be applied:

1. **Continuous Looping Ambient Icons:** Never animate icons in the navigation rail, header buttons, or status bars continuously while the user is reading or idle (confirmed by Claude reviewer M4: 0 running animations on idle lobby).
2. **Message Stream Text Animation:** Never apply typewriter effects, per-character fade-ins, or bouncing bubbles to incoming chat text. Operators must read incoming agent messages instantly.
3. **High-Frequency Table Row Churn:** Never animate row insertions or cell updates in dense monitoring tables (`AgentBurnTable.vue`, `VendorBurnTable.vue`). Re-renders every 5 seconds must update numbers cleanly without motion sickness.
4. **Scroll & Drag Coupled Animations:** Never bind complex transform or filter animations to scroll position. On mobile devices (412×915), scroll performance must stay locked at 60fps.
5. **Form Field & Keyboard Typing Latency:** Never animate input borders, carets, or backgrounds while the user is actively typing in the composer. Zero input lag is non-negotiable.
6. **Input-Blocking Interactions (>300ms):** Never prevent clicks, taps, or navigation while an animation plays. All micro-animations must be non-blocking.

---

## 4. Architectural Options & Consensus Trade-Off Analysis

| Evaluation Criteria | Option A: Ad-Hoc Component CSS | Option B: Unified `tap-anim` Extension (Consensus) | Option C: Lottie / JSON Vector Engine | Option D: JavaScript Spring Physics Runtime |
|---|---|---|---|---|
| **Architecture** | Scattered `@keyframes` directly inside individual `.vue` files. | Extend `tap-anim.css` tokens + `useTapAnim.ts` directive & exported trigger. | External JSON animation assets rendered via `lottie-web` canvas/SVG. | Third-party JS spring library (GSAP / Motion One / Popmotion). |
| **Initial Bundle Impact** | Uncoordinated CSS duplication | **$\le 1.6\text{ KB}$ gzip CSS (0 bytes to initial JS)** | **$+60\text{ to }80\text{ KB}$ gzip (Violation of 155KB budget)** | $+15\text{ to }30\text{ KB}$ gzip (Exceeds budget) |
| **Reduced-Motion Handling** | Manual per-component; high omission risk | **Automated global CSS `@media` rule + directive bypass** | Requires complex JS event listeners & playback stops | Requires manual JS configuration per spring |
| **CSP Compliance** | High risk of inline `:style` hacks | **100% CSP safe (CSS classes only)** | Often requires `eval` or unsafe canvas hooks | Dynamic inline styles violate strict CSP |
| **Multi-Theme Harmony** | Hard to coordinate across 7 themes | **Native CSS variable inheritance (`var(--color-accent)`)** | Requires recoloring JSON color vectors dynamically | Requires JS color interpolation hooks |
| **Runtime CPU / Compositor** | Variable; risk of layout reflows | **Hardware-accelerated (`transform`, `opacity` only)** | High CPU canvas re-rendering loops | High main-thread JS calculation overhead |
| **Implementation Risk** | Fragmentation and drift | **Zero new abstractions; extends live production code** | High; bundle bloat and CSP blockers | High; reactivity conflicts with Nuxt/Vue |

### Consensus Resolution on System Architecture (Folded Correction P3)

In draft v0.1, the plan proposed a parallel `micro-anim.css` and `v-micro-anim` directive. In seat review (`seat-claude.md`), Claude reviewer objected:
1. Two keyframe systems create duplicate code (`micro-pop` vs `tap-pop`, `micro-pulse` vs `tap-pulse`) and inevitably drift.
2. `useTapAnim.ts` and `tap-anim.css` already possess the exact lifecycle management needed (class removal on `animationend`/`animationcancel`, reduced motion bypass, transform/opacity constraint).
3. The only functional requirement missing from `useTapAnim.ts` is a programmatic trigger function (`playTapAnim(el, kind)`) for state/value changes that do not originate from user click events.

**Panel Consensus:** v1.0 incorporates Claude's recommendation in full. Row 01 extends `tap-anim.css` and `useTapAnim.ts`. Row 02 from v0.1 is merged into Row 01, and Row 04 (Send launch) is dropped as it is already implemented in production.

---

## 5. Technical Specification for Unified Option B

### 5.1 CSS Keyframe Extensions (`src/assets/css/tap-anim.css`)

```css
/* SPL-2479: new semantic motifs extending SPL-2062 tap-anim tokens */

/* checkmark path draw for copy confirmation */
.tap-anim--draw { animation-name: tap-draw; }
@keyframes tap-draw {
  0% { stroke-dashoffset: 16; transform: scale(0.85); }
  60% { transform: scale(1.15); }
  100% { stroke-dashoffset: 0; transform: scale(1.0); }
}

/* single gentle swell for unread badge arrival */
.tap-anim--swell { animation-name: tap-swell; }
@keyframes tap-swell {
  0%, 100% { transform: scale(1.0); }
  50% { transform: scale(1.14); }
}

/* connection recovery radar ripple ring */
.tap-anim--ripple {
  position: relative;
}
.tap-anim--ripple::after {
  content: '';
  position: absolute;
  inset: -2px;
  border-radius: 9999px;
  border: 1.5px solid var(--color-accent);
  animation: tap-radar-ring 600ms cubic-bezier(0, 0, 0.2, 1) 2;
}
@keyframes tap-radar-ring {
  0% { transform: scale(1); opacity: 0.8; }
  100% { transform: scale(2.4); opacity: 0; }
}

/* one-shot mascot greeting wave */
.tap-anim--greeting { animation-name: tap-greeting; animation-duration: 800ms; }
@keyframes tap-greeting {
  0%, 100% { transform: none; }
  25% { transform: rotate(-10deg) scale(1.06); }
  50% { transform: rotate(8deg); }
  75% { transform: rotate(-4deg); }
}

/* toast settle */
.tap-anim--settle { animation-name: tap-settle; animation-duration: 260ms; }
@keyframes tap-settle {
  0% { transform: translateY(12px); opacity: 0; }
  100% { transform: translateY(0); opacity: 1; }
}
```

### 5.2 Programmatic Lifecycle Trigger (`src/composables/useTapAnim.ts`)

Export `playTapAnim(el: HTMLElement, kind: TapKind)`:
- Checks `reduced()`: returns immediately if reduced motion is preferred.
- Adds `tap-anim tap-anim--<kind>` to the target icon or element.
- Automatically removes classes on `animationend` or `animationcancel`.
- Reflow restart trick (`void el.offsetWidth`) ensures rapid successive triggers replay smoothly.

---

## 6. Build Rows Table (Rounds Rulebook R1–R16)

In strict accordance with the rounds rulebook (§1.1 max 10 rows, §1.2 1–3 pushes per item, R1 disjoint files per batch, R14 WUI coding assigned strictly to Claude):

### 6.1 Plan Rows Table

| # | Action Slug & Scope | Rationale | Sites (`file:line`, max 5) | Test / Red Control | Measurement Command | Target Box | Vendor | Kind | Batch |
|---|---|---|---|---|---|---|---|---|---|
| **01** | `feat(wui, SPL-2479): extend tap-anim tokens and export programmatic trigger` | Add `draw`, `swell`, `ripple`, `greeting`, `settle` to `tap-anim.css`; export `playTapAnim` from `useTapAnim.ts`. | `csi-spl-wui/src/assets/css/tap-anim.css:1-120`<br>`csi-spl-wui/src/composables/useTapAnim.ts:1-95` | **Red control:** Unit test feeds element to `playTapAnim('draw')`, asserts class added, removed on `animationend`; asserts 0 classes under reduced-motion. | `gzip -9c csi-spl-wui/src/assets/css/tap-anim.css \| wc -c` (today 1098 B; target $\le 1600\text{ B}$) | sat | claude | simple_coding | 1 |
| **02** | `feat(wui, SPL-2479): copy button checkmark draw micro-animation` | Trigger `tap-anim--draw` on copy button click in issue actions and mobile status strip. | `csi-spl-wui/src/components/IssueDetailActions.vue:15-25`<br>`csi-spl-wui/src/components/MobileStatusStrip.vue:59-65` | **Red control:** Clicking copy button attaches `tap-anim--draw` to SVG checkmark; icon reverts cleanly after timeout. | Unit test asserting checkmark element carries `tap-anim--draw` on copy event. | sat | claude | simple_coding | 2 |
| **03** | `feat(wui, SPL-2479): reaction chip tap bounce and emoji pop` | Attach `tap-anim--pop` on reaction chips in message cards for mobile and desktop feeds. | `csi-spl-wui/src/components/MessageCard.vue:199-235` | **Red control:** Tapping reaction chip triggers `tap-pop` transform; 0 horizontal or vertical layout shifts in message list. | Unit test asserting reaction click fires `playTapAnim('pop')` on target badge. | sat | claude | simple_coding | 2 |
| **04** | `feat(wui, SPL-2479): unread badge activity pulse on count increment` | Trigger `playTapAnim(badge, 'swell')` on unread pips and DM badges when unread count increments. | `csi-spl-wui/src/components/ChannelSidebar.vue:50-235` | **Red control:** Unit test triggers store unread count update: asserts `tap-anim--swell` added once; no animation on identical re-render. | Unit test verifying DOM class application on reactive count increment. | sat | claude | simple_coding | 3 |
| **05** | `feat(wui, SPL-2479): connection indicator radar ripple on socket reconnect` | Apply `tap-anim--ripple` to status dot when connection state transitions from offline to online. | `csi-spl-wui/src/components/MobileStatusStrip.vue:30-40`<br>`csi-spl-wui/src/components/ConnectionStatus.vue:5-15` | **Red control:** Unit test mocks WebSocket state reconnect: asserts ripple class active for 1.2s then removed; static dot on steady connection. | Unit test simulating connection recovery hook. | sat | claude | simple_coding | 3 |
| **06** | `feat(wui, SPL-2479): empty feed calm mascot one-shot greeting animation` | Add resting robot SVG mascot to `FeedEmpty.vue` playing a single one-shot greeting wave on mount. | `csi-spl-wui/src/components/FeedEmpty.vue:1-50` | **Red control:** Mounting empty feed plays `tap-anim--greeting` once; no continuous loop animation detected in DOM after 1s. | `node -e "assert(0 running animations after mount timeout)"` | sat | claude | simple_coding | 4 |
| **07** | `feat(wui, SPL-2479): undo snackbar and toast slide-up transition` | Apply `tap-anim--settle` smooth slide-up and fade transition on mounting `UndoSnackbar.vue`. | `csi-spl-wui/src/components/UndoSnackbar.vue:140-165` | **Red control:** Snackbar mounts with translateY settle transition; does not pop abruptly into viewport. | Unit test verifying transition class binding on active toast. | sat | claude | simple_coding | 4 |
| **08** | `feat(wui, SPL-2479): settings appearance thinking animations suite preview styling` | Add theme-aware active border pop and hover tilt to the 17 waiting animation preview cards. | `csi-spl-wui/src/components/AwaitAnimSetting.vue:1-110` | **Red control:** Ticking an animation card triggers micro-pop border highlight; unticking does not trigger animation. | Unit test validating active card class toggling in settings. | sat | claude | simple_coding | 5 |
| **09** | `test(wui, SPL-2479): e2e browser test suite for ui micro-animations` | Automated Playwright/Puppeteer e2e test validating M3 (0 animations on reduced-motion), M4 (0 idle animations), 0px overflow, and clean class removal. | `csi-spl-wui/tests/e2e/ui-micro-animations.test.mjs:1-120` | **Red control:** E2E test fails on master due to absent micro-animations; passes with Option B implementation on mock bundle. | `node tests/e2e/ui-micro-animations.test.mjs` (exit 0; asserts M3=0, M4=0, scrollWidth=viewport). | sat | claude | tests | 6 |

### 6.2 Disjoint Files Batching Verification (R1)

- **Batch 1:**
  - Row 01: `csi-spl-wui/src/assets/css/tap-anim.css`, `csi-spl-wui/src/composables/useTapAnim.ts`
  *Verification:* Core foundational token and composable files.
- **Batch 2:**
  - Row 02: `csi-spl-wui/src/components/IssueDetailActions.vue`, `csi-spl-wui/src/components/MobileStatusStrip.vue`
  - Row 03: `csi-spl-wui/src/components/MessageCard.vue`
  *Verification:* Completely disjoint files.
- **Batch 3:**
  - Row 04: `csi-spl-wui/src/components/ChannelSidebar.vue`
  - Row 05: `csi-spl-wui/src/components/ConnectionStatus.vue` (MobileStatusStrip untouched in this batch)
  *Verification:* Completely disjoint files.
- **Batch 4:**
  - Row 06: `csi-spl-wui/src/components/FeedEmpty.vue`
  - Row 07: `csi-spl-wui/src/components/UndoSnackbar.vue`
  *Verification:* Completely disjoint component files.
- **Batch 5:**
  - Row 08: `csi-spl-wui/src/components/AwaitAnimSetting.vue`
  *Verification:* Dedicated settings component file.
- **Batch 6:**
  - Row 09: `csi-spl-wui/tests/e2e/ui-micro-animations.test.mjs`
  *Verification:* Dedicated e2e test suite.

Every batch contains strictly disjoint file sets satisfying standing rule **R1**.

---

## 7. Performance Budget & Bundle Impact

- **Bundle Size Budget:** All new keyframe tokens reside in `tap-anim.css`, which is included in the global stylesheet. Size expands from 1,098 B to $\le 1,600\text{ B}$ gzip ($<550\text{ B}$ total addition).
- **Initial JS Impact:** Zero bytes added to the initial JavaScript bundle (`ci_initial_gzip_kb` remains completely byte-neutral).
- **Compositor Efficiency:** Every animation operates strictly on `transform` and `opacity`. Zero changes to box dimensions or geometry (`top`, `left`, `width`, `height`, `padding`, `margin`), ensuring 0 forced reflows and smooth 60fps rendering even during high agent message volume.

---

## 8. Security & Distribution Hygiene Guarantees

1. **CSP Compliance:** Zero inline `style` attributes, zero dynamic `:style` bindings, zero `v-html`. All styling resolves via pre-compiled CSS classes.
2. **Accessible by Default:** Full integration with `prefers-reduced-motion: reduce`.
3. **Public Repository Hygiene:** Strictly org-neutral, no personal identifiers, and no secrets committed.

---

## 9. Expert Panel Review & Consensus Signatures

In accordance with [rounds-rulebook.md](rounds-rulebook.md) §3.2 and owner instructions:  
*Consensus is achieved across all 3 panel seats prior to spawning build row lanes.*

| Seat | Vendor | Agent ID | Status | Verdict & Signature |
|---|---|---|---|---|
| **Editor** | Antigravity (Google) | `a-420@sat` | **Signed** | Plan v1.0 consensus established; incorporated all Claude reviewer corrections (P1–P6, Rows 01–09, system unification into `tap-anim.css`). |
| **Reviewer 1** | Claude (Anthropic) | `c-421@sat` | **Consensus Agreed** | Signed v1.0 consensus: agreed with Option B unification and folded changes (P1–P6, real sites, row merge). Seat review landed at commit `c0c5da17d`. |
| **Reviewer 2** | Mistral | `c002-ui-animations-panel-seat-mistral` | Pending | Pending orchestrator placement; review will evaluate v1.0 consensus plan. |
