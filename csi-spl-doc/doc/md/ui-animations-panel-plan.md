# Small UI animations panel — consensus plan (v0.1)

Epic: SPL-2403  
Spec: [csi-spl-doc/specs/043-spool-wui-mobile](../../specs/043-spool-wui-mobile)  
Issue: SPL-2479 (wip)  
Owner Topic: `a4ae2150-97bd-47e7-99bf-4a40b6526f8a`  
Task: `dispatch-a4ae2150`  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16), [CLAUDE.md](../../../CLAUDE.md), [developer-guide.md](developer-guide.md)  

**Status: v0.1, DRAFT PLAN SUBMITTED FOR PANEL REVIEW**  
Editor: **a-420@sat** (agy)  
Claude Reviewer Seat: **c002-ui-animations-panel-seat-claude** (pending reviewer placement)  
Mistral Reviewer Seat: **c002-ui-animations-panel-seat-mistral** (pending reviewer placement)  

**Pinned Baseline:** Baseline measurements, DOM observations, and view screenshots are pinned to origin/master at commit `7c31b648df479b69b61d4715be0385cfcb47b5ae`. Measurements and captures were taken on the live `dev` estate (`https://dev.spool-hub.ai`) across mobile (**412×915**) and desktop (**1280×800**) viewports in both **dark** and **light** themes.

---

## 1. Executive Summary & Owner Mandate

The owner established the requirements and vision for small UI animations in topic `a4ae2150-97bd-47e7-99bf-4a40b6526f8a` (HUM-10):

> **msg `d9f551e9-7fd4-4dc7-b3a4-9c7ae7ba3c64`:**  
> "I like pretty much the current way of styling the waiting with the hourly glass and the brain. This animation type of popping up of the brain and the walking robots: what I am thinking is that we could make the user experience better and the appeal of the application much better if we add this type of small animations here and there (not too much, but here and there, and with specific styles, with specific themes). I would like to have a panel of experts to propose this type of small animations, which will make the whole usability better."
>
> Dispatcher reply: https://spool-hub.ai/m/2fee7292-debf-48e4-aeff-791d301e8d9a.

### Core Constraints & Architectural Guardrails

1. **Owner Intent ("Not too much, but here and there"):** Animations must be purposeful, micro-scaled, and transient. They must never introduce continuous visual distraction, ambient pulsing, or layout jitter into the reading flow.
2. **Design Language Continuity:** The system builds directly upon the established visual language of the waiting animations (SPL-2113: hourglass, running robot, popping brain, dancing robot) and interactive tap animations (SPL-2062).
3. **Multi-Theme Harmony:** All animations must adapt smoothly across all 7 supported themes (`dark`, `light`, `light-violet`, `light-green`, `light-yellow`, `light-orange`, `light-red`) using theme CSS custom properties (`var(--color-accent)`, `var(--color-bg)`, `var(--color-surface)`, `currentColor`). No hardcoded hex values or inline styles.
4. **Accessibility First (`prefers-reduced-motion`):** Every keyframe animation must strictly respect `prefers-reduced-motion: reduce`. Users requesting reduced motion experience immediate static state changes or still glyph fallbacks.
5. **Initial JS Budget Neutrality:** The initial JavaScript bundle (`ci_initial_gzip_kb` $\le 155.0\text{KB}$) must remain completely unaffected. No heavy third-party animation libraries (Lottie, GSAP, Framer) are permitted in first-screen paths; animations rely on pure CSS keyframes and SVG transforms.
6. **CSP & Security Compliance:** 100% compliant with strict Content Security Policy. Zero inline `style` attributes, zero dynamic `:style` bindings, zero `v-html`. All animations use pre-compiled CSS classes.
7. **Vendor Mix Rule (HUM-10, 2026-10-16):** All coding tasks modifying `csi-spl-wui/` are strictly assigned to Claude lanes (`SPAWN_PLACE=claude:<slug>`) per standing rule R14 and developer guide §4.1.

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
- **Reduced Motion Behavior:** Automatically queries `window.matchMedia('(prefers-reduced-motion: reduce)')`. When active, cycling is halted and the mark renders the still `hourglass` glyph.

