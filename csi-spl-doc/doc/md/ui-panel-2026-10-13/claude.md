# UI panel 2026-10-13: the claude seat

Seat c-951 of the five-vendor panel (claude, grok, mistral, agy, qwen), task
`ui-panel-34f4da14`, issue SPL-1724. Owner HUM-10 (t1 `34f4da14`, msg
`d0e4732e`): "what should be implemented in the current code base to make the
UI faster, more aesthetic and the code cleaner - 10 subtasks - the lowest
hanging fruits as of now".

Read on `origin/master` `4ac30d59b` (csi-spl-wui). The redesigned sign-in
(`pages/login.vue`, `layouts/login.vue`, `LoginFeatures.vue`,
`LoginLinks.vue`; c-451, SPL-1722) is out of scope, and no item below touches
it. No code was changed for this review.

## 1. Two measurements

Box `sat` (16 cores). The load average is given per run because other lanes
were building at the same time.

| what | value | how |
|---|---|---|
| initial JS (`200.html`) | **154.3 KB gzip**, 3 chunks (452.1 KB raw) | mock `nuxt generate` of `4ac30d59b` + `perf-budget.py bundle` (1.1); the same on live prd (WUI `8.1.3`, commit `06a9ecb8`): 154.3 KB, 3 chunks |
| home document (`index.html`) | **344.2 KB gzip**, 83 chunks (962.9 KB raw) | same run; live prd: 344.2 KB, 83 chunks |
| first contentful paint, prd, signed out | **median 260 ms** (min 136, max 320), n=10 | headless Chrome 1440x900, fresh profile per run, no throttling, `/` (it lands on `/login`); load 10.6 rising to 15.9 during the run. An earlier n=3 at load ~3: 148 / 156 / 460 ms |

Read against the ceilings in
`csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`:

- `ci_initial_gzip_kb` 154.3 against a ceiling of **155**: **0.7 KB of
  headroom**. Any change that adds code to the entry chunk now turns
  workflow 10 red, which makes item S2 more urgent than its size suggests.
- `ci_home_gzip_kb` 344.2 against a ceiling of 352.1. The spec 109 target is
  175 or less. T003 showed the 83 preloads are needed. Removing them only
  turns the same bytes into a request waterfall. The bytes come down only if
  the **default layout's static import closure** gets smaller, which is where
  S1 and S4 cut.
- The signed-out FCP is the sign-in page, which is excluded here. It is
  already fast and is not where the time goes. The signed-in first screen
  needs the e2e login (`do_spl_wui_perf_first_load`, 1.1).

Where the home bytes go (`nuxi analyze` on the mock build; sizes are the sum
of each module gzipped alone, about 1.4x the whole-chunk gzip, so the
estimates below scale them by 0.7):

- entry chunk: 136 KB of module sums, 80 KB of it app code (`spool-client`
  5.5, `channel-feed` 5.0, `live-ws` 3.7, `auth-client` 3.4, `stores/channel`
  3.4, `notify` 2.9, ...);
- default-layout closure (78 chunks): 197 KB; the largest app modules are
  `ChannelSidebar.vue` 13.3, `MessageCard.vue` 11.7, `MessageComposer.vue`
  9.3, `LiveFeed.vue` 4.6, `UserMenu.vue` 4.0.

### 1.1 Commands

