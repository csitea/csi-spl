# Perf round 20 (p20): editor's measurements

Seat: c-084 (claude), planner and editor of [perf-round-20-plan.md](../perf-round-20-plan.md).
Every number below was read on 2026-11-24 between 11:30Z and 11:55Z. Raw
outputs stay in the measuring user's state dir (`<state>` below); this file
quotes them.

<a id="p20e-1"></a>

## 1. The one tree

- `origin/master` at the plan's reading: `09f137d40`. Its `csi-spl-wui/`
  tree is the one prd serves and the one CI built:
  - `git log --oneline 6c741f5b0..09f137d40 -- csi-spl-wui | wc -l` -> `0`
  - `git log --oneline 3314cc4e5..09f137d40 -- csi-spl-wui | wc -l` -> `0`
  - `curl -s https://e2e.<domain>/build.json` -> `"commit":"6c741f5b08081530c308867c386c40103e6b87f6"`, `"version":"3.6.7"` (prd, the test workspace `e2e`; the default host reads the same).
- CI bundle: wf 10 run `45377752048` (head `3314cc4e5`), artifact
  `wui-mock-bundle` (`gh run download 45377752048 -n wui-mock-bundle`).

<a id="p20e-2"></a>

## 2. Bundle (CI's mock generate, box node 20.19.2)

The runner node 20.20.2 is not on this box (`find / -maxdepth 8 -path
'*node/20.20.2*' -name node` -> nothing), so these are box-node readings; CI
reads about 0.3 KB higher (spec 027 `perf-budgets.json` basis).

`python3 csi-spl-orc/src/bash/scripts/perf-budget.py bundle --pub <bundle>
--budgets csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json`
(n=1):

| document | chunks | gzip KB |
|---|---|---|
| `200.html` (every non-prerendered route) | 3 | 151.7 |
| `index.html` (`/`, the signed-in home) | 92 | 335.9 |

Hints in the documents (`grep -oE 'rel="prefetch"' | wc -l`):

| document | modulepreload | prefetch | prefetch gzip KB |
|---|---|---|---|
| `200.html` | 3 | 190 | 351.4 (359,794 B) |
| `index.html` | 92 | 92 | - |

The biggest first-screen chunks of `index.html` (gzip B, with the component
names their code carries, `grep -oE '__name:"[A-Za-z]+"'`): entry 94,186
(`app`, `error`, `BuildUpdateBar`); the default layout 53,951
(`ChannelSidebar`, `TopBar`, `MessageComposer`, `NotificationCenter`,
`UserMenu`, `SidebarRowMenu`, `MergeConfirmDialog`, five toasts); vendor
48,947.

<a id="p20e-3"></a>

## 3. First load on a phone, network (prd, test workspace)

`ENV=prd PFL_N=5 PFL_PROFILES=m390 PFL_NET=fast4g ./run -a
do_spl_wui_perf_first_load_net` (csi-spl-orc; 390 x 844, CPU 4x, 150 ms RTT,
9 Mbit/s; `PUPPETEER_CORE` pointed at a puppeteer-core already on the box,
nothing installed). Evidence `<state>/perf-first-load-net/e2e/20261124T113605Z`.

| first load (median / p90) | m390-cold (n=5) | m390-warm (n=5) |
|---|---|---|
| rail visible ms | 5042 / 6731 | 3213 / 5300 |
| requests before rail | 249 / 253 | 236 / 241 |
| KB before rail (wire) | 1145.7 / 1147.6 | 3.5 / 3.7 |
| prefetch requests / KB | 92 / 428.5 | 92 / 0 |
| prefetch before rail | 92 / 92 | 92 / 92 |

Per cold round, from `first-load-net.json` (a prefetched path counts as
"used" when the same path is also fetched as a normal request):

| rail ms | prefetched | used before rail (n / KB) | used only after rail (KB) | never used in rail + 4 s (n / KB) | normal js+css before rail (n / KB) |
|---|---|---|---|---|---|
| 6731 | 92 | 17 / 100.0 | 137.0 | 42 / 191.6 | 141 / 666.6 |
| 4050 | 92 | 17 / 100.0 | 133.6 | 43 / 194.8 | 141 / 689.3 |
| 5042 | 92 | 20 / 114.9 | 122.0 | 42 / 191.5 | 144 / 689.3 |
| 4355 | 92 | 17 / 100.0 | 136.9 | 42 / 191.5 | 141 / 689.3 |
| 5071 | 92 | 20 / 114.9 | 122.0 | 42 / 191.5 | 144 / 689.3 |