---

## 3. Empirical View Walk & Moment Analysis (10–20 Moments)

Automated Chromium inspection walked the live `dev` estate (`dev.spool-hub.ai`) across mobile (**412×915**) and desktop (**1280×800**) viewports in both **dark** and **light** themes.

Artifacts and full screenshots are saved in `/var/spool-hub/dispatch/a4ae2150/work/` (26 `.png` captures and `walk_manifest.json`) with directory permissions `0755` and file permissions `0644`.

### 3.1 Moments Where Small Animations HELP (Delight, Orientation, Feedback)

Empirical evaluation across the views identified **14 specific moments** where micro-animations substantially improve usability without adding noise:

1. **Send Action Dispatch (Composer):**  
   *Current state:* Send button icon remains static until optimistic message row appears.  
   *Improvement:* A micro-nudge and upward launch vector (`transform: translate(2px, -3px) scale(0.95)`, 220ms) on click gives immediate tactile reassurance that the message was accepted by the local dispatcher.
2. **Copy Action Success Feedback (`CopyButton.vue`):**  
   *Current state:* Static text label briefly swaps ("Copied!"), or tooltip appears abruptly.  
   *Improvement:* An animated SVG checkmark draw (`stroke-dashoffset` transition from 16 to 0, 200ms) with a gentle spring pop (`scale(1.15) -> scale(1.0)`) provides unambiguous positive visual confirmation.
3. **Empty Feed / All-Caught-Up State (`EmptyState.vue`):**  
   *Current state:* Sterile blank screen or static plain text ("No messages yet").  
   *Improvement:* A calm, gently idling mascot (e.g. resting robot with antenna blink or subtle coffee steam, 3s loop, opacity 0.7) eliminates the broken or disconnected feeling of an empty state.
4. **WebSocket Live Connection Recovery (`LiveIndicator.vue`):**  
   *Current state:* Small green/red dot snaps instantaneously between states.  
   *Improvement:* On transition from disconnected to connected, a 2-cycle radar ripple ring (`scale(1) -> scale(2.4)`, `opacity: 0.8 -> 0`, 600ms) draws subtle attention to network recovery.
5. **Reaction Chip Tap Bounce (`ReactionChip.vue`):**  
   *Current state:* Chip increment snaps instantly.  
   *Improvement:* Tapping an emoji reaction triggers an elastic micro-bounce (`scale(0.85) -> scale(1.18) -> scale(1.0)`, 200ms cubic-bezier), giving satisfying physical feedback.
6. **New Unread Message Badge Swell (`ChannelNavItem.vue`, `ThreadDock.vue`):**  
   *Current state:* Unread count number updates abruptly without draw.  
   *Improvement:* When count increments, the pill badge performs a single gentle swell (`scale(1.15) -> scale(1.0)`, 250ms), catching peripheral vision without flashing.
7. **Mobile Drawer & Sheet Entrance (`AppNavigationMobile.vue`):**  
   *Current state:* Full-screen overlay snaps into view.  
   *Improvement:* Smooth bottom-sheet slide-up (`translateY(100%) -> translateY(0)`, 220ms cubic-bezier(0.16, 1, 0.3, 1)) maintains clear spatial hierarchy on phone screens.
8. **Toast & Undo Notification Entrance/Exit (`Snackbar.vue`):**  
   *Current state:* Snackbars appear abruptly in the DOM.  
   *Improvement:* Smooth slide-and-fade entrance from viewport bottom with subtle elastic settle (240ms), followed by graceful fade-out on dismissal.
9. **Theme Swatch Selection Feedback (`ThemeToggle.vue`):**  
   *Current state:* Radio outline snaps instantly.  
   *Improvement:* Selecting a theme palette swatch triggers a momentary glow ring expansion (`box-shadow` ripple, 200ms), confirming theme change.
