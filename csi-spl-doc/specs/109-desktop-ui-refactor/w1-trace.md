# 109 T005: why `/lobby` shows its first message late (W1 trace)

**Task**: [tasks.md](tasks.md) T005 · **Spec**: [spec.md](spec.md) W1, W2, W3, D1, D2, FR-001 · **Lane**: c-581 · **Date**: 2026-10-08, 18:07..18:22Z
**Result**: the first message does **not** wait for the hub socket. W1 is the WUI's boot and first render, CPU work on the main thread, and it grows with the measuring box's CPU load. The spec's 5,004 ms was measured on a loaded box. On an idle box the same sha shows the first message in 844 ms warm.

---

## 1. Setup

| what | value |
|---|---|
| host | prd e2e workspace host (`https://e2e.<domain>`), signed in as the env's m3-e2e member (its login lives only on the drafting box; never printed or copied) |
| WUI | `3.7.9` `ce1461b5ef7eac9019c580d367dffe98dbc3ca33` (`<host>/build.json`), every run. The spec's runs had `bd165b42`; the 4 WUI commits in between (`git log bd165b424448..ce1461b5ef7e -- csi-spl-wui/src csi-spl-wui/nuxt.config.ts`) are the 107 header timer, a sidebar clock fix and two mock or test changes. None is on the boot or lobby path |
| browser | headless Chrome, 1440 x 900, CPU 1x, no network throttle |
| rounds | n=10 per box. Each round runs cold `/lobby` (HTTP cache cleared), then warm `/lobby`, then cold `/` (first topic row). 0 rounds had a connect over 1 s (longest 240 ms), so no round was set apart |
| boxes | **drafting box, loaded** (load average 36..60 on 16 cores); **second box** (Chrome runs there, so its own CPU and link; driven from the drafting box over an ssh tunnel, so the login never leaves it; load 10..27 on 16 cores); **drafting box, idle** (the same box right after its reboot drill, load 6..9) |
| probe | `/var/tmp/spec109/t005/w1-trace.mjs` on the drafting box. In the page, from navigation start (`performance.now`), it records: Resource Timing of `/config.json`, the session read and the two lobby reads; pinia `session.state === 'in'` (sampled each frame, the same frame the app mounts); a wrapped `WebSocket` (constructed = **asked**, `open`, first frame); the first `article.msg`; long tasks. CDP gives each round's longest connect. A CPU profile (`w1-profile.mjs`, 5 warm loads, 200 µs sampling) names the work. Evidence: `trace.json` / `profile.json` and a `*.log` per run in `/var/tmp/spec109/t005/` |

## 2. The trace (warm `/lobby`, median / p95 ms from navigation start)

| step | drafting box, loaded | second box | drafting box, idle |
|---|---|---|---|
| session read answered (`/api/v1/auth/session`) | 230 / 385 | 79 / 117 | 80 / 255 |
| **app mounted**, session `in` | **1,556** / 3,524 | **717** / 951 | **493** / 956 |
| room read `GET /v1/view/topics/<lobby>` starts | 1,925 / 3,403 | 697 / 931 | 481 / 934 |
| room + lobby topics reads answered | 2,045 / 3,539 | 739 / 1,018 | 562 / 984 |
| socket **asked** (`new WebSocket`) | 1,505 / 3,424 | 700 / 935 | 481 / 938 |
| socket connect + handshake (`open` − asked) | 180 / 230 | 46 / 83 | 217 / 300 |
| socket `open` | 1,695 / 3,581 | 750 / 994 | 699 / 1,204 |
| data in → first message painted | **814** / 1,534 | **488** / 684 | **287** / 361 |
| **first message (W1)** | **2,445** / 5,073 | **1,250** / 1,617 | **844** / 1,324 |
| long tasks before it (n / TBT / longest) | 4 / 581 / 510 | 1 / 307 / 347 | 2 / 100 / 145 |

The columns are medians of each step on its own, so they do not add up exactly. A round reads in order, e.g. drafting box loaded, round 0: session 230 → app 1,556 → room read 1,488..1,626 → socket open 1,695 → first message 2,445.

### 2.1 What the first message waits on

