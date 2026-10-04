# Performance edition 20261004: 30 measured improvements, end to end (plan, 2026-10-04)

Owner, prd t1 topic `7d7e86a9`: "performance improvements - edition 20261004." / "Basically check the best practices from the previously archived and conducted performance improvements ... Pick 30 performance improvements and implement as much as possibly based on empirical evidence" / "A yes" (measure first, one lane per fix, before/after numbers each). Scope addition (same topic): "well add the scope to be e2e - aka investigate backend , db problems as well .."

This lane plans and measures. It changes no product code. Each row in section 3 is one lane with its own brief in `perf-edition-20261004-briefs/<id>.md`. The rows cover the whole path: the browser (WUI), the hub API and its WebSocket fan-out, the live database, and the CI/bash tooling that every change goes through. Sources: round 3 (`perf-audit-round3-2026-10-02.md`), the DB payload rounds (`db-payload-audit-round2-2026-10-02.md`), round 4 (`perf-round-4-plan.md` and its commits on master), specs `027-spool-performance` (budgets) and `066-perceived-performance-metrics`. Open choices were decided by the evidence-backed default, written down here; the owner asked for no more questions.

## 0. Lessons from round 4: which practices paid off

Round 4 planned 30 practices x 2 sites (`3616013c`). 26 practices landed, 4 never started: their lanes hit a usage limit on 2026-10-03 and were not resumed (W7, W1, W8, W11). "Now" is a re-measurement on trunk `751ccd61` (v8.9.8), 2026-10-04 19:00..22:30Z, by the methods of section 2.