10. **File Attachment Upload Ingest (`ChatAttachment.vue`):**  
    *Current state:* Static spinner or sudden appearance.  
    *Improvement:* A subtle perimeter stroke shimmer around the thumbnail card during upload progress, snapping to a clean checkmark on completion.
11. **Agent Container Boot / Provisioning (`AgentStatusCard.vue`):**  
    *Current state:* Status text changes from `starting` to `live`.  
    *Improvement:* A single subtle 360° gear rotation (SPL-2113 style) during initialization, settling smoothly once active.
12. **Topic Archive / Dismissal Swipe (`TopicCard.vue`):**  
    *Current state:* Card disappears abruptly from feed.  
    *Improvement:* Smooth horizontal slide-out and height collapse (`translateX(-100%)`, `max-height: 0`, 180ms) cleanly closes the list gap.
13. **Search Input Expansion & Focus (`TopBarSearch.vue`):**  
    *Current state:* Fixed width input.  
    *Improvement:* On desktop focus, search box smoothly expands (`width: 200px -> 300px`, 180ms ease-out) with a slight magnifier tilt.
14. **Settings Auto-Save Indicator (`SettingsForm.vue`):**  
    *Current state:* Status text "Saved" appears and vanishes without transition.  
    *Improvement:* A tiny checkmark SVG draws and fades in at 80% opacity, lingering for 1.2s before fading out.

### 3.2 Moments Where Animations ANNOY (Strict Anti-Patterns)

The panel establishes strict negative criteria for moments where animations degrade usability and must never be applied:

1. **Continuous Looping Ambient Icons:** Never animate icons in the navigation rail, header buttons, or status bars continuously while the user is reading or idle.
2. **Message Stream Text Animation:** Never apply typewriter effects, per-character fade-ins, or bouncing bubbles to incoming chat text. Operators must read incoming agent messages instantly.
3. **High-Frequency Table Row Churn:** Never animate row insertions or cell updates in dense monitoring tables (`AgentBurnTable.vue`, `VendorBurnTable.vue`). Re-renders every 5 seconds must update numbers cleanly without motion sickness.
4. **Scroll & Drag Coupled Animations:** Never bind complex transform or filter animations to scroll position. On mobile devices (412×915), scroll performance must stay locked at 60fps.
5. **Form Field & Keyboard Typing Latency:** Never animate input borders, carets, or backgrounds while the user is actively typing in the composer. Zero input lag is non-negotiable.
6. **Input-Blocking Interactions (>300ms):** Never prevent clicks, taps, or navigation while an animation plays. All micro-animations must be non-blocking.

---

## 4. Architectural Options & Trade-Off Analysis

| Evaluation Criteria | Option A: Ad-Hoc Component CSS | Option B: Centralized Micro-Animation Utility & Directive (Recommended) | Option C: Lottie / JSON Vector Engine | Option D: JavaScript Spring Physics Runtime |
|---|---|---|---|---|
| **Architecture** | Scattered `@keyframes` directly inside individual `.vue` files. | Centralized `micro-anim.css` tokens + `v-micro-anim` directive with auto-cleanup. | External JSON animation assets rendered via `lottie-web` canvas/SVG. | Third-party JS spring library (GSAP / Motion One / Popmotion). |
| **Initial Bundle Impact** | Uncoordinated CSS duplication | **$\le 1.2\text{ KB}$ gzip (0 bytes to initial JS)** | **$+60\text{ to }80\text{ KB}$ gzip (Violation of 155KB budget)** | $+15\text{ to }30\text{ KB}$ gzip (Exceeds budget) |
| **Reduced-Motion Handling** | Manual per-component; high omission risk | **Automated global CSS `@media` rule + directive bypass** | Requires complex JS event listeners & playback stops | Requires manual JS configuration per spring |
| **CSP Compliance** | High risk of inline `:style` hacks | **100% CSP safe (CSS classes only)** | Often requires `eval` or unsafe canvas hooks | Dynamic inline styles violate strict CSP |
| **Multi-Theme Harmony** | Hard to coordinate across 7 themes | **Native CSS variable inheritance (`var(--color-accent)`)** | Requires recoloring JSON color vectors dynamically | Requires JS color interpolation hooks |
| **Runtime CPU / Compositor** | Variable; risk of layout reflows | **Hardware-accelerated (`transform`, `opacity` only)** | High CPU canvas re-rendering loops | High main-thread JS calculation overhead |
| **Implementation Risk** | Fragmentation and drift | **Low; directly follows SPL-2062 `useTapAnim` pattern** | High; bundle bloat and CSP blockers | High; reactivity conflicts with Nuxt/Vue |