1. **Not the socket.** The room read is started by `plugins/lobby-warm.client.ts` the moment the session store says `in`, with the lobby id from `/config.json`, which prd serves (`lobbyTaskId` = the hub's `SPOOL_HUB_LOBBY_TASK_ID`). The socket is asked in the same tick (`plugins/spool-live.client.ts`). In every round the room read ends before or within a few ms of `open`, and the message paints hundreds of ms later. The handshake itself costs 46..217 ms (median per box).
2. **D2 split.** "The app asks for the socket" = app mount, 493..1,556 ms (median, by box). "The socket's connect and handshake" = 46..217 ms. The spec's `ws open after nav` 4,007 ms was almost all **asked late**, and the ask waits for the same app boot that the reads and the first message wait for. So `ws open` and W1 move together because both wait on the boot. The socket does not cause W1. The spec's own data already split it: `ws connect` 83 ms median vs `ws open after nav` 4,007 ms.
3. **The app boot.** The session is answered at 80..230 ms, but nothing can use it until the app mounts at 493..1,556 ms. Warm, every script comes from the cache (190 script resources per load), so this is parse, compile and run time, not download (agrees with D1: warm ≈ cold). The CPU profile on the loaded drafting box (n=5 warm loads) puts boot at 2,610 ms per load: 1,308 ms native work (`(program)`: parse, compile, style) and 898 ms `(idle)` (the thread waits: cached module fetches, and on a loaded box the scheduler).
4. **The first render.** After the data is in, the message paints 287..814 ms later. That window is one long task of 145..510 ms (median) building the shell and the feed. The profile puts it at 1,605 ms per load on the loaded drafting box, 514 ms of it in the Vue runtime chunk.
5. **No read chained after the roster.** The room read starts at app mount, alongside `channels` and `roster`, never after them.

### 2.2 The box's CPU load is the multiplier

| same WUI sha, warm W1 median / p95 | load avg / cores | W1 |
|---|---|---|
| drafting box, idle (after the reboot drill) | 6..9 / 16 | **844** / 1,324 |
| second box | 10..27 / 16 | **1,250** / 1,617 |
| drafting box, loaded | 36..60 / 16 | **2,445** / 5,073 |
| spec section 2 (drafting box, `bd165b42`, load not recorded) | ? | **5,004** / 11,074 |

Same box and link, only the load differs: warm W1 goes from 844 to 2,445 ms. The spec's rounds track main-thread blocking (`baseline/baseline.json`, warm): 1,718 ms at TBT 461, 5,004 at 1,289, 11,074 at 3,928. Its TBT median was ~1,600 ms against 100 ms on the idle drafting box. The links were clean: 0 rounds with a connect over 1 s on either box.

## 3. W1..W3 from two boxes (s109-3 change 3)

Median / p95 ms, n=10 each, 0 stalled rounds, WUI `ce1461b5`. Drafting box idle, cold, has n=9: round 7 saw no message within 40 s, kept out and reported here.

| wait | spec (drafting box, `bd165b42`) | drafting box, loaded | second box | drafting box, idle | FR-001 target |
|---|---|---|---|---|---|
| W1 `/lobby` warm, first message | 5,004 / 11,074 | 2,445 / 5,073 | 1,250 / 1,617 | 844 / 1,324 | <= 1,500 |
| W2 `/lobby` cold, first message | 5,373 / 10,021 | 3,525 / 4,994 | 1,485 / 2,186 | 982 / 1,088 | - |
| W3 `/` cold, first topic row | 4,942 / 7,504 | 2,154 / 4,532 | 1,154 / 1,483 | 806 / 1,151 | - |

On a box that is not saturated, FR-001's target already holds (second box 1,250, idle drafting box 844). It is missed only under load (2,445). This is not a box-link stall (s109-3 rule): it is box CPU, which the longest-connect column cannot see.

## 4. Cause, named with numbers

**W1 = app boot (≈ 0.5..1.6 s) + two reads (≈ 0.04..0.15 s) + one long first render (≈ 0.3..0.8 s), all on one main thread.** Its size scales with the CPU the page gets: ×2.9 from the idle to the loaded drafting box. The hub socket is off the critical path (handshake 46..217 ms, asked in the same tick as the reads). D9 holds: the hub answers its reads in 40..150 ms.

Real users see the same shape. Dev RUM `load_messages` cold p75 is 6,180 ms (spec 1.1), but `send_ack` p50 is 138 ms. A user's laptop under load is the loaded box here.

## 5. Fix shape for T006

FR-001 as written ("the first page comes from the view read, the socket only adds live rows") is **already true** in the code: no socket-free rewrite would save time. Per FR-001's own clause ("if the trace points elsewhere, the trace wins"), T006 is re-shaped to CPU:

| # | change | where | expected effect (to be measured) |
|---|---|---|---|
| 1 | **Measure under CPU load, not on luck**: every before/after of T006 (and T014) runs the baseline probe at `Emulation.setCPUThrottlingRate` 4 (a slow laptop) as well as 1, and records the box's load average per run; a run with load / cores > 1 is reported apart, like a stalled connect | the probe and the tasks.md rules (T006 / T014 lanes) | before/after numbers that do not flip with box load |
| 2 | **Paint the lobby feed before the rest of the shell**: the first render after the data builds the shell and the feed in one task of 145..510 ms. Mount the feed's first rows first and let the rail, panel 1 and the header widgets follow in a later task (lazy or `requestIdleCallback`) | `wui/src/pages/lobby.vue`, `wui/src/layouts/default.vue` (render order only) | data in → first paint 287..814 → < 150 ms |
| 3 | **Less work before mount**: the session is known at 80..230 ms, but the app mounts at 493..1,556 ms. Name the plugins and chunks that run before mount (`(program)` 1,308 ms per load under load) and defer every one the first screen does not need | `wui/nuxt.config.ts`, `wui/src/plugins/*` (order and lazy only) | app mounted 493 → < 300 ms idle; ≈ proportional under load |

Target stays W1 <= 1,500 ms median, now stated on the throttled profile (CPU 4x) on an idle box, n=10. Item 1 is the precondition: without it, T006's after-number would read the box's load, not the change.

<!-- last-edit: 2026-10-08T18:30:00Z — T005 W1 trace, c-581 -->