| practice (r4 id) | gain measured when it landed (n) | now on `751ccd61` (n) | held? | lesson |
|---|---|---|---|---|
| Split one long serial CI job (C4) | wf11 e2e 3 shards; shellcheck one parallel pass 210 -> 38 s local (n=1 of 5) | wf11 wall = slowest shard 856 s vs 1 656 s (n=20); wf67 step 33.5 s vs 110 s (n=20) | **yes** | shards are uneven (856 vs 682 s): split by measured time, not round-robin (row E10) |
| Parallel test files (C2) | orc + iac worker pool | wf10 orc step 266 s vs 816 s; iac 63.5 s vs ~105 s (n=20) | **yes** | the pool exposed 3 latent pipefail/SIGPIPE races (`cd8a0929`, `6eeec759`, `980ea596`); the orc floor is now one excluded file (orch-rotate, >= 150 s) |
| No fork per item in a bash loop (C1) | orc `./run` 1 215 -> 294 ms, iac 545 -> 161 ms (n=12) | orc 568 ms, iac 272 ms (n=10, load 4.8); clones 71 -> 143, 39 of 61 execs are `do_log`'s cut/date/mkdir | **partly eroded** | orc now loads 253 action files (217 functions at r4) and every log line forks 6..7 times: half the gain came back: row E18 |
| Overlap build with the test gate (C6) | WUI commit-to-live 162 -> 102 s; hub 455 -> 431 s (lane report, n=5..9) | WUI 146 / 145 s dev / prd (n=20); hub 489.5 / 493.5 s (n=12) | WUI **yes**; hub **lost** | the hub suite grew 304 -> 357 s and is the critical path again: row E05. The version prediction needed 4 candidates (`73706a65`) and a setup-go fix (`cdc3c9d7`) |
| Build once, cache layers (C5) | wf10 generate once: -105 runner-s per push (n=5); wf50 buildx cache **dropped**: bake 119 s vs 101.5 s (n=5/12) | wf10 ~195 -> ~104 runner-s (n=20); wf50 111 s (n=20) | **yes** (site 2) | a layer cache cannot help when every sha invalidates the layers (version ARG + `.git` COPY) |
| Cache pinned tool installs (C3) | checkov / semgrep venvs cached | install 5 s vs 32 s; 3 s vs 20 s (n=16..20) | **yes** | cheap, safe, durable |
| Warm the CDN edge after a deploy (C7) | first-reader TTFB doc 365 -> 162 ms, `/_nuxt` 315 -> 155 ms dev; HIT 140/140 vs 0/140 (n=70 per arm per env) | wf31 runs per deploy (n=2 in the window) | yes | only proves this box's POP; the runner's POP was already warm |
| Kill N+1 query loops (G2) | tenant/channels 32 -> 4 RT at 13 channels; locate 9 -> 2 at 8 tenants (n=5) | 4 flat; 2 flat (n=5) | **yes** | the biggest RT win per line of code; new N+1 found in archived cards (row E09) |
| Memoise a repeated read in one request (G1) | channel_humans reads move 4 -> 2, merge 5 -> 2; RT -1..-3 (n=5) | channel_humans reads 1/1/1/1/2/2 (n=5) | **yes** | the same shape repeats for the membership read: 5 per write route (row E07) |
| Batch a write tx with `pgx.Batch` (G3) | MergeTopic 12 -> 7 RT; CreateIssue 6/8 -> 2 (n=5) | 7; 2 (n=5) | **yes** | |
| One CTE, not lock -> read -> update (G5) | move 50 -> 36, promote 32 -> 26 RT (n=5) | see note | yes | write-route totals moved +2..4 since (kind 10, reaction 12, archive 18, move 27, merge 30; promote 20), n=5: other lanes added reads; re-measure before quoting |
| Read-only multi-read as one tenant batch (G4) | kind 20 -> 15, archive 22 -> 14 RT (n=5) | held in the door rig (n=5) | yes | still 7 read-only GETs wrapped in BEGIN..COMMIT (rows E20, E09) |
| RETURNING instead of a re-read (G6) | kind 15 -> 8, reaction 13 -> 10 RT (n=5) | kind 8, reaction 9 (door rig, n=5) | **yes** | the concurrency control (`TestSetKindConcurrentRegisterDense`) caught a wrong fold |
| Pipeline independent reads (G7) | topics/{id}, topics?dm 3 -> 2 RT (n=5 x 3) | 2 / 2 (n=5) | **yes** | |
| No decode -> map -> re-encode (G9) | trimEnv 88 -> 1 alloc, 5x; Canonical 3x (n=6, fuzz vs the old function) | 1 alloc; ratios 4.3x / 2.4..2.8x under load 40..75 (n=6) | **yes** | golden + fuzz against the old function made a signature-contract change safe; `trimWUIEnv` has the same shape (row E13) |
| Encode a fan-out frame once (G8) | fanoutWUI 300.8 -> 252.2 us, 508 -> 383 allocs (n=6) | 382 allocs (n=6) | yes, **smaller than planned** | expected /N, got -16 %: the per-socket write dominates; 6 more fan-outs still encode per socket (row E16) |
| Typed structs for hot frames (G12) | presence 500 -> 11 allocs, edited 338 -> 11 (n=6) | same allocs (n=6) | **yes** | |
| Pool per-request buffers (G10) | ETagView 133 KB 139 512 -> 227 B/op (n=6); site 2 **dropped** (wsjson already pools) | 228 B/op (n=6) | **yes** | |
| Cacheable answers get validators (G11) | flow ETag kept; plan `max-age=300` **dropped**: hosting's `**` header rule overrides the hub (TTFB 126 vs 121 ms, n=10) | - | half | measure through the real path (hosting rewrite), not the origin |
| Canvas text measure, no DOM probe (W4) | max diff 0.015 px over 92 checks | phone 0 ms; **desktop still 1 forced layout 125.9 ms** at `tenant-switcher.mjs:205` (n=5) | phone yes, desktop no | row E14 |
| No forced layout at mount (W3) | /issues usePaneWidths 82.4 -> 0 ms (n=7 x 2); site 2 **dropped** (ResizeObserver variant raised layout 299 -> 520 ms) | 0 forced layouts from usePaneWidths (n=5+5) | **yes** | one revert (`56d51be9`) was a misread flake: re-land needed an interleaved n=3 green proof. useLoopStrip is now the #1 phone frame (row E06) |
| Shared passive rAF viewport source (W5) | apply 101.9 -> 32.9 ms; listeners 4 -> 1 (n=5) | apply 0..0.6 ms; 1 non-passive left (usePaneWidths) (n=5; n=20 rows) | **yes** | row E28 takes the last one |
| Intl objects once (W2) | 500-row sort x33, formatPrice x11.6 (n=15) | no per-call Intl on a hot path (grep) | **yes** | the remaining ICU cost is the first collator INIT, not reuse (row E12) |
| v-if for closed UI (W6) | phone body 640 -> 587 elements, -1 chunk request (n=3) | phone body 622 (+35 since, n=10); 283 hidden elements on phone / | yes, eroded by new UI | new closed lists keep arriving (rows E08, E27) |
| SW app shell (W9) / root locale at the edge (W10) | W10: fi rail -273 ms, 2 -> 1 documents (n=6); W9 correctness proven (n=3 swaps) | both in code; not timed (self-signed origin) | yes (W10) | W9's gain was never timed on a deployed host |
| Phone first long task (W7), ICU off first screen (W1), defer plugins (W8), lazy helpers (W11) | never landed | W7: longest 716 ms, main 120/120 hidden (n=5/n=10); W1: 49.3 ms (n=5); W8: 0 bytes can leave initial (5 static importers); W11: 2.8 KB gz (n=1 build) | open | W7, W1, W11 are rows E08, E12, E29; W8 goes to section 5 |