Bundle sizes (the CI gate's own counter, on a mock generate):

```text
cd csi-spl-wui && pnpm install --frozen-lockfile
NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en pnpm run generate
python3 ../csi-spl-orc/src/bash/scripts/perf-budget.py bundle --pub .output/public --budgets ../csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json
```

Per-module attribution: `NUXT_PUBLIC_USE_MOCK=1 npx nuxi analyze --no-serve`,
then read `const data` in `.nuxt/analyze/client.html` (visualizer tree:
chunk -> module -> `gzipLength`).

Signed-in first load (the standard probe, needs the e2e login):
`cd csi-spl-orc && ENV=prd PF_N=10 PF_PROFILES=d1440 ./run -a do_spl_wui_perf_first_load`.

The FCP above came from a short CDP script, given in section 5.1 so the
number can be re-run.

## 2. Speed

### S1. Load the shell's interaction-only components lazily

- **What**: seven components the default layout and every message card
  build into the home closure are only mounted after a user action (all
  sit behind `v-if`), yet they are auto-imported eagerly. Prefix them with
  `Lazy`: `MoveUndoToast`, `ArchiveUndoToast`, `DeleteUndoToast`,
  `MentionDirectToast`, `OpenMessageToast`, `MergeConfirmDialog` in the
  layout, and `<EmojiPicker v-if="pickerOpen">` in the card (its own comment
  already says a closed picker should cost nothing).
- **Files**: `src/layouts/default.vue` (template only),
  `src/components/MessageCard.vue` (the `EmojiPicker` tag).
- **Gain**: 5.8 KB of module sums, so about **-4 KB on `ci_home_gzip_kb`**;
  `ci_initial_gzip_kb` unchanged.
- **Effort**: XS (seven tag renames), plus one e2e run of the undo toasts and
  the emoji picker.
- **Measure**: 1.1 bundle command, `ci_home_gzip_kb` before / after; the
  toast and picker e2e files stay green.

### S2. Win back headroom in the entry chunk (0.7 KB left)

- **What**: move code that is not needed for first paint out of `entry`, each
  behind a dynamic `import()` in `onNuxtReady` or on first use. These are the
  candidates by size in the entry chunk; check each importer before moving
  it: `utils/tenant-switcher.mjs` 1.6, `error.vue` 1.5,
  `utils/perf-mark.mjs` 1.35, `utils/emoji.mjs` 1.1 (pulled in by
  `stores/channel.ts`), `plugins/pwa.client.ts` 1.0 (keep only the
  `beforeinstallprompt` listener eager), `plugins/i18n-more.client.ts` 0.9.
  Leave `errorJournal` eager: it has to catch the earliest errors.
- **Files**: the plugins and stores named above.
- **Gain**: about **-3 to -5 KB on `ci_initial_gzip_kb`**, with matching
  savings on every document. The main win is that the next feature does
  not turn trunk red.
- **Effort**: M (one lane, each move its own commit, measured).
- **Measure**: 1.1 bundle command, `ci_initial_gzip_kb`; never raise the
  ceiling to make room.

### S3. `content-visibility: auto` on message rows

- **What**: `grep -rn content-visibility csi-spl-wui/src` returns 0 hits.
  With `content-visibility: auto` plus `contain-intrinsic-size: auto 72px` on the card
  root, the browser skips style, layout and paint for cards outside the
  viewport in a long topic or channel.
- **Files**: `src/components/MessageCard.vue` (style only).
- **Gain**: rendering time of a long feed falls with the share of cards off
  screen. Expected large on 200+ message topics; to be measured, since none
  of our probes covers it yet.
- **Effort**: S. **Risk**: the clip measure (`measure()` reads
  `scrollHeight`) and `scrollRowIntoPane` / jump-to-message must still land
  on the right row. Test those first.
- **Measure**: CDP `Performance.getMetrics` (`LayoutDuration` +
  `RecalcStyleDuration`) after opening a 300-message mock topic, n=10 before
  and after; the jump-to-message e2e stays green.

### S4. Split the off-screen sidebar tabs out of `ChannelSidebar.vue`

- **What**: `ChannelSidebar.vue` is the largest app module in the home
  closure (13.3 KB). Its template holds nine tab panels; only Channels, DM
  and Flow are shown on first paint. Move the People, Agents, Boxes and
  Events panels into `defineAsyncComponent` children. The panels are at
  template lines 488..630; Issues is already lazy (`LazyIssueEpicsPanel`).
- **Files**: `src/components/ChannelSidebar.vue`, new
  `src/components/sidebar/*Panel.vue`.
- **Gain**: an estimated **-3 to -5 KB on `ci_home_gzip_kb`**, and the file
  drops from 2,224 lines toward ~1,500 (clean code).
- **Effort**: M. **Order**: spec 109 T015 owns the rail block of this file.
  Do this after T015 lands, or keep to the panel blocks only, and check
  `lane-map.sh --check` before editing.
- **Measure**: 1.1 bundle command; `wc -l src/components/ChannelSidebar.vue`.

## 3. Aesthetics

Screenshots: mock generate of `4ac30d59b`, headless Chrome 1440x900 and
390x844 (touch), `/`, `/channel/lobby`, `/issues`.

### A1. Phone: the sender's name is cut to "HU…"

- **What**: at 390 px every message header reads `HU…`, `H… → C…`,
  `HUM-1@…`. The meta line carries the via-terminal badge, the kind icon,
  the time, the emoji button, `0 >>` and the menu button, so the name gets
  the space that is left. On the phone breakpoint, move the emoji and kind
  buttons into the row menu (it already opens as a bottom sheet). Show
  `n >>` only when n > 0, because the row itself opens the topic there
  (`clickable`).
- **Files**: `src/components/MessageCard.vue` (the `@media (max-width:
  820px)` block and the two buttons).
- **Gain**: the author is readable on every phone row.
- **Effort**: S.
- **Measure**: an e2e step at 390x844 on mock `/channel/lobby` checks that
  every `.msg-author` has `scrollWidth <= clientWidth` (fails today).

### A2. Desktop: row actions only on hover or focus

- **What**: every message row shows the open-topic button, `0 >>` and the
  menu button all the time, and every channel row shows its menu button. On
  a quiet channel the right edge is a column of icons. Show them on
  `:hover` / `:focus-within`. Keep them always visible under
  `@media (hover: none)`. Keyboard use is unchanged, because the
  msg-shortcuts open the same actions.
- **Files**: `src/components/MessageCard.vue`,
  `src/components/ChannelSidebar.vue` (styles only).
- **Gain**: a calmer feed, the Slack-like look the WUI aims for.
- **Effort**: S.
- **Measure**: before / after screenshot at 1440; an e2e step that the menu
  button is visible on `focus-within` and the existing menu e2e stays green.

### A3. The same lobby looks two ways

- **What**: `/` (which shows the lobby) does not highlight the `lobby` row
  in the sidebar and titles the pane `• #lobby`. `/channel/lobby` highlights
  the row and titles it `#lobby`. The row is only active through
  `router-link-active`, which `/lobby` does not match. Mark it active when
  `isLobbyPath(route.path)` (it is already in `utils/lobby-warm.mjs`).
- **Files**: `src/components/ChannelSidebar.vue` (the channel row's class /
  `aria-current` binding).
- **Gain**: one consistent look, and the person always sees where they are.
- **Effort**: XS.
- **Measure**: an e2e step on mock `/`: the lobby row carries
  `aria-current="page"` (fails today).

### A4. A type scale: 53 font sizes down to a handful

- **What**: `grep -rhoE "font-size:\s*[^;]+" src --include=*.vue
  --include=*.css | sort -u | wc -l` returns 53. The top three are
  `0.8125rem` x151, `0.75rem` x127 and `0.875rem` x120, plus `11px`, `12px`
  and `13px` literals. Exactly one `font-size: var(...)` exists. Spacing
  tokens exist (`--spacing-*`) but have 56 uses against 1,664 literal
  padding / margin / gap values. Add `--fs-2xs..--fs-xl` to `variables.css`
  and map the six most used values (most of the uses) onto them. Add a unit
  gate shaped like `tests/unit/css-color-tokens.test.mjs` that fails on a
  new literal outside an allow-list.
- **Files**: `src/assets/css/variables.css`, a mechanical pass over the
  `.vue` styles, a new `tests/unit/css-font-size-tokens.test.mjs`.
- **Gain**: one rhythm across panes. The size steps between the sidebar,
  feed and toolbars stop drifting by 1 px, and a later density setting
  becomes one token change.
- **Effort**: M (mechanical, but every view needs a screenshot check).
- **Measure**: the grep above, 53 -> 10 or fewer; the new gate green.

## 4. Clean code

### C1. `--color-text` is used 13 times and defined nowhere

- **What**: `grep -rn -- "--color-text\s*:" src` returns 0, but 13
  `var(--color-text)` uses sit in 10 files: `EmojiPicker`, `KindPicker`,
  `SettingsDialog`, `CalendarEventDialog`, `DisplayNameSetting`,
  `SignInEmailsPanel`, `pages/docs.vue`, `pages/tenant-settings.vue`,
  `pages/help/[[page]].vue` and `assets/css/main.css`. Each such
  declaration is invalid at computed time and silently inherits. The token
  is `--color-fg`. In the same pass, `var(--radius-sm, 6px)` (2 uses)
  carries a fallback that disagrees with the token (8 px). Add a unit gate:
  every `var(--x)` without a fallback names a defined property.
- **Files**: the 10 files above (one token each), a new
  `tests/unit/css-vars-defined.test.mjs`.
- **Gain**: colours that follow the theme as meant; the next typo is caught
  in CI.
- **Effort**: XS.
- **Measure**: `grep -rho "var(--color-text)" src | wc -l` 13 -> 0; the new
  test green, with a CONTROL that fails on the old tree.

### C2. One click-outside composable instead of six copies

- **What**: `function onDocPointer` is written out six times outside
  `usePointMenu.ts` (`issues.vue`,
  `EmojiPicker`, `KindPicker`, `UserMenu`, `SidebarRowMenu`, `ThemeToggle`),
  each with its own `document.addEventListener('pointerdown', ...)`. 16
  such document listeners exist in `src`. `UserMenu` and `ThemeToggle`
  keep theirs attached while closed. Add `useDismiss(refs, close, { ignore
  })`, attached only while open (the same idea `usePointMenu.ts` applied to
  the three row menus, CLE-77915 item 9).
- **Files**: new `src/composables/useDismiss.ts`; the six components.
- **Gain**: -60 lines or so, one behaviour (touch-sheet backdrop, ignore
  selectors) in one place, no idle listeners.
- **Effort**: S.
- **Measure**: `grep -rn "function onDocPointer" src | wc -l` 7 -> 1 (the one left is
  in `usePointMenu.ts`); the
  picker and menu e2e stay green.

### C3. Generate the `.mjs` type shims instead of hand-writing them

- **What**: `src/types/mjs-shims.d.ts` is 2,647 hand-written lines
  declaring 133 `.mjs` modules. A signature change is made twice, and only
  the existence of each shim is tested (`tests/unit/mjs-shims-exist.test.mjs`).
  Start with the 10 most imported utils: give them JSDoc types and emit
  their `.d.ts` with `tsc --allowJs --declaration --emitDeclarationOnly`,
  then delete those blocks from the shim file. Do the rest in later slices.
- **Files**: `src/types/mjs-shims.d.ts`, the chosen `src/utils/*.mjs`, a
  `typecheck` pre-step.
- **Gain**: types that cannot drift from the code; the shim file shrinks per
  slice.
- **Effort**: M for the first slice.
- **Measure**: `wc -l src/types/mjs-shims.d.ts`; `pnpm run typecheck` green.

## 5. Ranked list (11 items)

Ranked by gain for the effort, cheapest certain wins first.

| rank | item | group | effort | expected gain |
|---|---|---|---|---|
| 1 | S1 lazy toasts + emoji picker | speed | XS | ~-4 KB home |
| 2 | C1 `--color-text` + defined-var gate | clean | XS | 13 silent colour bugs, gate |
| 3 | A3 lobby row active on `/` | aesthetic | XS | one look per view |
| 4 | A1 phone header shows the name | aesthetic | S | readable author on phone |
| 5 | S2 entry headroom | speed | M | -3..5 KB initial, trunk safety |
| 6 | A2 hover-reveal row actions | aesthetic | S | calmer feed |
| 7 | C2 `useDismiss` | clean | S | 6 copies -> 1 |
| 8 | S3 `content-visibility` | speed | S | long-feed render (to measure) |
| 9 | A4 type scale + gate | aesthetic | M | 53 sizes -> <= 10 |
| 10 | S4 sidebar panels split | speed + clean | M | ~-4 KB home, -700 lines |
| 11 | C3 generated shims, slice 1 | clean | M | no type drift |

### 5.1 The FCP script

Run with `node --experimental-websocket fcp.mjs https://<env.dns.fqdn>/ 10`
(node 20, `google-chrome` on PATH):

```js
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
const [url, n = 10] = process.argv.slice(2)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function once(i) {
  const dir = mkdtempSync(tmpdir() + '/fcp-'), port = 9300 + i
  const ch = spawn('google-chrome', ['--headless=new', '--no-sandbox', '--disable-gpu', '--no-first-run',
    `--user-data-dir=${dir}`, `--remote-debugging-port=${port}`, '--window-size=1440,900', 'about:blank'], { stdio: 'ignore' })
  try {
    let tabs
    for (let k = 0; k < 50 && !tabs; k++) { try { tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json() } catch { await sleep(200) } }
    const ws = new WebSocket(tabs.find((t) => t.type === 'page').webSocketDebuggerUrl)
    await new Promise((r) => (ws.onopen = r))
    let id = 0; const pend = new Map(); const ev = []
    ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id) { pend.get(d.id)?.(d); pend.delete(d.id) } else ev.push(d.method) }
    const send = (method, params = {}) => new Promise((r) => { pend.set(++id, r); ws.send(JSON.stringify({ id, method, params })) })
    await send('Page.enable'); await send('Page.navigate', { url })
    for (const t0 = Date.now(); !ev.includes('Page.loadEventFired') && Date.now() - t0 < 60000;) await sleep(100)
    await sleep(1500)
    const r = await send('Runtime.evaluate', { returnByValue: true,
      expression: "performance.getEntriesByName('first-contentful-paint')[0]?.startTime" })
    ws.close(); return r.result.result.value
  } finally { ch.kill('SIGKILL'); await sleep(300); rmSync(dir, { recursive: true, force: true }) }
}
const f = []
for (let i = 0; i < +n; i++) f.push(await once(i))
f.sort((a, b) => a - b)
console.log(`FCP n=${f.length} median ${f[Math.floor(f.length / 2)]} min ${f[0]} max ${f.at(-1)}`)
```