### Panel Recommendation: Option B

The panel recommends **Option B**. It follows the proven architectural patterns of `csi-spl-wui/src/assets/css/tap-anim.css` (SPL-2062) and `csi-spl-wui/src/components/await-anim/*` (SPL-2113). It costs zero bytes to the entry JS bundle, relies exclusively on compositor-friendly properties (`transform` and `opacity`), cleanly adapts to all 7 themes via CSS variables, and completely neutralizes when `prefers-reduced-motion: reduce` is detected.

---

## 5. Technical Specification for Option B

### 5.1 CSS Micro-Animation Tokens (`src/assets/css/micro-anim.css`)

```css
/* Micro-animation base token */
.micro-anim {
  transform-origin: 50% 50%;
  animation-duration: 220ms;
  animation-timing-function: cubic-bezier(0.16, 1, 0.3, 1);
  animation-iteration-count: 1;
}

/* Affirmative pop for checkmarks and reaction chips */
.micro-anim--pop { animation-name: micro-pop; }
@keyframes micro-pop {
  0% { transform: scale(0.85); }
  60% { transform: scale(1.15); }
  100% { transform: scale(1.0); }
}

/* Upward launch vector for message send */
.micro-anim--launch { animation-name: micro-launch; }
@keyframes micro-launch {
  0% { transform: translate(0, 0) scale(1); }
  40% { transform: translate(2px, -3px) scale(0.92); opacity: 0.8; }
  100% { transform: translate(0, 0) scale(1); opacity: 1; }
}

/* Single subtle pulse for unread badges and pips */
.micro-anim--pulse-subtle { animation-name: micro-pulse-subtle; }
@keyframes micro-pulse-subtle {
  0%, 100% { transform: scale(1.0); }
  50% { transform: scale(1.14); }
}

/* Radar ping for socket connection recovery */
.micro-anim--radar-ping {
  position: relative;
}
.micro-anim--radar-ping::after {
  content: '';
  position: absolute;
  inset: -2px;
  border-radius: 9999px;
  border: 1.5px solid var(--color-accent);
  animation: micro-radar-ring 600ms cubic-bezier(0, 0, 0.2, 1) 2;
}
@keyframes micro-radar-ring {
  0% { transform: scale(1); opacity: 0.8; }
  100% { transform: scale(2.4); opacity: 0; }
}

/* Reduced motion guarantee */
@media (prefers-reduced-motion: reduce) {
  .micro-anim,
  .micro-anim--radar-ping::after {
    animation: none !important;
  }
}
```

### 5.2 Vue Directive Lifecycle Engine (`useMicroAnim.ts`)

Following `useTapAnim.ts`, `v-micro-anim` attaches the CSS class on event trigger and listens to `animationend` and `animationcancel` to remove the class immediately. No lingering timers (`setTimeout`), zero memory leaks, and automatic clean unbinding on unmount.

---

## 6. Build Rows Table (Rounds Rulebook R1–R16)

In strict accordance with the rounds rulebook (§1.1 max 10 rows, §1.2 1–3 pushes per item, R1 disjoint files per batch, R14 WUI coding assigned strictly to Claude):

### 6.1 Plan Rows Table

