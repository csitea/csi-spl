# 066: metrics for the performance users perceive

Status: **owner answered Q1..Q10 on 2026-10-03; Q2, Q6 and Q9 still open**
(section 10). The admin page is IN scope now (owner, Q8). Build lanes:
section 11. Spec only; no code, workflow, gate or `CLAUDE.md` was touched.
Draft 2026-10-03, c-061; answers folded in 2026-10-03, c-066.
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

### 4.0 Fire-and-forget: the collection never slows or breaks the app (owner, Q4)

> "make sure that it does not itself affect the performance of the whole
> application. Use a proper fire-and-forget thing. If for some reason the
> logging doesn't work, it should not mess with the whole thing"

Rules every lane in section 11 tests, not argues:

| side | rule |
|---|---|
| WUI | nothing on a UI path awaits the collector: `perfMark()` pushes into an in-memory ring buffer and returns; it never throws (body wrapped in `try`/`catch`, errors swallowed) |
| WUI | the POST is never awaited by UI code; a failed, slow (> 5 s, `AbortController`) or non-2xx send DROPS that batch: no retry, no queue growth. After 3 failures in a row the tab stops sending until the next load |
| WUI | the ring buffer is capped (500 samples); a full buffer drops the oldest, and counts the drop in the next batch |
| WUI | the collector loads after `onNuxtReady`, not in the initial chunk; if the import fails the app runs exactly as with RUM off |
| hub | `POST /v1/perf/samples` validates, enqueues into a bounded channel and answers 204 BEFORE any database work; a full queue answers 204 and drops, counted |
| hub | one writer goroutine batch-inserts the queue; a store error is logged at most once a minute and the batch is dropped; ingest never holds a connection a member route waits on (its own small pool cap, and a 2 s `context` timeout per insert) |
| hub | no 5xx from the ingest route because of storage, and the WUI shows nothing either way |

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
| (b) an admin view in the WUI | **in scope now** (owner, Q8: "Okay add the whole admin page now."): a `Performance` section in Tenant settings (`/tenant-settings/performance`), behind `tenant.settings` like the other admin sections, reading the same summary route. It shows this workspace's rows: per (metric, device, view) n, p50, p75, p95 ranked by p75, the window (7 / 30 days), a build A / B compare, and n beside every percentile (p95 hidden under n = 50, section 8). The orc action (a) stays: it is how a perf round's plan lane reads the numbers |
| (c) direct SQL on prd | rejected: nothing reads prd ad hoc (owner rule 2026-09-19) |

**How a perf round starts from it.** The round's plan lane runs
`ENV=prd PERF_DAYS=7 ./run -a do_spl_wui_perf_report`, takes the **top 5
(metric, device, view) rows by p75 with n >= 100**, and only then opens the
lab probes to find WHY those are slow. Each round-plan row cites its field
p75 and n. After the round ships, the same action with `PERF_BUILD_A/B` is
the field before / after next to the lab A/B.

## 7. The smallest first step that starts gathering this week (decision 5)

The owner said yes to starting now (Q10). The lanes, their files and their
tests are section 11 (it replaces the P1..P4 table of the draft). Switch-on
order: L1 + L2 deploy (route answers, table empty) -> L4 + L5 + L6 deploy with
RUM on in dev only -> L9 measures -> prd on when L9 passes (Q7). Data flows on
dev the day L6 lands, on prd the day after the A/B. L3, L7 and L8 (summary
route, admin page, orc report) follow once L1 is on master; they can land
before the data does.

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
agent-side latency (`do_spl_latency_probe`) and alerting. The WUI admin page
was listed here as phase 2; the owner moved it into scope on 2026-10-03 (Q8,
section 6 (b), lane L7).

## 10. Owner questions and answers

The questions as asked (draft 02eb00c9):

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

### 10.1 The answers (HUM-10, t1 #spool-hub-ops, topic `6e21c7d8-fda1-40e6-b58f-9c6822748f25`, 2026-10-03, dictated in the car)

Verbatim, in posting order. They are the ten owner posts of that topic between
04:25 and 04:29Z, read from the desk mirror (`ls .../spool/c-001/inbox/*HUM-10*`,
10 files with that task_id); the slot is the answer's place in that order.

