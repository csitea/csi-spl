# Perf round 19 (p19) - editor seat notes (WIP state, not the plan)

Seat: c-778 (claude), issue SPL-6363, epic SPL-2402, spec
`csi-spl-doc/specs/027-spool-performance`. Brief: desktop web UI speed,
7 rows ranked by gain per cost (owner HUM-10, t1 4369bb74, msgs 20a0121d,
6eb7d949, 2737efe6). Holder: c-002. The plan
(`perf-round-19-plan.md`) is NOT drafted yet; this file is the raw evidence
and the state at the rotation of 12:27Z.

## 1. The tree

- Every number below is on `origin/master` **`7e31ade12`** unless it says
  otherwise. Served build read: e2e and dev host `build.json` -> version
  3.6.7, commit `6c741f5b0` (an ancestor of `7e31ade12`; `git diff --stat
  6c741f5b0 7e31ade12 -- csi-spl-wui` -> 0 files).
- Mock bundle: `git archive 7e31ade12 csi-spl-wui csi-spl-cnf csi-spl-doc
  csi-spl-orc/src/bash/scripts` into a scratch tree, the main checkout's
  `node_modules` (same `pnpm-lock.yaml`), node 20.20.2 (the CI runner's),
  wf 10's generate env (`NUXT_PUBLIC_USE_MOCK=1`, `DEFAULT_LOCALE=en`, the
  four `NUXT_PUBLIC_REPO_*`), `pnpm run generate`, 11 m 29 s.
- Box: 16 cores, 1-min load 35..113 during every run below. Times are
  therefore read as indicative; ranking uses COUNTS (requests, bytes, layouts,
  style recalcs, DOM nodes, listeners), which do not move with load.

## 2. Measurements

### 2.1 Bundle (perf-budget.py on the mock generate, n=1)

`python3 csi-spl-orc/src/bash/scripts/perf-budget.py bundle --pub .output/public --budgets <027 perf-budgets.json>`:

- `ci_initial_gzip_kb` 151.9 (200.html, 3 chunks) <= 155
- `ci_home_gzip_kb` 336.3 (index.html, 92 chunks) <= 352.1

Per document (python read of the generated HTML, gzip -6):

| doc | gz | inline `<style>` raw | modulepreload n / gz | prefetch n / gz |
|---|---|---|---|---|
| index.html | 18,068 B | 52,671 B | 92 / 344.0 KB | 92 / 178.9 KB |
| 200.html | 16,827 B | 52,490 B | 3 / 155.4 KB | 190 / 357.3 KB |

Served prd e2e `/lobby` (v3.6.7, curl, n=1): 1 script + 3 modulepreload =
155.4 KB gzip, 190 prefetch = 357.4 KB gzip, 52,490 B inline style. Document
TTFB 55..177 ms (n=5); hub `/version` 115..200 ms TTFB (n=6).

### 2.2 Mock journey, desktop 1440 (perf-baseline-live.proof.mjs MOCK=1 WATERFALL=1, N=10, PROFILES=d1440,d1440-cpu4)

- cold `/lobby`: **380..404 requests**, js 326 / 2,159.8 KB raw, css 50 /
  218.8 KB; **357 of 380 requests start before the first message paints**
  (305 js) - the prefetch set (round 0 waterfall).
- every round was "loaded" (load / cores p50 4.3), so its ms are not quoted.
- The topic-list and open-topic steps read -1 on the mock (`a.topic-row` is
  not on a desktop `/` of the mock).

**Given to p20** (planner c-084, SPL-6364, msgs e31d60bb / 784bbd4b): the
prefetch-until-ready fix for app documents is p20 row 07
(`p20-07-wui-home-prefetch-after-rail`, files: `nuxt.config.ts` first-screen
hints module, `src/utils/first-screen-hints.mjs`,
`src/plugins/prefetch-on-ready.client.ts`; waits for c-980). It quotes this
waterfall as its desktop baseline. One row, one round: p19 does not plan it.

### 2.3 Dev live first load (do_spl_wui_perf_first_load, ENV=dev PF_N=8 PF_PROFILES=d1440, warm cache)

| metric | median / p90 (n=8) |
|---|---|
| rail | 6,004 / 10,196 ms |
| Flow | 8,125 / 13,959 ms |
| TBT | 2,986 / 6,745 ms |
| long tasks | 20 / 39 |
| script ms (CDP) | 996 / 1,659 |
| layout ms (CDP) | 535 / 725 |
| ws created / open | 3,972 / 5,457 ms |
| DOM nodes | 932 / 932 |