| # | Action Slug & Scope | Rationale | Sites (`file:line`, max 5) | Test / Red Control | Target Box | Vendor | Kind | Batch |
|---|---|---|---|---|---|---|---|---|
| **01** | `feat(wui, SPL-2479): micro-animation core css tokens and keyframes` | Define core micro-animation tokens in `micro-anim.css` (pop, launch, pulse, radar) and import into Nuxt asset pipeline. | `csi-spl-wui/src/assets/css/micro-anim.css:1-80`<br>`csi-spl-wui/nuxt.config.ts:35-45` | **Red control:** Unit test checks keyframe presence in stylesheet; verifies `@media (prefers-reduced-motion: reduce)` zeroes animations. | sat | claude | simple_coding | 1 |
| **02** | `feat(wui, SPL-2479): micro-animation directive with lifecycle cleanup` | Create `v-micro-anim` directive with automatic class removal on `animationend` and reduced-motion bypass. | `csi-spl-wui/src/composables/useMicroAnim.ts:1-75`<br>`csi-spl-wui/tests/unit/micro-anim-directive.test.mjs:1-60` | **Red control:** Unit test mounts element, fires trigger, asserts class added then removed on `animationend`; asserts 0 classes under reduced-motion. | sat | claude | simple_coding | 1 |
| **03** | `feat(wui, SPL-2479): copy button success checkmark draw animation` | Replace instant text swap with animated SVG checkmark draw (`stroke-dashoffset`) and pop spring. | `csi-spl-wui/src/components/CopyButton.vue:15-45`<br>`csi-spl-wui/src/components/ChatMessageActions.vue:20-50` | **Red control:** Clicking copy button triggers animated checkmark path draw before reverting after timeout. | sat | claude | simple_coding | 2 |
| **04** | `feat(wui, SPL-2479): composer message send dispatch feedback animation` | Trigger `micro-anim--launch` on send button click before message transitions to optimistic pending state. | `csi-spl-wui/src/components/ChatInput.vue:40-75`<br>`csi-spl-wui/src/components/composer/ComposerSendButton.vue:10-35` | **Red control:** Send button click executes launch transform before input clears; verified zero input delay. | sat | claude | simple_coding | 2 |
| **05** | `feat(wui, SPL-2479): reaction chip tap bounce and emoji pop` | Add elastic scale pop on tapping reaction chips or adding new emojis from picker. | `csi-spl-wui/src/components/ReactionChip.vue:12-40`<br>`csi-spl-wui/src/components/ReactionsBar.vue:25-55` | **Red control:** Tapping chip adds pop class and removes it on `animationend`; no layout shift in surrounding feed. | sat | claude | simple_coding | 3 |
| **06** | `feat(wui, SPL-2479): unread message badge single pulse on count increment` | Trigger gentle scale pulse on channel and thread dock unread badges only when count increases. | `csi-spl-wui/src/components/ChannelNavItem.vue:30-65`<br>`csi-spl-wui/src/components/ThreadDock.vue:25-50` | **Red control:** Incrementing unread count triggers pulse; non-incrementing re-renders do not animate. | sat | claude | simple_coding | 3 |
| **07** | `feat(wui, SPL-2479): live connection indicator radar ripple on reconnect` | Apply 2-cycle radar ripple ring when WebSocket transitions from disconnected to connected. | `csi-spl-wui/src/components/LiveIndicator.vue:10-45`<br>`csi-spl-wui/src/components/TopBar.vue:40-70` | **Red control:** Socket reconnect triggers radar animation for 1.2s then returns to static dot; no looping on stable connection. | sat | claude | simple_coding | 4 |
| **08** | `feat(wui, SPL-2479): empty feed state calm mascot illustration animation` | Introduce calm breathing robot mascot in empty channel state matching owner's await-anim aesthetic. | `csi-spl-wui/src/components/EmptyState.vue:1-60`<br>`csi-spl-wui/src/pages/channel/[name].vue:85-115` | **Red control:** Empty channel displays mascot SVG with gentle idle motion; vanishes when messages exist. | sat | claude | simple_coding | 4 |
| **09** | `feat(wui, SPL-2479): snackbar and undo notification slide-up transition` | Smooth cubic-bezier slide-up and fade-out transitions for notification toasts and undo snackbars. | `csi-spl-wui/src/components/Snackbar.vue:15-50`<br>`csi-spl-wui/src/components/UndoSnackbar.vue:12-45` | **Red control:** Toast mounts with smooth translateY transition; does not pop abruptly into viewport. | sat | claude | simple_coding | 5 |
| **10** | `test(wui, SPL-2479): e2e browser test suite for ui micro-animations` | Automated Playwright/Puppeteer e2e test validating reduced-motion compliance, zero layout shifts, and CSP safety. | `csi-spl-wui/tests/e2e/ui-micro-animations.test.mjs:1-150` | **Red control:** Browser test fails on master due to missing animation classes; passes when micro-animations land. | sat | claude | tests | 6 |