| Q | ts (UTC) | msg | verbatim | reading | status |
|---|---|---|---|---|---|
| Q1 | 04:25:11 | `eb408f83` | "On one, do them all." | yes, all of M1..M8 (and M6b `inp`) | **decided** |
| Q2 | 04:25:38 | `4052815b` | "On question 2 I don't understand what you mean. Explain it." | no answer; the owner asks for a plain explanation (10.2) | **open** |
| Q3 | 04:25:55 | `e76bd161` | "On 3, that's kind of a best practice, yes." | yes, p75 ranks, p50 and p95 beside it | **decided** |
| Q4 | 04:26:31 | `0d0deec5` | "4. Definitely yes. But make sure that it does not itself affect the performance of the whole application. Use a proper fire-and-forget thing. If for some reason the logging doesn't work, it should not mess with the whole thing, so some kind of asynchronous fire-and-forget thing" | yes, the dedicated table; PLUS a hard rule: collection is asynchronous fire-and-forget end to end and a broken collector never touches the app (section 4.0) | **decided** |
| Q5 | 04:26:53 | `f8f54729` | "On 5, yes." | yes, 100 % with the 300 / tab / hour cap | **decided** |
| Q6 | 04:27:03 | `769c4eb4` | "On 6, yes." | Q6 was a PICK (30 / 90), not yes / no. Likely "yes to the recommendation" = 30 days; built as 30 days (one constant, `store.PerfSampleRetention`), so 90 is a one-line change | **open** (confirm) |
| Q7 | 04:27:26 | `181aa29b` | "On 7, yes." | yes, prd too, after the 3 % A/B passes on dev | **decided** |
| Q8 | 04:27:44 | `07fabc24` | "Okay add the whole admin page now." | the admin WUI view moves from "later" into THIS build (section 6 (b), lane L7); the orc action stays for the perf rounds | **decided** |
| Q9 | 04:27:57 | `d0b46f58` | "Online, yes." | dictation, most likely "On nine, yes" (it is the ninth answer, between Q8 and Q10). Q9 was a PICK: no (recommended) / yes. A literal "yes" means "add the opt-out"; it may also mean "yes to the recommendation" = no opt-out. Built WITHOUT an opt-out until confirmed; the opt-out would be one more lane (a `tenant.settings` toggle the ingest route reads) | **open** |
| Q10 | 04:28:10 | `8224d24e` | "On 10 years" | dictation of "On 10, yes": start the lanes now, the A/B after | **decided** |

### 10.2 Still open, as the orchestrator asks them

1. **Q2 (explain).** "When you send a message, we want to know how long until
   the OTHER person sees it. Your phone and their laptop have different clocks,
   so we cannot just subtract one time from the other. The plan: your browser
   measures send -> the server confirmed it; their browser measures the server
   time stamp -> the message appeared on their screen, after correcting its
   clock against the server (the error is known, and a sample with more than
   0.25 s of error is thrown away). Two halves, added up in the report. The
   alternative would be to send the message id with each timing so the two
   halves can be joined exactly, but then timings point to specific messages,
   which we want to avoid. OK with two halves and no message ids?" yes / no
2. **Q6.** "Keep raw timings 30 days or 90 days? You answered 'yes'; we read it
   as 30 days (the recommendation)." 30 / 90
3. **Q9.** "Should a workspace be able to switch the timing collection off in
   its settings? You answered 'Online, yes', which we read as 'On nine, yes'.
   Does that mean YES, add the switch, or yes to our recommendation, NO switch
   (the data is anonymous)?" add the switch / no switch

## 11. Build lanes

Small lanes, ONE task each, disjoint files. Each lane runs
`lane-map.sh --check <its files>` first and re-checks the migration number
when it starts. Round 4's W-lanes own `ChannelSidebar.vue`, `default.vue`,
`usePaneWidths.ts`, `useTouchUi.ts` and `useLoopStrip.ts`, which no lane here
touches. Hub paths are under `csi-spl-api/src/go/spool-hub-api/`, WUI paths
under `csi-spl-wui/`.

**The one shared file is `internal/hub/server.go`:** L1 adds one line to the
retention sweep loop (beside `sweepAgentLifecycle`, line 432 today), L2 and L3
one route line each. They land in that order (L2 and L3 after L1), so no two
are open on it at once.