So 313..329 KB of the 1,146 KB before the rail is prefetch the rail does not
use. The hub reads before the rail (cold round 2): `auth/session`,
`/config.json`, `view/channels` (200), `view/roster`, `me/reads`,
`view/topics?limit=50`, `view/me`, `/build.json`, `view/channels` (a 204
preflight, then 200 again), `view/topics?...dm=true`, `/build.json`,
`view/search/operators` (1.9 KB). `OPTIONS` answers carry
`access-control-max-age: 7200` (curl, n=3), so the preflights are
first-visit only.

<a id="p20e-4"></a>

## 4. First load on a phone, main thread (prd, test workspace)

`ENV=prd PF_N=5 PF_PROFILES=m390 FL_CPU_PROFILE=1 ./run -a
do_spl_wui_perf_first_load` (warm HTTP cache, CPU 4x, no network
throttle). Evidence `<state>/perf-first-load/e2e/20261124T114554Z`.

| m390, n=5 | median | p90 |
|---|---|---|
| rail ms | 3108 | 4046 |
| blocking time before rail ms | 1290 | 1682 |
| blocking time, whole load ms | 1575 | 1950 |
| long tasks / longest ms | 14 / 762 | 15 / 875 |
| script ms / layout+style ms | 995 / 527 | 1081 / 572 |
| hub socket constructed / open ms | 2059 / 3170 | 2691 / 4018 |

`flow` read n=0: on a phone the Flow tab navigates, and the probe waits for
the desktop list (section 6).

The profiled round (n=1), self ms of the served chunks: vendor 1,345.4, entry
759.8, default layout 485.5. Its hottest function is in the default layout
chunk, `s` at 132.7 ms self: `measureFoot` of
`csi-spl-wui/src/composables/useSidebarVersion.ts:86-90`. It reads
`getBoundingClientRect()` and only then tests `!phone.value`, so a phone pays
the layout read for an answer that is always `false`. It runs on mount, on
every ResizeObserver callback and on every route change (`:106`, in a
`requestAnimationFrame`).

<a id="p20e-5"></a>

## 5. Clicks on a phone (prd, test workspace)

A scratch probe (not committed): kept session, never signs in, never posts.
390 x 844, CPU 4x, 150 ms RTT, 9 Mbit/s. Per round: `/` -> Channels tab ->
`#lobby` -> the first card -> Back -> another channel -> search. A step ends
when its target is first on screen.

| step, ms | n | median | min..max |
|---|---|---|---|
| Channels tab -> list | 5 | 57 | 48..102 |
| channel open -> first card | 5 | 881 | 590..1129 |
| topic open -> topic root | 5 | 531 | 326..571 |
| channel switch -> cards | 5 | 525 | 371..618 |

Each hub read in these steps took 156..201 ms (150 ms is the emulated RTT).
A step needs one read (`view/topics?channel=` for a channel,
`view/topics/<id>` for a topic), so ~350..900 ms of each step is the phone's
own work. Each channel open and each topic open also read `me/reads` and
`view/channels?read=...` (5 of 5 rounds each).

Not measured, and why: **scrolling a long topic** (the workspace has 4
channels, 1 card in `#lobby` and short topics: no scroller, 5 of 5 rounds);
**search** (the probe's end marker never matched, 5 of 5; the step fired
`wui/revision` x3, `me/reads`, `view/channels`, `perf/samples`); **posting**
(a post writes prd: not run).

CPU profile of the same clicks (V8 sampling every 200 us, n=3 rounds, self ms
summed over the 3):

| step | function (served chunk) | source | self ms / 3 rounds |
|---|---|---|---|
| channel open | `Xu` (default layout) | `fitStrip`, `useLoopStrip.ts:170-174`: `box.clientWidth` | 308.8 |
| channel open | native `getBoundingClientRect` | (the callers above and below) | 159.7 |
| channel open | `Ls` (message card chunk) | `measureBox`, `useCardHeight.ts:52-62`: `getComputedStyle` + `scrollHeight` per card | 113.5 |
| topic open | `c` (small util chunk) | `holdCard`, `parent-section-open.mjs:131-156`: a `requestAnimationFrame` loop that reads `getBoundingClientRect().top` until it holds still | 182.8 |
| topic open | `d` (live feed chunk) | `measureJump`, `useLiveFeedThreadEnds.ts:33-51`: `scrollTop` / `scrollHeight` / `clientHeight` | 154.5 |