Box load 69+ during it; spec 109 section 7 read rail-class waits of 0.6..0.9 s
on an unloaded box, so these are box readings, not the WUI's.

### 2.4 Dev CPU profile, one profiled round (FL_CPU_PROFILE=1, PF_N=3)

Top self ms, mapped by reading the deployed chunk at that column:

| self ms | where | what |
|---|---|---|
| 117 | `/:5:18` (the document) | the inline locale script of the document |
| 100 | `B573Gg8G.js:2:51508` | Vite's preload helper: per dependency it walks every `<link>` in `<head>` backwards (O(deps x links); 190+ prefetch links in head) |
| 86 | `4ZvAZKHv.js:2:37540` | `useSidebarVersion.ts` foot-row check (`getBoundingClientRect` + `getComputedStyle`): **p20 row 02's file** |
| 80 | `B573Gg8G.js:11:53386` | `stores/notification.ts` `readPermission` (`Notification.permission`) at hydrate |
| 74 | `MTxneD_j.js:1:15992` | vue-i18n translate (`ot`) |

n=1 profiled round under load: leads, not baselines.

### 2.5 Desktop journey counters on the mock (probe, scratch, n=1 so far)

A scratch probe (not committed; `/var/tmp/c-778-p19/probe/desk-journey.mjs`)
drives one fresh context: cold `/lobby`, `/channel/alerts`, `/lobby`, a topic,
a 400-reply topic (mock `spool.mock.extra-messages`), 40 scroll steps in it,
`/search?q=line`, `/lobby`, 40 typed characters; CDP `Performance.getMetrics`
deltas per step. n=1, load1 80.9:

| step | wall ms | layouts | style recalcs | script ms | long tasks | nodes after | listeners after |
|---|---|---|---|---|---|---|---|
| cold-lobby | 4197 | 19 | 59 | 507 | 15 | 1,587 | 396 |
| switch-alerts | 550 | 6 | 13 | 10 | 3 | 1,911 | 451 |
| switch-lobby | 449 | 7 | 12 | 6 | 1 | 2,147 | 484 |
| open-topic | 1090 | 9 | 20 | 59 | 5 | 3,333 | 649 |
| open-long-topic | 1581 | 18 | 29 | 4 | 5 | 7,313 | 1,530 |
| scroll-long-topic | 654 | 0 | 2 | 1 | 0 | 7,315 | 1,530 |
| search | 376 | 11 | 16 | 8 | 3 | **17,845** | **3,158** |
| back-lobby | 175 | 10 | 13 | 1 | 1 | **18,083** | **3,194** |
| type-40 | 1910 | **172** | **176** | 253 | 1 | 18,131 | 3,198 |

Re-run n=5 (13:1xZ, load1 86..95; medians; `/var/tmp/c-778-p19/probe-n5.json`):

| step | wall ms | layouts | style recalcs | script ms | long tasks | nodes after | listeners after |
|---|---|---|---|---|---|---|---|
| cold-lobby | 3395 | 19 | 57 | 370 | 11 | 1,588 | 396 |
| switch-alerts | 735 | 6 | 13 | 15 | 3 | 1,912 | 451 |
| switch-lobby | 255 | 7 | 12 | 1 | 1 | 2,148 | 484 |
| open-topic | 925 | 9 | 19 | 55 | 6 | 3,334 | 649 |
| open-long-topic | 2136 | 19 | 30 | 5 | 7 | 7,288 | 1,529 |
| scroll-long-topic | 665 | 0 | 2 | 2 | 1 | 7,290 | 1,529 |
| search | 928 | 11 | 16 | 8 | 3 | 17,820 | 3,157 |
| back-lobby | 304 | 10 | 13 | 1 | 1 | 18,058 | 3,193 |
| type-40 | 1768 | **172** | **176** | 223 | 0 | 18,106 | 3,197 |

The counts are the same in all 5 rounds (type-40: 172 / 176 in 5 of 5;
nodes after back-lobby 17,932..18,072; listeners 3,193..3,194), so L1 and L2
are deterministic, not load noise. Wall ms remain box readings.

Leads (to be attributed before any becomes a row):

- L1 nodes / listeners grow 1,587 -> 18,083 and 396 -> 3,194 over 8
  navigations and are not released on Back to `/lobby` (CDP `Nodes` counts
  detached nodes too: a leak or a kept-alive page; `search` alone +10,500).
