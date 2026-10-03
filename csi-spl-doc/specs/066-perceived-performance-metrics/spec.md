# 066: metrics for the performance users perceive

Status: **draft for the owner, Q1..Q10 open** (section 10). Spec only; no
code, workflow, gate or `CLAUDE.md` was touched.
Draft 2026-10-03, c-061.
Related: [027 performance](../027-spool-performance/) (the budget gate),
[063 agent context lifecycle](../063-agent-context-lifecycle/) section 12
(the dedicated-table and 3 % logging rule this spec applies by analogy),
[perf round 3 audit](../../doc/md/perf-audit-round3-2026-10-02.md),
[perf round 4 plan](../../doc/md/perf-round-4-plan.md).

## 1. What the owner asked (t1 #spool-hub-ops, topics `3ac11098` and `6e21c7d8`, verbatim)

> "We need to improve the metriv Cs collection on the most important aspects
> on the perceived by the users performance, start gathering the data to be
> almble to do those rounds better on empirical data"

**Reading.** Collect real-user (field) metrics for what people FEEL: the first
load, the time until messages show, send until the message is visible to the
others, switching topic or channel, scroll and typing responsiveness, and the
reconnect after a laptop or phone wakes. On desktop and phone, on dev and prd.
The next perf rounds then rank work by measured user pain instead of by code
reading and lab probes.

## 2. What exists today (measured 2026-10-03 on `origin/master`)

Every claim cites the command that produced it.

| # | fact | command -> result |
|---|---|---|
| 1 | The shipped WUI records NO user timing: no marks, measures, observers, beacons or web-vitals | `grep -rlE 'performance\.(mark\|measure)\|PerformanceObserver\|sendBeacon\|web-vitals' csi-spl-wui/src \| wc -l` -> 0 |
| 2 | The only `performance.now` in shipped code is the pane divider drag | `grep -rlE 'performance\.now' csi-spl-wui/src` -> `src/components/PaneDivider.vue` |
| 3 | The WUI sends no telemetry to the hub; its error journal is in-memory by design ("no network of its own") | `sed -n 1,12p csi-spl-wui/src/composables/errorJournal.mjs` |
| 4 | Five LAB probes time the WUI against a deployed host, each from one scripted account on one box | `ls csi-spl-wui/tests/e2e/perf-*.mjs \| wc -l` -> 5 (`perf-live.proof`, `perf-baseline-live.proof`, `perf-first-load.timing`, `perf-first-load-net.timing`, `perf-flow-events.timing`) |
| 5 | None of those probes runs in CI; they run by hand or through orc actions | `grep -rlE 'perf-(baseline\|live\|first-load\|flow-events)' .github/workflows \| wc -l` -> 0 |
| 6 | CI gates one perf number: the initial JS gzip of a mock build (210 KB ceiling) | `grep -n perf .github/workflows/10_ci-quality.yml` -> line 245 "Initial JS gzip stays within the performance budget" |
| 7 | `do_spl_perf_budget` times three view reads (me, channels, roster) with curl, n=12, plus the bundle; by hand, "CI does not call this action" | `grep '@description' csi-spl-orc/src/bash/run/spl-perf-budget.func.sh` |
| 8 | The hub logs no request timing of its own; server time per route comes from the Cloud Run request log via `do_spl_hub_route_latency` | `grep -rnE 'duration_ms\|latency\|time\.Since' csi-spl-api/src/go/spool-hub-api/internal/hub/*.go \| grep -v _test` -> 1 hit, `wake.go:57` (a backoff, not a timing) |
| 9 | `do_spl_latency_probe` prices the hops of one DM to a desk agent on one box's clock | `grep '@description' csi-spl-orc/src/bash/run/spl-latency-probe.func.sh` |
| 10 | The latest migration is 0105; the two dedicated event tables are `flow_events` (0104) and `agent_lifecycle_events` (0105) | `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| tail -2` |

### 2.1 Which perceived moments are measured today, and with what n