The `(program)` bucket (native work, style and layout among it) was 2,577 ms
(channel open) and 1,845 ms (topic open) over the 3 rounds. A self time that
holds a forced layout is an upper bound of the gain: part of that layout is
needed before the next paint anyway. Each row's lane measures the rest.

The profiler probe:

```js
// read-only: one warm load, then CPU-profile channel-open and topic-open (n=3 each)
const puppeteer = (await import(process.env.PUPPETEER_CORE)).default
const BASE = process.env.BASE
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const browser = await puppeteer.launch({ executablePath: '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'], userDataDir: process.env.USER_DATA_DIR })
const p = (await browser.pages())[0] || await browser.newPage()
await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 3 })
const cdp = await p.createCDPSession()
await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 })
await cdp.send('Profiler.enable'); await cdp.send('Profiler.setSamplingInterval', { interval: 200 })
const agg = {}
function add(step, prof) {
  const byId = new Map(prof.nodes.map((n) => [n.id, n])); const dt = {}
  for (let i = 0; i < prof.samples.length; i++) dt[prof.samples[i]] = (dt[prof.samples[i]] || 0) + (prof.timeDeltas[i] || 0) / 1000
  for (const [id, ms] of Object.entries(dt)) { const cf = byId.get(Number(id)).callFrame; const k = `${cf.functionName || '(anon)'} ${cf.url.replace(/^https:\/\/[^/]+/, '')}:${cf.lineNumber + 1}:${cf.columnNumber + 1}`; agg[step] ??= {}; agg[step][k] = (agg[step][k] || 0) + ms }
}
const vis = (sel) => p.waitForFunction((s) => { for (const el of document.querySelectorAll(s)) { const r = el.getBoundingClientRect(); if (r.width > 0 && r.height > 0) return true } return false }, { timeout: 30000, polling: 100 }, sel)
for (let i = 0; i < 3; i++) {
  await p.goto(BASE + '/', { waitUntil: 'domcontentloaded' }); await vis('[data-testid=sidebar-tab-flow]'); await sleep(3000)
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click()); await sleep(800)
  for (const [step, act, sel] of [
    ['channel-open', () => p.evaluate(() => [...document.querySelectorAll('#sidebar-panel-channels .nav-item')].find((e) => (e.getAttribute('href') || '').endsWith('/channel/lobby'))?.click()), '[aria-describedby=feed-open-hint]'],
    ['topic-open', () => p.evaluate(() => document.querySelector('[aria-describedby=feed-open-hint]')?.click()), '[data-test=topic-root]']]) {
    await cdp.send('Profiler.start'); await act(); await vis(sel).catch(() => {}); await sleep(500)
    add(step, (await cdp.send('Profiler.stop')).profile)
  }
}
for (const [step, m] of Object.entries(agg)) for (const [k, ms] of Object.entries(m).sort((a, b) => b[1] - a[1]).slice(0, 18)) console.log(step, ms.toFixed(1), k)
await browser.close()
```

<a id="p20e-6"></a>

## 6. What could not be read here