What paid off most per hour of lane time, in order: **round-trip removal on the DB path** (N+1, batch, CTE, RETURNING, pipelining: every row held, n=5, deterministic), **CI parallelism** (C2, C4: minutes per push), **one-pass encoders with a golden + fuzz guard** (G9), **removing forced layouts at mount** (W3, W5). What did not: caches that the real path overrides (G11 plan, C5 wf50), and a predicted /N gain that a bench of the whole path would have shown as -16 % (G8).

**The biggest gap round 4 never looked at was the live database.** Every r4 DB number came from a private Postgres behind a counting proxy. The live read in section 2.4 shows that one background sweep holds 28.4 % of prd DB time, and one PUT route deadlocks 47 times a day. Neither can be seen in a round-trip count.

## 1. Rules for every lane

- Measured on trunk `751ccd61` (v8.9.8). Every site carries its cost now, with n. Before the change, re-measure on your rebased trunk with the row's method; a change that shows no gain is dropped and reported, never shipped.
- The 30 rows' files are pairwise disjoint and off every live lane at planning time (`lane-map.sh --check` on all 49 paths: rc 3 only for `.github/workflows/20_hub-build-deploy.yml`, held by c-221@sat, which is therefore not in the plan). Off migrations, `msg/msg.go`, `store/fleet_*.go` and the rotation/lease/spawn/desk scripts. A lane touches only its row's files plus new test files beside them.
- One commit per site, with before/after and n in the message.
- Live DB and hub rows prove the gain on dev AND prd with the same read-only action before and after the roll (section 2.4). Lab ratios (proxy RT, bench) are the gate before the push; the live number is the result.
- Done means: on master through the pre-push gate; hub or WUI runtime changes deployed to dev AND prd with the served version checked (hub `/version`, WUI `build.json`); before/after numbers with n; report to the orchestrator on task `7d7e86a9-078f-4c8a-9a44-d6e18d2db2f7`.
- GCP: per-environment service-account keys only, never the owner account. Live measurements are read-only.
- Box: `satellite` = the satellite box (Chrome, lower load: WUI timing rows); `main` = the main box (it holds both env SA keys, so live before/after reads run there; also the ssh-to-satellite row); `either`.

## 2. How it was measured

### 2.1 Hub (lab)

`go test -bench -benchmem -count=6` (median; B/op and allocs/op are exact, ns/op is 2..4x high under box load 26..75). DB round trips through the counting pgProxy of `onsend_bench_test.go` against a private postgres:16-alpine with a non-superuser owner (RLS on), n=5: the committed `TestRoundTripsPerRequest`, `TestChannelHumansReadOncePerRequest` (MEMO_RT_N=5), `TestWriteBatchRoundTrips`, `TestNPlus1RoundTrips*`, plus a throwaway door rig (a prod-like session door, one member) for the routes those tests do not cover, and one `log_statement=all` sample per route to name the statements. The rig is not committed; each lane adds the route it changes to `TestRoundTripsPerRequest` or a new test beside its file.

### 2.2 WUI (lab)