| moment | measured? | where, n |
|---|---|---|
| first load (rail / Flow painted) | lab only | `perf-first-load.timing.mjs` on dev: rail 3.3 s / Flow 5.0 s desktop, n=10 (round 3 audit, line 124); mock fast 4G n=5 |
| time until messages show | lab only | `perf-baseline-live.proof.mjs` "first message", one scripted account |
| send -> visible to the sender | lab only | `perf-baseline-live.proof.mjs` "send": optimistic row and hub-confirmed row (`data-pending` gone) |
| send -> visible to ANOTHER client | **not measured** | `spl-latency-probe` covers member -> desk agent on one box, not member -> member in a browser |
| switch topic / channel | lab only | `perf-live.proof.mjs` "routes", `perf-flow-events.timing.mjs` flow-open, n=10 |
| typing responsiveness | **not measured** | nothing times keydown -> next paint |
| scroll smoothness | **not measured** | nothing counts dropped frames |
| reconnect after sleep | **not measured** | `live-ws.mjs` has the reconnect state machine (`reconnectDelayMs`, line 101), no timing |
| any of the above from REAL users, phone or desktop, prd | **not measured** | fact 1: n = 0 field samples |

Every number we have is from one scripted account, one box, one network,
mostly dev. Real phones, real networks and prd have n = 0.

## 3. The metrics (decision 1)