- **Field data (spec 066).** `ENV=prd PERF_DAYS=7 ./run -a
  do_spl_wui_perf_report` -> `FATAL ... no readable password file
  <state>/m3-e2e/t1/pw-human`; the test workspace's member -> `403 forbidden,
  the member lacks tenant.settings`; dev `e2e` -> `401 invalid_credentials`.
  So no row cites a field p75; the plan asks the holder for a workspace
  admin's read (plan section 6).
- **The Flow probe on a phone.** `ENV=prd PF_N=5 PF_PROFILES=m390 ./run -a
  do_spl_wui_perf_flow_events` -> `m390 round 0 ERROR Execution context was
  destroyed, most likely because of a navigation.` (rounds 0 and 1, then
  stopped by this seat): the phone's Flow tab navigates and the probe does
  not follow it. A tool defect, not perf work: sent to the orchestrator.
- **The runner's node** (section 2).

<a id="p20e-7"></a>

## 7. Seat state (for a restart of this seat)

Written at the 12:33Z rotation, 2026-11-24; updated at the 14:30Z one, after it, and at 15:31Z.

- Plan v0.2 is on `review/c002-perf-round-20-planner`, sha `fd664e5b0` (on
  `09f137d40`; v0.1 was `f120ed920`). Not on master; not signed.
- Panel: the holder (c-002) queued a mistral seat (ask 9bbc3db9) and an agy
  seat (ask 21032ee7); both briefs name `fd664e5b0` (holder msg adf38838).
  Not placed at 12:33Z. Grok held (weekly 97%).
  Mistral (m-135): PASS on `fd664e5b0` (msg 1901395a, seat file
  `review/c002-perf-round-20-mistral-seat` `960bb5d2f`), one minor defect
  W1 for v1.0: the action table has no `box` column (rulebook 3.1). Agy:
  not placed yet. The holder (msg be24df21) asked for v1.0 with W1 and
  N1..N6 folded: v1.0 is the next commit on the review branch; the holder
  GOes the landing, not this seat.
- State at the 15:31Z rotation: the review branch head is v1.0
  `312380222` (`659875506` plus the read time fixed). m-135 PASS on
  `312380222` (msg 367a86fc, seat file `3bfa6a954`; it reached only this
  seat, forwarded to c-002). Agy (ask 21032ee7): no verdict. The holder
  (msg 8dae88c1): keep the head. So THIS commit is local only, not pushed:
  pushing it would move the branch past the signed sha. Next: on the agy
  verdict fold or answer; on the holder's GO rebase onto origin/master, drop
  or keep this commit as the holder says, land with `do_spl_push_master`,
  then the Qto import.
- State at the 16:32Z rotation: unchanged. The planner head is still
  `312380222` (ls-remote). The mistral seat branch moved to `972b1449a`, its
  own state commits only, no new verdict. Agy: still no verdict, no agy seat
  branch on origin. This commit stays local beside the 15:31Z one.
- State at the 17:33Z rotation: unchanged. Planner head still `312380222`
  (ls-remote). Mistral seat branch at `6babc7d4e`, its 17:17Z state commit
  only, no new verdict. The second seat (claude backup for agy, ask
  600e0886, queued 15:08Z) has no branch on origin and no verdict yet.
  Local, not pushed, like the two state commits before it.
- State at the 18:34Z rotation: unchanged. Planner head still `312380222`
  (ls-remote). Mistral seat branch at `dc61daa7e`, its 18:18Z state commit
  only, no new verdict. The second seat (claude backup for agy) still has no
  branch on origin and no verdict. Local, not pushed, like the three state
  commits before it.
- State at the 19:35Z rotation: LANDED. The holder ruled the panel
  cross-vendor with the mistral PASS alone (msg af8ad549; agy out of quota
  until 12-01). c-020 (claude, extra reader) passed `312380222` with notes
  W1-W3 and N1-N7 (seat file `94c776ca7`). The holder gave the GO (msg
  7e58fef4, word ffa37af8). The 12 commits were reworded with release notes
  only (patch-ids equal) and landed as `580bf49e3`; v1.0 is `f8b09f84b`. The
  Qto import is doc `e7b54b47-a399-435e-907b-5fd035954a1b` (`59d27de50`; map
  row added by hand, as p17). The v1.1 fold of W1-W3 and N1/N3, edited in
  Qto and then exported, is `384916e59` (holder msg ef8c263c). Report sent
  to the holder on `dispatch-perf-r20`.
- Next: wait for a message starting with ACCEPTED. The holder files one
  issue per row and places them; a send-back is answered here, and a plan
  edit goes into Qto doc `e7b54b47` first, then the export.
- Perf round 19 (c-778): plans none of the p20 files; row 07 takes its
  app-document prefetch finding (msg e31d60bb, answered by this seat).
  p19 v0.1 (`d86a2f880`, msg c6992303) lists its row files; `grep -c` of
  each name in the v0.2 plan is 0 outside `useLiveFeedThreadEnds.ts` (not
  `useLive.ts`) and the read-only `perf-baseline-live` command quote, so
  R1 holds both ways (answered, msg 31129549).
- Field data: not readable (no workspace admin login; holder msg 390f5cf5).
  Flow probe on phones: the holder's bug lane
  `c002-bug-wui-perf-flow-events-m390-nav` (c-117, SPL-6386). It found
  `d1440` fails the same way (msgs a82a3859, c1585eb8): the plan's line 240
  ("errors on every m390 round") is fixed in v1.0, not in v0.2 while the
  panel signs it. No p20 row edits that probe (answered, msg 5f6dfa29).
  c-117 landed that fix as `8d348dbe1` (msg abfc15b4; `merge-base
  --is-ancestor` rc 0).
- The seat closes only on a message on `dispatch-perf-r20` starting with
  ACCEPTED.