| lane | one task | files (new unless "edit") | its test | after | must NOT touch |
|---|---|---|---|---|---|
| L1 storage + retention | the table, the store (Postgres + memory), and the 30-day prune on the existing sweep | `csi-spl-rdb/src/sql/postgres/spool-hub/0106_wui_perf_samples.sql`; `internal/store/perf_samples.go` (interface, memory, `PerfSampleRetention`); `internal/store/perf_samples_postgres.go`; `internal/hub/perf_retention.go` (`sweepPerfSamples`); one sweep line in `internal/hub/server.go` (edit) | `internal/store/perf_samples_test.go` on POSTGRES (insert batch, RLS by tenant, CHECK on `metric`, prune older than retention, summary query `percentile_cont` p50/p75/p95 + n); `PRE_PUSH_TIER=full ./run -a do_check_pre_push` | - | `human_events`, `flow_events`, `agent_lifecycle*`, `msg/`, any WUI file |
| L2 hub ingest, fire-and-forget | `POST /v1/perf/samples`: validate, bounded queue, 204 before any DB work, one batch writer, drop + count on full queue or store error, rate cap per session, `{"hub_ms"}` in the answer | `internal/hub/perf_ingest.go`; one route line in `internal/hub/server.go` (edit) | `internal/hub/perf_ingest_test.go`: 204 with the store blocked / failing / full queue; no 5xx from storage; tenant and `at` from the session, a body `tenant_id` ignored; rejects unknown metric and PII-shaped fields (section 4.2); member route latency unchanged with ingest saturated | L1 | any WUI file, the store files of L1 |
| L3 hub summary route | `GET /v1/admin/perf/summary?days=&build=&build_b=`, `tenant.settings` permission, the caller's workspace only | `internal/hub/perf_summary.go`; one route line in `internal/hub/server.go` (edit) | `internal/hub/perf_summary_test.go`: 403 without `tenant.settings`; another workspace's rows never returned; p95 omitted under n = 50; build A / B shape | L1 (L2 for the server.go line) | any WUI file, `perf_ingest.go` |
| L4 cnf + build switch | `perf.rum_enabled`, `perf.sample_rate` per env (dev on, prd off until L9), passed to the WUI build | `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` (edit) and their rendered files; `.github/workflows/30_wui-build-deploy.yml` (edit, two `NUXT_PUBLIC_PERF_*` env lines beside `NUXT_PUBLIC_TENANT_HOSTS`); `csi-spl-wui/nuxt.config.ts` (edit, two `runtimeConfig.public` keys) | `ENV=dev ./run -a do_tpl_gen` and `ENV=prd ...`, then `git diff --exit-code`; `pnpm run typecheck`; `./run -a do_check_pre_push_lint` | - | any hub file, any `src/` WUI file |
| L5 WUI collector, fire-and-forget | the pure sampler + ring buffer + batcher + sender (section 4 transport, section 4.0 rules) and the plugin that loads it after `onNuxtReady` when `perfRum` is on | `src/utils/perf-rum.mjs` (`perfMark()`, no Vue import); `src/plugins/perf-rum.client.ts` | `tests/unit/perf-rum.test.mjs`: `perfMark` never throws and returns synchronously; a rejecting / hanging / 500 sender drops the batch with no retry; 3 failures stop the tab; cap 500 drops oldest and counts; 300 / hour cap; `pagehide` beacon; no PII field can be set; `pnpm run typecheck` | L4 | `MessageComposer.vue`, `LiveFeed.vue`, `live-ws.mjs`, `nuxt.config.ts`, any hub file |
| L6 WUI measurement points | M1..M8 wired: one `perfMark()` call each at the composer submit, the feed row paint / `data-pending` clear, the view switch, the `live-ws.mjs` state change; M1 / M2 / M6b / M7 from passive observers in `perf-rum.mjs` (edit, L5 has landed) | `src/components/MessageComposer.vue`, `src/components/LiveFeed.vue`, `src/utils/live-ws.mjs` (edits) | `tests/e2e/perf-rum.test.mjs` on the mock build: each metric appears in the captured batch with the right `device` / `view`, no id or text in any sample; the existing e2e suite green: `BASE_URL=<generated bundle> pnpm run test:e2e` | L5 | the round 4 W-lane files, any hub file |
| L7 admin page | the `Performance` section of Tenant settings (section 6 (b)) | `src/pages/tenant-settings/performance.vue`; `src/utils/tenant-settings-nav.mjs` (edit, one entry, `perm: 'tenant.settings'`); `i18n/locales/*.json` (edit, `tenant_settings.performance*` keys only, all 19 locales); the mock summary in `src/composables/useSpoolApi.ts` (edit, mock branch only) | `tests/unit/tenant-settings.test.mjs` (edit: the section shows only with `tenant.settings`); `tests/e2e/tenant-settings.test.mjs` (edit: the page renders the canned summary, phone and desktop); `pnpm run typecheck` | L3 | `tenant-settings.vue` layout, the other sections, any hub file |
| L8 orc report action | `do_spl_wui_perf_report` (section 6 (a)), read-only, as the env SA | `csi-spl-orc/src/bash/run/spl-wui-perf-report.func.sh` | `csi-spl-orc/src/bash/tests/spl-wui-perf-report.tst.sh`, hermetic on a canned summary JSON; `./run -a do_check_pre_push_lint` | L3 | any WUI or hub file |
| L9 overhead A/B | section 5 on dev, n >= 5 per arm; on a pass, flip `perf.rum_enabled` on for prd (cnf only) | this spec (result as section 12); `csi-spl-cnf/csi-spl/prd.env.yaml` (edit, one key) and its rendered file | the A/B itself; `ENV=prd ./run -a do_tpl_gen` then `git diff --exit-code` | L2, L6 on dev | any code |

Open answers that would add or change a lane: Q9 "add the switch" adds one
lane (a `tenant.settings` toggle in the General section plus the ingest route
reading it). Q6 = 90 days changes one constant in L1. Q2 = no changes L6 and
section 3.1 (a join by message id).