A mock `nuxt generate` with sourcemaps (`NUXT_PUBLIC_USE_MOCK=1 NUXT_CLIENT_SOURCEMAP=true`), served by `tests/e2e/lib/serve-hosting-h2.mjs` (h2, Hosting's headers), driven by puppeteer-core with the round-3 harness (`perf-audit-round3-2026-10-02.harness.txt`: `mk.mjs`, `prof.mjs`, `crit.mjs`, `attr.cjs`) and three additions: per-path interleaved timings with hidden-element and non-passive-listener counts, median-per-frame profiles, and a forced-layout census from a Chrome trace (Layout / UpdateLayoutTree events that carry a JS stack, sourcemapped). m390 = 390x844 DPR 3 at CPU 4x; d1440 = desktop, no throttle. n=5 per cell interleaved. Box load 10..59 (recorded per batch): **quote ratios and deterministic counts** (DOM, listeners, forced-layout count), not absolute ms. The live-config build's 3 initial chunks were byte-identical to the mock's, so bundle bytes hold for both. Node micro-benches n=12 in fresh processes.

Sourcemap traps, verified against the minified code: frames mapped to `utils/topic-in.mjs:144` are `MessageComposer.vue` (dock rect and `innerHeight`), frames mapped to `utils/flow-keys.mjs:52` are SFC setups (mainly ChannelSidebar).

### 2.3 CI and bash

`gh api` job and step durations of the last 20 successful master runs per workflow (pulled 2026-10-04 ~21:40Z; per-row run-id ranges in the briefs). Commit-to-live = run `created_at` -> deploy job `completed_at`, only runs that rolled. Per-piece times of the hub suite from 3 job logs (`== <piece> ==` timestamps). Local `time` n=10 and `strace -f -c` at load < 5 (load is noted per number; the CI-lane batch at load 43..103 was discarded).

### 2.4 Live hub and DB (new this round, read-only, as the env SA)

| layer | how | window |
|---|---|---|
| hub routes | `do_spl_hub_route_latency` (server time from the Cloud Run request log: n, p50/p95/max, KB, 4xx/5xx per route) | prd 24 h = 141 834 requests; dev 7 d = 65 009 |
| Cloud Run | Monitoring v3: CPU and memory utilisation, instance count, startup latency, concurrency | 24 h and 7 d, both envs |
| DB statements | Query Insights (`do_spl_db_insights` and the per-query Monitoring series): total time, calls, mean per statement hash | prd 24 h = 1 584 s DB time over 2.83 M calls |
| DB health | `do_spl_db_health`; `do_spl_db_query` on `pg_stat_user_tables` / `_indexes` / `pg_stat_database` / `pg_settings` | counters since 2026-09-18 |
| plans | `EXPLAIN (ANALYZE, BUFFERS)` in the action's read-only rolled-back transaction on prd t1 (the tenant with 16 774 of 19 847 messages), n=3 each | 2026-10-04 19:02..19:30Z |

Live images: spool-hub 8.9.6 on both envs. Headline facts the rows below build on:

- **Neither compute layer is saturated.** Hub CPU per-minute p99 peaks at 0.04 (prd 24 h) and 0.11 (7 d); memory p99 <= 0.25. Cloud SQL (db-f1-micro) CPU p50 0.13, max 0.61 (7 d); 138 MB, cache hit 100.00 %; backends p95 12, max 21 of 25. So the wins are **less DB time per request and fewer requests**, not bigger machines.
- **prd DB time, 24 h, by statement:** read_marks sweep 28.4 % (n=138, mean 3 258 ms), flow counts 18.9 % (n=8 413 x 35.5 ms), the two channels read-mark CTEs 11.0 % + 8.3 % (n=6 987 each), unanswered sweep 4.7 %, read_marks upsert 4.5 %, channel counts 3.8 %, recursive topic walk ~3.5 %.
- **prd routes, 24 h, by total server time:** GET /v1/view/channels (n=6 979, p50 65 ms), PUT /v1/me/reads (n=8 784, p50 21.5 ms, **47 x 500**, p50 reply 15.7 KB), GET /v1/pins, GET /v1/view/topics (p95 342 ms).
- **pg_stat_database prd:** deadlocks 47, temp_files 614 / 4.2 GB since 2026-09-18.
- The 7-day Insights ranking is stale (its top entry, the old walk shape, has had no calls since 2026-10-02). Plan from the 24 h ranking.
<!-- sections 3-5 follow in the next commit -->