Every metric is in ms, on ONE clock (the browser's `performance.now()`),
reported as **p50, p75 and p95** per (metric, device, env, build). **p75 is
the ranking number** (the field-metrics convention: the experience of most
people on a bad-ish day, without being one outlier). Each sample carries
`device` = `phone` or `desktop` (the WUI's existing `MOBILE_STACK_QUERY` in
`useMobileStack.ts`, the same switch that picks the phone layout).

The start and end events reuse the DOM states the lab probes already wait on,
so a lab number and a field number of the same metric are comparable.

| id | metric | start | end | notes |
|---|---|---|---|---|
| M1 | `load_rail` | navigation start (`timeOrigin`) | the rail's first tab visible | `cache` = `warm` when the navigation entry's `transferSize` is 0, else `cold` |
| M2 | `load_messages` | navigation start | the first message row (or the empty state) painted in the first view that shows messages | only on loads that land on a message view |
| M3 | `send_ack` | composer submit | the row loses `data-pending` (hub confirmed) | sender's clock; failed sends are counted apart (`outcome=fail`), not as a time |
| M4 | `deliver_visible` | the hub accepted the message (hub ts on the live frame) | that row painted on ANOTHER member's client | see 3.1 |
| M5 | `switch_view` | the click / route change to another topic, channel, DM or Flow | the first message row (or empty state) of the new view painted | `view` = kind only (`topic`, `channel`, `dm`, `flow`, `search`), never an id |
| M6 | `type_next_paint` | `keydown` in the composer | the next frame after the input is handled (`requestAnimationFrame` + `setTimeout 0`) | own probe, works on Safari; Event Timing (INP) is Chromium + Firefox only, so it is recorded as M6b `inp` where available |
| M7 | `scroll_jank` | a scroll burst in the feed starts | it stops (150 ms idle) | value = the longest frame gap in the burst; plus `frames_over_50ms / frames` as a ratio |
| M8 | `reconnect_live` | the page becomes visible again (`visibilitychange`) or `online` fires, with the socket not open | the socket is open AND the catch-up read is done (live state) | only when the tab was hidden > 30 s; `hidden_s` bucket kept |

Send -> visible to others = M3 + M4 (see 3.1). Not one measured number, on
purpose.

### 3.1 How send -> visible on another client is measured

Two machines have two clocks, and a browser clock can be minutes off.

| option | how | verdict |
|---|---|---|
| A. two legs, no join | M3 on the sender (sender clock). M4 on the receiver: hub accept ts -> painted, with the receiver's clock offset to the hub estimated from the beacon round trip (the ingest response carries the hub time; offset from the lowest-RTT exchange, error <= RTT/2, stored with the sample) | **recommended**: no message id leaves the client, the error bound is known and stored |
| B. join by message id | both clients report the message id; the read side joins submit -> painted | rejected: a message id per sample links timings to content, and it still needs the clock offset |
| C. lab only | a two-browser e2e on dev | complementary, not field data; keep `perf-baseline-live` for it |

M4 drops a sample whose offset error is > 250 ms and counts what it dropped,
so a bad clock estimate never becomes a fast or slow number.

## 4. Collection (decision 2)

| choice | options | recommendation |
|---|---|---|
| transport | (a) `navigator.sendBeacon` only; (b) batched `fetch(..., {keepalive:true})` + `sendBeacon` on `pagehide`; (c) over the live WebSocket | **(b)**: one POST per 30 s or 50 samples, whichever first, and a final beacon on `pagehide` / hidden. The API host is cross-origin, so the body is `text/plain` JSON (a CORS-safelisted type, no preflight). Not (c): the socket is the latency path being measured |
| endpoint | a new hub route | `POST /v1/perf/samples`, session-authenticated like every member route; the hub stamps `tenant_id` from the session and `at` itself (the client never sends either); answers `{"hub_ms": <epoch ms>}` for the clock offset; 204 on overload, never an error the UI shows |
| storage | a general log, `human_events`, `flow_events`, a new table | **a DEDICATED table `wui_perf_samples`**, used for this only, as in spec 063 section 12; nothing else reads or writes it |
| sampling | 100 %, per-session %, per-metric % | **100 % of sessions now** (the member count is small and n is what is missing), capped at 300 samples per tab per hour (M6: 1 in 10 keydowns; M7: every scroll burst). A cnf knob `perf.sample_rate` (0..1) lowers it later |
| retention | 30 / 90 days | **30 days raw**, pruned by the hub's existing retention sweep (the one `agent_lifecycle.go` uses) |
| switch | always on, cnf, workspace setting | cnf `perf.rum_enabled` per env (dev on; prd on after the 3 % A/B passes on dev); the WUI reads it at build time as `NUXT_PUBLIC_PERF_RUM` |

### 4.1 The table

`wui_perf_samples`, migration `0106_wui_perf_samples.sql` (the number is
re-checked when the lane starts), append-only, RLS by tenant like 0104 and
0105.

| column | meaning |
|---|---|
| `id` bigserial, `at` timestamptz | hub receive time |
| `tenant_id` | from the session, never from the body |
| `session_id` uuid | random per TAB, held in memory only, never stored in the browser, never tied to the user |
| `metric` | `load_rail`, `load_messages`, `send_ack`, `deliver_visible`, `switch_view`, `type_next_paint`, `inp`, `scroll_jank`, `reconnect_live` (CHECK constraint) |
| `value_ms` integer | the measured time (M7: the longest frame gap) |
| `ratio` real NULL | M7 only: frames over 50 ms / frames |
| `device` | `phone`, `desktop` |
| `view` | kind only: `topic`, `channel`, `dm`, `flow`, `search`, NULL |
| `cache` | `cold`, `warm`, NULL (M1, M2) |
| `outcome` | `ok`, `fail`, `timeout` |
| `build` | the WUI version from `build.json` (before / after per release) |
| `net` | `navigator.connection.effectiveType` where the browser has it, else NULL |
| `clock_err_ms` | M4 only: the offset error bound |
| `hidden_s` | M8 only: bucket `30-300`, `300-3600`, `3600+` |

### 4.2 No personal data

No user id, email, name, IP, user-agent string, URL, query string, topic,
channel, message or issue id, and no message text. The tenant comes from the
session server-side; the session id is a random per-tab value. In any
user-facing text (settings, help, a notice) the word is **workspace**, never
tenant. The privacy page states that anonymous timing data is collected.

## 5. Overhead budget: at most 3 % slower (decision 3)

The owner's spec 063 rule ("logging must not decrease performance more than
3%") applies by analogy. Measured, not argued: an interleaved A/B with
`NUXT_PUBLIC_PERF_RUM=0` vs `1` on dev, **n >= 5 per arm**, medians compared.

| what | probe (exists) | arms | pass |
|---|---|---|---|
| first load | `perf-first-load.timing.mjs` rail + flow, desktop and phone profile | RUM off / on | each median within 3 % |
| send and switch | `perf-baseline-live.proof.mjs` send + open | off / on | each median within 3 % |
| main thread | the same probes' TBT and longest task | off / on | within 3 % |
| initial JS | `perf-budget.py bundle` (CI's own number) | off / on | the collector is NOT in the initial chunk (imported after `onNuxtReady`); initial gzip grows < 0.5 KB |
| hub | `do_spl_hub_route_latency` p50 / p95 of the send and view routes, 6 h window before and after the ingest route ships | before / after | within 3 %; the ingest route is rate-capped per session |

The collector itself: observers are passive, the batch is serialised on idle
(`requestIdleCallback`, fallback `setTimeout`), and nothing measured adds a
forced layout (no new `getBoundingClientRect` on a hot path).

## 6. How the data is read (decision 4)

| option | verdict |
|---|---|
| (a) an orc query action | **recommended first**: `do_spl_wui_perf_report` in `csi-spl-orc`, read-only, as the env SA, through a hub admin route (`GET /v1/admin/perf/summary?days=&build=`) that runs `percentile_cont` server-side. Prints per (metric, device, view) n, p50, p75, p95, ranked by p75; `PERF_BUILD_A` / `PERF_BUILD_B` print a before / after of two builds |
| (b) an admin view in the WUI | later: the same summary route behind the admin role, once the numbers are trusted |
| (c) direct SQL on prd | rejected: nothing reads prd ad hoc (owner rule 2026-09-19) |

**How a perf round starts from it.** The round's plan lane runs
`ENV=prd PERF_DAYS=7 ./run -a do_spl_wui_perf_report`, takes the **top 5
(metric, device, view) rows by p75 with n >= 100**, and only then opens the
lab probes to find WHY those are slow. Each round-plan row cites its field
p75 and n. After the round ships, the same action with `PERF_BUILD_A/B` is
the field before / after next to the lab A/B.

## 7. The smallest first step that starts gathering this week (decision 5)

Three lanes start in parallel the moment the owner approves, each against the
contract in sections 4 and 6; a fourth runs the A/B once two have landed.
Each lane runs `lane-map.sh --check <its files>` first; round 4's W-lanes own
`ChannelSidebar.vue`, `default.vue`, `usePaneWidths.ts`, `useTouchUi.ts` and
`useLoopStrip.ts`, which no lane here touches.

| lane | scope | files (new unless marked) | must NOT touch |
|---|---|---|---|
| P1 rdb + hub ingest | migration, store (Postgres + memory), `POST /v1/perf/samples`, `GET /v1/admin/perf/summary`, 30-day prune, rate cap, tests on Postgres | `csi-spl-rdb/src/sql/postgres/spool-hub/0106_wui_perf_samples.sql`, `internal/store/perf_samples*.go`, `internal/hub/perf_samples.go` (+ `_test.go`), one route line each in `internal/hub/server.go` (edit) | `human_events`, `flow_events`, `agent_lifecycle*`, `msg/`, any WUI file |
| P2 WUI collector | the pure sampler + batcher, the plugin, and the measurement points M1..M8 | `csi-spl-wui/src/utils/perf-rum.mjs` (+ `tests/unit/perf-rum.test.mjs`), `src/plugins/perf-rum.client.ts`; one `perfMark()` call each in the composer submit, the feed row render and the `live-ws.mjs` state change (edits) | the round 4 W-lane files above, `nuxt.config.ts`, any hub file |
| P3 read action | the report action and its hermetic test (a canned summary JSON) | `csi-spl-orc/src/bash/run/spl-wui-perf-report.func.sh`, `csi-spl-orc/src/bash/tests/spl-wui-perf-report.tst.sh` | any WUI or hub file |
| P4 overhead A/B (after P1 + P2 are on dev) | section 5, n >= 5 per arm, result appended to this spec as section 11 | this spec only | any code |

Switch-on order: P1 deploys (route answers, table empty) -> P2 deploys with
RUM on in dev only -> P4 measures -> prd on when P4 passes. Data flows on dev
the day P2 lands, on prd the day after the A/B.

## 8. Risks

- **Small n.** A workspace with a few members gives a few hundred samples a
  week. The report prints n beside every percentile and hides a p95 under
  n = 50.
- **Safari** has no Event Timing, no Long Tasks and no `connection`: M6 is our
  own probe for that reason; `inp` and `net` are NULL there.
- **Background tabs** throttle timers: a sample whose span crossed a hidden
  period is dropped (`document.visibilityState` checked at start and end).
- **Clock offset** (M4): bounded and stored, see 3.1.
- **The collector becoming the slowness**: section 5's gate, and the cap.

## 9. Not in scope

Hub CPU / DB metrics (Cloud Run and `do_spl_hub_route_latency` have them),
agent-side latency (`do_spl_latency_probe`), alerting, and a WUI admin page
(phase 2).

## 10. Owner questions

1. **Q1** The metric set M1..M8 (section 3) as the first set? yes / no
2. **Q2** Send -> visible to others as two legs with a bounded clock offset (option A), not a join by message id? yes / no
3. **Q3** p75 as the ranking number, p50 and p95 reported beside it? yes / no
4. **Q4** A dedicated table `wui_perf_samples`, nothing else in it? yes / no
5. **Q5** Sampling: 100 % of sessions with a 300 samples / tab / hour cap? yes / no
6. **Q6** Retention: pick 30 days (recommended) / 90 days
7. **Q7** Collect on prd too, switched on only after the 3 % A/B passes on dev? yes / no
8. **Q8** Read first through the orc action (an admin WUI view later)? yes / no
9. **Q9** A per-workspace opt-out in workspace settings? pick: no (recommended, the data is anonymous) / yes
10. **Q10** Start lanes P1, P2 and P3 now, P4 after? yes / no