- L2 typing: 172 layouts and 176 style recalcs for 40 keys, ~4.3 forced
  layouts per key (composer autosize / mention picker read?), 253 ms script.
- L3 Vite preload helper link walk (2.4).
- L4 `Notification.permission` read at hydrate (2.4).
- L5 cold `/lobby` 19 layouts / 59 style recalcs / 15 long tasks before
  settle.

### 2.6 Dev hub reads per step (do_spl_wui_perf_flow_events, ENV=dev PF_N=6 PF_PROFILES=d1440)

first-screen median 3,809 / p90 5,312 ms; flow-cold 475 / 892; flow-warm
95 / 134 (n=6, load1 56..65). The flow-open and events steps read -1 (the
dev t1 Flow entries open release notes; the step's selector never matched).
Hub reads, client ms median / p90, n over the 6 rounds:

| step | route | ms | n / 6 rounds |
|---|---|---|---|
| first-screen | `GET /api/v1/auth/session` | 90 / 174 | 6 |
| first-screen | `GET /v1/view/me` | 66 / 149 | **10** |
| first-screen | `GET /v1/view/topics` | 100 / 143 | **10** |
| first-screen | `GET /v1/view/roster` | 146 / 367 | 6 |
| first-screen | `GET /v1/view/channels` | 122 / 381 | 6 |
| first-screen | `GET /v1/view/flow`, `issues`, `search/operators` | 92..108 | 5 each |
| first-screen | `GET /v1/view/topics/:id` | 84 / 187 | 4 |
| first-screen | `GET /v1/me/reads` | 66 | 2 |
| flow-cold | `GET /v1/view/flow` | 181 / 247 | 6 (again after first-screen's 5) |
| flow-open | `GET /v1/wui/revision` | 70 / 85 | **12** |
| flow-open | `GET /v1/release-notes` | 212 / 242, 27.8 KB | 6 |

Leads: L6 `/v1/view/me` and `/v1/view/topics` read ~1.7 times per first
screen (spec 109 T004 keeps a settled roster / topic-list read for 10 s;
`me` is not in it); L7 Flow read again on the first Flow open although
first-screen read it; L8 `/v1/wui/revision` twice per step. The hub itself
answers in 66..181 ms medians: the desktop wait is client work, not the hub.

## 3. Off-limits files (R1 / R3), read 2026-11-24

- c-980 (SPL-5070, Nuxt 4), from `review/c002-spl5070-nuxt4-migration-r2`
  (`git diff --stat origin/master...FETCH_HEAD`, 29 files): `nuxt.config.ts`,
  `package.json`, `pnpm-lock.yaml`, `tsconfig.json`, `i18n/client-loaders.ts`,
  `src/pages/blog.vue`, `src/utils/perf-mark-core.mjs`,
  `src/utils/public-seo.mjs`, `perf-budget.py`, `perf-budgets.json`,
  `render-wui-firebase-json.sh`, wf 10/15/30/50/63, 8 e2e/unit files.
- p20 (c-084, plan v0.2 `fd664e5b0`): `useLoopStrip.ts`,
  `useSidebarVersion.ts`, `parent-section-open.mjs`,
  `useLiveFeedThreadEnds.ts`, `useCardHeight.ts`, `read-sync.mjs` +
  `read-sync-boot.ts`, `first-screen-hints.mjs`, `prefetch-on-ready.client.ts`
  (+ the hints module of `nuxt.config.ts`).
- Lane map 11:28Z: no lane recorded files; WUI lanes c-747, c-980, g-067,
  c-918.

## 4. Not available to this seat

- `do_spl_wui_perf_report` (RUM field data) on dev: 403, the test member is no
  workspace admin. No field numbers.
- No sign-in of my own, no post on dev or prd, no key read. The dev harness
  runs went through their own actions (the action reads its test member).

## 5. Next (for this seat or its successor)

1. Re-run the probe n=5 (`N=5`), then attribute L1 (heap snapshot: which
   component keeps the nodes) and L2 (a trace with forced-layout stacks).
2. Read `do_spl_wui_perf_flow_events` output (`/var/tmp/c-778-p19/flow-dev`,
   running at rotation) for the hub reads per step.
3. Draft 7 rows off section 3's files, each with baseline / gain / files /
   counting test + red control; send c-084 and c-002 the file list; push
   v0.1 to `review/c002-perf-round-19-planner`; ask c-002 for panel seats.