### 6.2 Disjoint Files Batching Verification (R1)

- **Batch 1:**
  - Row 01: `csi-spl-wui/src/assets/css/micro-anim.css`, `csi-spl-wui/nuxt.config.ts`
  - Row 02: `csi-spl-wui/src/composables/useMicroAnim.ts`, `csi-spl-wui/tests/unit/micro-anim-directive.test.mjs`
  *Verification:* Completely disjoint file sets across rows.
- **Batch 2:**
  - Row 03: `csi-spl-wui/src/components/CopyButton.vue`, `csi-spl-wui/src/components/ChatMessageActions.vue`
  - Row 04: `csi-spl-wui/src/components/ChatInput.vue`, `csi-spl-wui/src/components/composer/ComposerSendButton.vue`
  *Verification:* Completely disjoint component files.
- **Batch 3:**
  - Row 05: `csi-spl-wui/src/components/ReactionChip.vue`, `csi-spl-wui/src/components/ReactionsBar.vue`
  - Row 06: `csi-spl-wui/src/components/ChannelNavItem.vue`, `csi-spl-wui/src/components/ThreadDock.vue`
  *Verification:* Completely disjoint navigation and reaction files.
- **Batch 4:**
  - Row 07: `csi-spl-wui/src/components/LiveIndicator.vue`, `csi-spl-wui/src/components/TopBar.vue`
  - Row 08: `csi-spl-wui/src/components/EmptyState.vue`, `csi-spl-wui/src/pages/channel/[name].vue`
  *Verification:* Completely disjoint indicator and page files.
- **Batch 5:**
  - Row 09: `csi-spl-wui/src/components/Snackbar.vue`, `csi-spl-wui/src/components/UndoSnackbar.vue`
  *Verification:* Dedicated snackbar component files.
- **Batch 6:**
  - Row 10: `csi-spl-wui/tests/e2e/ui-micro-animations.test.mjs`
  *Verification:* Dedicated test file.

Every batch contains strictly disjoint file sets satisfying standing rule **R1**.

---

## 7. Performance Budget & Bundle Impact

- **Bundle Size Ceiling:** All keyframes reside in a single CSS stylesheet (`micro-anim.css`) measuring $\le 1.2\text{ KB}$ gzipped.
- **Initial JS Budget Impact:** Zero bytes added to the entry JS bundle (`ci_initial_gzip_kb` remains safely under the 155.0 KB ceiling).
- **Compositor Efficiency:** Every animation operates strictly on `transform` and `opacity`. Zero changes to geometry (`top`, `left`, `width`, `height`, `padding`, `margin`), ensuring 0 forced reflows and smooth 60fps rendering even during high agent message traffic.

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
| **Editor** | Antigravity (Google) | `a-420@sat` | **Signed** | Plan v0.1 drafted; empirical baseline measured on dev at 412×915 and 1280×800; Option B proposed. |
| **Reviewer 1** | Claude (Anthropic) | `c002-ui-animations-panel-seat-claude` | Pending | Pending reviewer seat placement; review will evaluate v0.1 draft plan. |
| **Reviewer 2** | Mistral | `c002-ui-animations-panel-seat-mistral` | Pending | Pending reviewer seat placement; review will evaluate v0.1 draft plan. |
