# API (hub) performance round: measured baseline and v0.1 proposal (2026-10-06)

Owner HUM-10, prd t1 topic `ea9dc09a-9030-4177-ba94-22a3df3b89af`, verbatim, in order:

1. msg 857e077a: "api related performance improvement refactoring round"
2. msg 04f74475: "Debated needed between 2 claude , 2 agy and 2 grok agents , now achieving the maximum benefits in speed via 10 commits ( small ones )"
3. msg eccc528a: "than based on the consensus thouse should be executed with 2 agents per box ( [main box] and sat )" (box name redacted: the hygiene sweep bans it)
4. msg 6a16e1fd: "I would like to review them first as well ... even they might be just over my competence ..."
5. msg bca448c9: "yes - agy is traitor ... no can do ... money is not indefinitely available .." (so the panel is 2 claude + 4 grok)

**What this doc is:** the measured baseline, plus a v0.1 list of every candidate row, ordered by measured gain. The panel (c-001 seats it) picks the 10 small commits from it, and the owner reviews those 10 before the build. Each row says in one plain sentence what changes and why, so it can be reviewed without reading SQL. This lane changes no product code.

**Basis:** trunk `929edfa3e`. Live hub revisions, from the request log: prd `csi-spl-hub-prd-00451..`, dev `csi-spl-hub-dev-00441..00444`. Row slug **`ap-NN`**. Status is generated, never hand-kept: `git log origin/master --grep='ap-[0-9][0-9]'` plus the served `/version`.

## 1. Answer

1. **The API's time is in a few SQL statements, not in the hub process.** On prd the DB spent **2 290 s in 24 h**:
   - **40.4 %** is one statement builder: the Flow unread counts, recomputed on every read-mark PUT and every new line (n=11 229 x 77 ms + n=680 x 87 ms).
   - **26.3 %** is the channel list's three unread statements (n=11 734 each).
   - **10.5 %** is the topic walks. They are the slowest thing a user waits for: **p50 150..350 ms, p95 0.5..1.5 s** per list (n=446 in 8.4 h).
2. **Where the time goes, from prd plans (read-only, n=3):**
   - **Flow counts** probe the messages table and read_marks **once per Flow event the member ever got**: ~3 530 events for HUM-10, almost all already read. That is O(all events), not O(unread).
   - **Channels** expand all **4 849 archived lines** on every call, then drop every one of them for a reader whose marks cover each channel (HUM-10: 0 rows out, 25..36 ms). The counts statement visits the heap for 3 691 of its 6 917 index-only rows, because the visibility map lags.
   - **Walks** visit ~45 messages per listed topic (2 301 for 51 DM topics). Each candidate step rescans all ~370 archived cards, because the archived check is an OR that cannot use its index.
3. **Three text rewrites were A/B-tested on prd and none is a gain.** Two returned identical results (md5); the third did not:
   - Flow counts driven from the member's events: 74.2 / 77.4 / 101.4 ms.
   - Flow counts with an index-only message join: 71.0 / 90.2 / 68.5 ms, and its result **differs on prd** (unsafe).
   - Both sit at the hub's own Insights mean (77 ms). The 127..990 ms Seq Scan plan seen first is the operator scope's plan, not the hub's.
   - Walk with the archived OR split in two: **5 584 / 7 270 / 5 900 ms against 114..286 ms**. The planner fell into the bitmap-scan trap the hub turns off.

   So the Flow-counts win needs a structural change (ap-01), and a walk change can only be judged under the hub's own planner settings (ap-00 first).
4. **The hub process is not the bottleneck.** Route time minus DB time is a few ms per route (round 2: 1..3 ms). At the snapshot: 9 of 25 backends in use, 0 lock waits, no new deadlocks since E02.
5. **One tool gap blocks honest walk proofs.** `do_spl_db_hot_measure` keeps a copy of the walk text frozen at SPL-984. On prd it reads walk_dm **22.0 ms p50 (n=20)**. The store's current statement takes **114..286 ms (n=3)** on the same tenant and reader, and Insights says **456 ms mean (n=245)**. Row ap-00 fixes the tool.

## 2. How it was measured

| layer | command (read-only, from `csi-spl-orc`, env SA) | window, n |
|---|---|---|
| hub routes | `ENV=<env> ROUTE_HOURS=24 ROUTE_TOP=40 [ROUTE_QUERY=1] ./run -a do_spl_hub_route_latency` | prd: the default 50 000-entry limit cut it to **8.4 h** (02:53..11:15Z); dev 24 h, 17 274 entries |
| DB statements | `ENV=<env> INSIGHTS_HOURS=24 INSIGHTS_TOP=25 ./run -a do_spl_db_insights` | prd 24 h: 62 statements, 2.25 M calls, 2 290 s; dev 24 h: 43 statements, 87 s |
| DB load | `ENV=prd SECTION=load ./run -a do_spl_db_health` | one snapshot, 11:15Z |
| plans | `EXPLAIN (ANALYZE, BUFFERS)` of the **store's own statement text** via `do_spl_db_query`, n=3 | prd t1, reader HUM-10; dev t1, reader HUM-9 (406 DM topics) |
| A/B | the same statement rewritten, same n, plus a result md5 of old vs new | prd and dev |
| hot path | `ENV=<env> TENANT_ID=t1 READER=<hum> MEASURE_N=20 MEASURE_JIT=off MEASURE_ONLY=walk_dm,walk_all,channels ./run -a do_spl_db_hot_measure` | n=20 (stale text, see 1.5) |

- c-001 ran the prd reads (a lane cannot read prd), 11:15..12:05Z, in four rounds. The texts were printed with literals for t1 and the reader by the store's own builders (`viewTopicsSQL`, `flowCountsSQL`, `countsRead`, `hiddenUnreadRead`, `markedUnreadRead`), through a throwaway Go test that was not committed. ap-00 makes that a committed tool.
- **Caveat:** `do_spl_db_query` runs in the operator RLS scope with the default planner settings. The hub runs a walk under the tenant scope, with `jit`, `enable_bitmapscan` and `enable_sort` off and `force_custom_plan`. Two of the four plans differed from the hub's (Flow counts, the walk rewrite). The **proof of every row is the hub's own number**: the Insights mean of its statement and the route p50/p95, before and after the roll.
- `pg_stat_statements` is not installed on prd (`do_spl_db_health`: installed f, available t). Insights is the per-statement source.
- Data at measurement:
  - prd t1: 21 921 live messages, 4 994 flow_events (HUM-10: ~3 590), 1 006 read_marks, 388 archived cards.
  - dev t1: 13 026 messages, 12 649 of them DMs in 504 topics.

## 3. Baseline

### 3.1 prd routes by total server time (8.4 h)

| route | n | p50 ms | p95 ms | max ms | 5xx | p50 KB | p95 KB |
|---|---|---|---|---|---|---|---|
| GET /v1/view/channels | 4 670 | 40.5 | 120.0 | 6 639 | 0 | 1.7 | 1.8 |
| GET /v1/view/topics (all shapes) | 446 | 149.7 | 736.7 | 1 638 | 0 | 4.9 | 44.7 |
| PUT /v1/me/reads | 4 817 | 12.4 | 29.8 | 425 | 0 | 0.4 | 0.5 |
| GET /v1/pins (box probe) | 14 348 | 2.7 | 5.4 | 13 439 | 0 | 0.5 | 0.8 |
| POST /api/v1/auth/login | 166 | 122.6 | 185.2 | 302 | 0 | 1.0 | 1.0 |
| GET /v1/view/flow | 108 | 75.4 | 510.1 | 913 | 0 | 0.5 | 5.3 |
| GET /v1/view/topics/{id} | 652 | 16.9 | 57.0 | 298 | 0 | 1.4 | 14.7 |
| GET /v1/view/roster | 455 | 16.1 | 59.7 | 1 305 | 0 | 2.9 | 8.1 |
| GET /v1/view/search | 5 | 2 031.6 | 2 607.8 | 2 608 | 4 | 2.5 | 2.5 |
| GET /v1/files/{hash} | 147 | 52.7 | 134.5 | 344 | 0 | 5.8 | 392.5 |

The topics route split by query shape (`ROUTE_QUERY=1`, same window):

| shape | what the WUI uses it for | n | p50 ms | p95 ms | p50 KB |
|---|---|---|---|---|---|
| `limit=50` | Flow / home topic list | 65 | **303.9** | 836.9 | 4.9 |
| `channel=<c>&limit=20&per_topic=30` (spool-hub-devel) | channel page | 60 | **212.7** | 848.1 | 44.4 |
| `dm=true&dm_counts=true&dm_read=...` | DM seed, first screen | 55 | **268.8** | 538.5 | 4.6 |
| `dm=true&dm_counts=true&dm_read=..&limit=50` | DM seed | 23 | **353.5** | 1 502.0 | 0.7 |
| `dm=true&limit=20&peer=<agent>&per_topic=30` | one DM conversation | 9 | **608.4** | 1 414.3 | 15.0 |
| `channel=lobby&limit=20&per_topic=30` | lobby | 43 | 83.6 | 325.5 | 10.8 |

- **Per signed-in screen load**, the WUI calls session, me, channels, roster, the DM seed and the Flow list (round 2: 11 DB round trips, ~5.8 KB gzip). Of those, the **DM seed and the Flow list take hundreds of ms** on prd.
- **Per minute of normal use**, each tab PUTs its read marks every 5 s while a cursor moves (`PUSH_MS`, `csi-spl-wui/src/utils/read-sync.mjs:19`). prd shows **one channels GET per PUT** (4 670 vs 4 817). The cause is unknown (row ap-06).
- **WebSockets:** `/v1/ws` (boxes) n=11 429 upgrades in 8.4 h, 715 refused; `/v1/wui/ws` (browsers) n=84.
- The search 503 (`search_budget`) belongs to lane c-389 and counts here only as an input.

### 3.2 prd DB time by statement (Insights, 24 h, 2 290 s)

| # | statement (store builder) | calls | mean ms | total s | share |
|---|---|---|---|---|---|
| 1 | Flow counts `WITH fc AS` (`flowCountsSQL` via `FlowRead`: GET /v1/view/flow and the read-mark wake) | 11 229 | 77.08 | 865.5 | **37.8 %** |
| 2 | channels hidden-unread (`hiddenUnreadRead`) | 11 734 | 26.29 | 308.4 | **13.5 %** |
| 3 | channels counts (`countsRead`) | 11 734 | 21.83 | 256.2 | **11.2 %** |
| 4 | DM walk (`viewTopicsSQL`, dm=true) | 245 | 456.54 | 111.9 | 4.9 % |
| 5 | all-topics walk (`viewTopicsSQL`) | 139 | 541.32 | 75.2 | 3.3 % |
| 6 | unanswered sweep (orc cron; E17 landed) | 133 + 40 | 451.7 / 415.9 | 76.7 | 3.3 % |
| 7 | Flow fan-out per new line (`FlowFanout`, embeds `flowCountsSQL` per member) | 680 | 86.97 | 59.1 | 2.6 % |
| 8 | channel walk (`viewTopicsSQL`, channel=) | 453 | 116.84 | 52.9 | 2.3 % |
| 9 | message insert `WITH ins AS (INSERT ..)` (two shapes) | 590 + 247 | 46.06 / 85.53 | 48.3 | 2.1 % |
| 10 | `INSERT INTO boxes .. last_hello_at` (each box hello) | 70 648 | 0.63 | 44.2 | 1.9 % |
| 11 | channels marked-unread (`markedUnreadRead`) | 11 734 | 3.24 | 38.0 | 1.7 % |
| 12 | read-marks upsert | 9 062 | 3.64 | 33.0 | 1.4 % |

- Rows 1 + 7 = **40.4 %**, rows 2 + 3 + 11 = **26.3 %**, rows 4 + 5 + 8 = **10.5 %**.
- **Trend:** the perf edition of 2026-10-04 (same method) had the Flow counts at 8 413 x 35.5 ms. Now they are **11 229 x 77.1 ms: 2.9x the DB time in two days**. The read_marks sweep (E01, 28.4 % then) is out of the 24 h top 25.

### 3.3 prd plans (operator scope, t1 / HUM-10, n=3)

| statement | execution ms | buffers | what the plan does |
|---|---|---|---|
| Flow counts, as the store sends it | 182.5 / 990.3 / 127.0 | 65 453 | Seq Scan on messages (18 861 rows) + one `flow_events_msg` probe per message. **The operator scope's plan, not the hub's** (see 3.4) |
| Flow counts, driven from the member's events (A/B `-b`) | 74.2 / 77.4 / 101.4 | | 3 592 flow_events -> 3 592 `f:` mark probes + 3 532 message probes (0.014 ms each) + 3 532 place-mark probes -> 0..4 rows |
| channels hidden-unread | 24.5 / 36.0 / 27.8 | 7 916 | 388 archived cards -> 4-arm UNION -> **4 849 lines** -> anti-join with the reader's 12 marks -> **0 rows** |
| channels counts | 21.9 / 17.1 / 21.5 | 2 010 | Index Only Scan `messages_channel_stats`, 6 917 rows, **Heap Fetches 3 691** |
| channels marked-unread | 1.8 / 1.5 / 2.2 | 105 | fine |
| DM walk, as the store sends it | 286.3 / 136.4 / 113.7 | 66 288 | 2 301 messages visited for 51 topics (~45 per topic); the archived NOT EXISTS uses `messages_archived` on tenant_id only: **~367 archived rows per probe**, 112 probes x 0.55..0.79 ms; the subject LATERAL reads every row of the topic via `messages_task` and sorts it (51 x 1.5 ms); planning 11..22 ms |

Dev, same statements, t1 / HUM-9, n=3: Flow counts 117.5 / 6.6 / 7.0 ms. DM walk 726.9 / 74.0 / 75.2 ms, 23 525 buffers, 2 374 messages visited for 51 topics.

### 3.4 Rewrites tried (A/B, same n, result md5 old vs new)

| rewrite | prd ms (n=3) | dev ms (n=3) | md5 equal | verdict |
|---|---|---|---|---|
| Flow counts start from a MATERIALIZED set of the member's own events (`-b`) | 74.2 / 77.4 / 101.4 | 5.7 / 7.0 / 5.9 | yes, prd + dev | **no gain**: equals the hub's Insights mean (77.1 ms), so the hub already runs this shape |
| `-b` + join messages on the covering `messages_task_received` (task_id, received_at = flow_events.at, msg_id) (`-c`) | 71.0 / 90.2 / 68.5 | 5.5 / 5.7 / 8.8 | **dev yes, prd NO** (md5 ed33cae7 vs 4137ef96) | **unsafe and no gain**: some prd flow_events carry an `at` that is not their message's received_at (a case only prd data has), so the join drops rows; the planner also kept `messages_received` |
| DM walk: archived OR split into two NOT EXISTS (`-b`) | **5 584 / 7 270 / 5 900** | 91.1 / 91.1 / 73.5 | yes, prd + dev | **worse**: the recursive step became a Bitmap Heap Scan of 11 435 rows x 50 (the SPL-984 trap). The hub turns bitmap scans off, so this needs the hub's settings to judge |
| DM walk: subject row by an index-only pick, then one row by key (`-c`) | not run | 632.4 / 796.6 / 647.0 | yes, dev | **worse** on dev |

Rewrite scripts and texts (not in git): `/var/tmp/c392-sql/{explain,eq,hot}.sh`, `/var/tmp/c392-sql/<env>/*.sql`.

### 3.5 Hub process, pool, WebSocket fan-out

- **CPU and memory per request class:** not re-measured. No read-only action reads the Cloud Run Monitoring series; the perf edition used a one-off call. Last numbers (2026-10-04, prd 24 h): CPU per-minute p99 0.04, memory p99 <= 0.25; prd runs `GOMAXPROCS=1`. Example: channels route p50 40.5 ms against ~48 ms of DB per call (five statements in one pipelined batch). The hub's own share is not visible.
- **DB connections:** 9 of 25 in use (8 pool + LISTEN), 0 sessions waiting on a lock. The deadlock counter is still 47, as on 10-04, so E02 holds. 0 5xx on PUT /v1/me/reads in 8.4 h. Settings: `statement_timeout` 30 s, `work_mem` 4 MB, `jit` on (the walks turn it off).
- **WS fan-out per message:** the encode side is done (E16: 208 us / 224 allocs per 10 sockets, n=6). The DB side of a new line is `FlowFanout`, **87 ms per line** (n=680/day): it runs the Flow counts once per member who has a socket. ap-01 fixes it too.

## 4. Candidate rows, ordered by measured gain

One row = ONE improvement at the named sites = one small commit `perf(ap-NN): <what>`, in the owner's row-lane template (t1 e0dda261, msg 7a55486d):
- the sites are the only files the lane may change;
- re-check each site on a fresh `origin/master`;
- run the listed tests before and after;
- behaviour stays identical: same rows, same JSON, same errors;
- clean-code bar: functions <= 80 lines, nesting <= 4, params <= 8;
- stop and report if the change turns out to change behaviour;
- drop and report a site whose gain is gone on re-measure.

**Legend:**
- `api:` = `csi-spl-api/src/go/spool-hub-api/`.
- **Box:** `main` is the owner's primary box. It holds the prd SA keys and Chrome; its short name is banned in shipped files by the hygiene sweep, and the lane map prints it. `sat` is the satellite.
- A store row needs Postgres: `postgres:16-alpine` in docker on either box (`SPOOL_TEST_PG_DSN`; store tests skip without it).
- **Every prd proof read goes through c-001 on main.**
- **Agent:** `claude` for SQL whose correctness rests on RLS or on result equality, and for DDL; `grok` for bounded, mechanical work (the owner's mix).

| row | what and why, in one sentence | sites | measured cost now (n) | expected gain | proof (same method, same n) | tests that guard behaviour | risk | box | agent | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| **ap-01a** | Store each Flow event's place key (`ch:<c>`, `dm:<id>[@box]`) and topic key on the event row when it is written, plus an index on them, so the counts can later read only the events a mark does not cover. | new migration `csi-spl-rdb/src/sql/postgres/spool-hub/0134_flow_events_place_key.sql` (columns, backfill from messages, index `(tenant_id, member_id, place_key, at)`); `api:internal/store/flow_postgres.go:26-50` (`flowInsertCTE` writes them) | enables ap-01b; on its own 0 | 0 (enabler); write cost +1 index entry per event (~600 lines/day x members). Backfill from messages by msg_id, never by `at`: on prd some events' `at` differs from their message's received_at (3.4) | message insert mean (Insights) unchanged within noise, 24 h before/after; backfill row count = flow_events count | `flow_test.go`, `flow_keys_test.go`, migration catalogue tests, `PRE_PUSH_TIER=full` | med: DDL on prd needs the owner's go; deploy order DDL before hub | main | claude | 1 |
| **ap-01b** | Count a member's unread by reading, per place mark, only the events after it, instead of probing the messages table and the marks once for every event the member ever got (~3 530 for the main reader, nearly all read). | `api:internal/store/flow_postgres.go:78-119` (`flowCoveredSQL`, `flowCountsSQL`; shared by `FlowRead` :155 and `FlowFanout` :193) | prd 24 h: **865.5 s (37.8 %)**, n=11 229 x 77.1 ms, + `FlowFanout` 59.1 s (2.6 %), n=680 x 87.0 ms; per call ~10 600 index probes (`-b` plan, n=3) | 77 -> under 10 ms per call (estimate: work becomes O(marks + unread)); up to **~-800 s/day = ~35 % of prd DB time**; the badge push after each read and each new line lands sooner | Insights 24 h mean + calls of `WITH fc` and `FlowFanout` before/after on prd; EXPLAIN n=3 t1/HUM-10; result md5 equal old/new on dev and prd (`eq.sh` method) | `internal/store/flow_test.go`, `flow_keys_test.go`, `flow_archive_test.go` (Postgres); `internal/hub/flow_test.go`, `flow_etag_test.go` | med: the archived and door rules must stay per message for the uncovered events; the oracle is today's statement | main | claude | 1 (after ap-01a) |
| **ap-02** | Expand archived lines only for channels the reader has no mark on, so a reader whose marks cover every channel no longer builds ~4 850 lines just to throw them all away. | `api:internal/store/channels_postgres.go:469-494` (`hiddenUnreadRead`) | prd 24 h: **308.4 s (13.5 %)**, n=11 734 x 26.3 ms; EXPLAIN 24.5 / 36.0 / 27.8 ms, 7 916 buffers, **0 rows out** for HUM-10 (n=3) | for an all-marked reader 26 -> ~2 ms per channels GET (estimate); up to ~-280 s/day; channels p50 40.5 -> ~20 ms | EXPLAIN n=3 prd before/after for HUM-10 AND for a reader with no marks (the expansion must still run there, same counts); Insights mean; GET /v1/view/channels p50/p95 24 h | `channel_hidden_unread_test.go`, `channels_hidden_unread_e04_test.go`, `channel_stats_oracle_test.go`, `channel_own_unread_test.go`, `channels_test.go` (Postgres) | low-med: the oracle test keeps the pre-E04 shape as truth | sat | claude | 1 |
| **ap-00** | Make `do_spl_db_hot_measure` run the statements the store **actually** sends today (printed by the Go builders), under the hub's planner settings, so every walk row can prove its gain on prd with n=20. | `csi-spl-orc/src/bash/run/spl-db-hot-measure.func.sh`; a new printer test beside `api:internal/store/view_postgres.go` (e.g. `stmt_print_test.go`, skipped unless asked) | hot walk_dm **22.0 ms p50 (n=20)** vs the store's text **114..286 ms (n=3)** vs Insights **456 ms mean (n=245)**, same tenant and reader | none for a user: the proof tool for ap-03 and ap-07 | the action's statement md5 = the builder's output; prd walk_dm lands in the Insights range | `csi-spl-orc/src/bash/tests/spl-db-hot-measure.tst.sh`; the new Go test | low | main | grok | 1 |
| ap-03 | Check "is this topic archived" with two index probes instead of one OR, so a walk step stops reading all ~370 archived cards per candidate. | `api:internal/store/topic_archive_postgres.go:363-366` (`archivedTopicHideSQL`) | prd DM walk plan: 112 archived probes x 0.55..0.79 ms of 114..286 ms (n=3); walks 239.9 s/day (10.5 %); DM seed p50 269..354 ms | unknown: under the operator scope the split was **20x worse** (3.4); judge it only with ap-00 under the hub's settings; drop it if hot-measure walk_dm n=20 does not drop | ap-00 hot-measure walk_dm / walk_all n=20 A/B on prd; route p50/p95 per shape 24 h | `view_topics_test.go` (oracle), `view_topics_subject_test.go`, `topic_archive_test.go`, `view_test.go`; `internal/hub/channels_test.go` | med: planner-shape sensitive | sat | claude | 2 (after ap-00) |
| ap-04 | Keep the messages table's visibility map current with an insert-driven autovacuum threshold, so the channel counts (and the walk probes) are true index-only scans instead of visiting the heap for half the rows. | new migration `csi-spl-rdb/src/sql/postgres/spool-hub/0135_messages_autovacuum.sql` (`ALTER TABLE messages SET (autovacuum_vacuum_insert_scale_factor = ...)`) | prd channels counts: **Heap Fetches 3 691 of 6 917** rows (n=3, every run); 256.2 s/day (11.2 %) | counts 17..22 -> ~10..12 ms (estimate) ~-100 s/day; smaller heap work in every index-only walk probe | EXPLAIN n=3 before/after (Heap Fetches -> near 0 after one autovacuum pass); `do_spl_db_health SECTION=vacuum` | migration catalogue tests; `PRE_PUSH_TIER=full` | low-med: prd DDL needs the owner's go; more autovacuum on a micro instance | main | claude | 2 |
| ap-05 | Find why the WUI sends one GET /v1/view/channels per read-mark PUT, and drop the re-read where the Flow `keys` push already carries the new counts. | measure first: `csi-spl-wui/src/utils/read-sync-boot.ts:82`, `csi-spl-wui/src/stores/channel.ts:202-206` | prd 8.4 h: channels GETs 4 670 vs PUTs 4 817; each channels GET ~48 ms of DB (3.2 rows 2 + 3 + 11) | if the re-read follows the tab's own PUT: up to the whole channel-list load (602.6 s/day, 26.3 %); if not, **drop the row** | dev browser session, CDP network log, 10 min of reading, n>=20 PUTs: channels GETs per PUT before/after; route n per 24 h on prd | `tests/unit/read-sync.test.mjs`, `read-sync-delta-reply.test.mjs`, `unread-model.test.mjs`, `own-message-unread.test.mjs`; the channel unread e2e | med: a stale channel badge if the keys push does not cover a case | main (Chrome) | grok | 2 |
| ap-06 | Re-count a member's Flow badges at most once per short window when several read-mark wakes arrive together, instead of once per wake (perf edition E03, never landed). | `api:internal/hub/wui_wake.go:57-63`, `api:internal/hub/read_marks.go:131-136`, `api:internal/hub/flow.go:257-275` (`pushFlowCounts`) | n=11 229 count reads/day, one per wake (prd); the burst factor is **not measured**; PUTs come every 5 s per tab, so a sub-second window helps only multi-tab / multi-device bursts | calls / burst factor; re-measure after ap-01b (the per-call cost may be small by then); drop if the median per-member PUT gap is > 1 s | Insights calls of `WITH fc` per 24 h before/after; a hub test: N wakes inside the window -> 1 push with the final counts; a lone wake still pushes | `internal/hub/flow_test.go` + a new coalesce test | med: the badge lags by up to the window | sat | claude | 2 (after ap-01b live) |
| ap-07 | Keep one "topic head" row per topic (latest line, channel or DM, parties), kept current by the insert path, so a topic list reads ~50 rows instead of walking ~45 messages per listed topic. | new migration + trigger; `api:internal/store/view_postgres.go:193-375` (`viewTopicsSQL`, `statement`, `summary`) | prd: 2 301 messages visited for 51 DM topics (n=1 plan); walks 239.9 s/day; DM seed p50 269..354 ms, Flow list p50 304 ms, channel page p50 213 ms (8.4 h) | walk work -80..90 % (estimate): the biggest **user-visible** gain on every list | ap-00 hot-measure n=20 per walk; route p50/p95 per shape 24 h | `view_topics_test.go` oracle against today's walk; trigger tests on Postgres | **high**: an insert-path trigger, a backfill, prd DDL. Round 2 deferred it until prd numbers existed; they do now | main | claude | 3 (owner decision) |
| ap-08 | Find what makes a message insert take 46..86 ms on prd and remove the biggest single cost. Candidates: the Flow-candidate CTE `flowInsertCTE`, 18 indexes on messages, 3 row triggers. | measure first: `api:internal/store/postgres.go` (the `WITH ins AS (INSERT ..)` send path), `api:internal/store/flow_postgres.go:26-50` | prd 24 h: n=590 x 46.1 ms and n=247 x 85.5 ms; every send pays it | unknown until a lab profile names it; drop if the largest piece is < 10 ms | local pg16 with prd-sized rows, rolled-back insert, `EXPLAIN (ANALYZE, BUFFERS, WAL)`, n=20 | send-path tests on Postgres | med | sat | claude | 3 (runner-up; after ap-01a: same file) |
| ap-09 | Pick each listed topic's subject line through the covering index and fetch only that one row. | `api:internal/store/view_postgres.go:351-375` (`summary`) | prd DM walk plan: 51 x 1.5 ms = ~76 ms of 286 ms (n=1) | the text rewrite tried was **worse on dev** (3.4); only with a shape that wins under ap-00 | ap-00 hot-measure walk_dm n=20 A/B | `view_topics_subject_test.go`, `view_topics_test.go` | med | either | claude | runner-up (same file as ap-07) |

### 4.1 Dropped: real but a user would not notice the gain

| what | measured (prd 24 h unless noted) | why dropped |
|---|---|---|
| `INSERT INTO boxes .. last_hello_at` on every box hello | 70 648 x 0.63 ms = 44.2 s (1.9 %) | box bookkeeping; no screen waits on it |
| unanswered sweep (orc cron) | 173 runs x ~450 ms = 76.7 s (3.3 %) | a cron; E17 already narrowed it |
| `FileReadableByHuman` jsonb probe | 8 973 x 2.65 ms = 23.8 s; GET /v1/files p50 52.7 ms | 2.65 ms of a GCS-bound 52.7 ms route |
| GET /v1/me/reads (whole map) | n=90 in 8.4 h, p50 18.7 KB, 9.8 ms | once per tab start |
| box polls (`/v1/pins?probe=1`, deliveries) | 12 876 in 8.4 h at 2.6 ms; 219 651 x 0.06 ms | already cheap |
| POST /api/v1/auth/login | n=166, p50 122.6 ms | the password hash cost is deliberate |
| GET /v1/view/search 503 | n=5, 4 x 5xx | lane c-389 owns it (`internal/store/search.go`, `internal/search`) |

### 4.2 Runners-up (not rows yet)

- A read-only action for the Cloud Run CPU / memory / instance series (`do_spl_hub_cloud_run_metrics`) to give per-request-class hub cost.
- A hub-side cache of the reader-independent channel counts per tenant, invalidated by the message wake and a short TTL. Only if ap-02 + ap-04 leave channels above 20 ms of DB. A change-stamp key does not work: read_marks bumps the tenant stamp on every PUT.
- `cloudsql.enable_pg_stat_statements` for exact per-statement timing: it restarts the instance, so it is the owner's call, not a row.

## 5. Batches: 4 lanes at a time, 2 per box, files disjoint

| batch | main | sat | gate before it starts |
|---|---|---|---|
| 1 | ap-01a then ap-01b (one lane, serial: same file), ap-00 | ap-02 | ap-01a: owner's DDL go for prd (dev first) |
| 2 | ap-04 (DDL go), ap-05 (Chrome) | ap-03 (needs ap-00 landed), ap-06 (needs ap-01b live, re-measure first) | batch 1 served on dev + prd |
| 3 | ap-07 (owner decision) | ap-08 (needs ap-01a landed) | the owner's review |

- **Disjoint, including generated files.** No source path is in two rows of one batch. ap-01a/b and ap-08 share `flow_postgres.go`, so they run in different batches; ap-07 and ap-09 share `view_postgres.go`, and only one of them may be picked. Generated files:
  - ap-00's bash edit may move `.shellcheck-warning-baseline.txt`, and no other batch-1 row touches bash.
  - A Go row whose new function crosses the clean-code limits splits the function; it does not grow the `internal/cleancode` longFuncs map.
  - ap-01a, ap-04 and ap-07 each add a migration with the next free number: serial by batch, re-numbered at rebase.
- **Off every live lane:** `lane-map.sh --check` on the 12 existing paths of these rows printed `free`, rc 0 (2026-10-06 11:54Z, trunk `929edfa3e`).
- **One spawn per slug across both boxes.** The box column names the only box that spawns that slug.
- **Done = served.** A row is done when dev AND prd serve a hub (`/version`) that contains its sha (`git merge-base --is-ancestor`), and its proof has been re-run after the roll with the same n.

## 6. Summary for the owner (3 lines)

1. The API is slow in four database statements, not in the server. One Flow-badge count is 38 % of all DB time, and its cost nearly tripled in two days. The channel list is 26 %. The topic lists are what you wait for: 0.15..0.35 s typical, up to 1.5 s.
2. Each one has a named cause seen on prd. The badge count re-checks every Flow event a person ever got, about 3 500, on each read. The channel list builds 4 849 archived lines and uses none. Each topic-list step re-reads ~370 archived cards.
3. 9 candidate rows (10 commits with ap-01 split in two) plus a proof-tool fix. Three quick SQL rewrites were measured on prd and none helped, so the top row is a small schema change: it needs your go for prd.

## 7. Not measured, and what it needs

- **Hub CPU / memory per request class today:** needs the runner-up Monitoring action, not a one-off call.
- **The burst factor of read-mark PUTs per member** (ap-06) and **the cause of one channels GET per PUT** (ap-05): each row's first step.
- **The walk under the hub's planner settings and current text:** ap-00.
- **prd route window:** the 50 000-entry log limit gave 8.4 h. Use `ROUTE_LIMIT=200000` for the after-proofs.

## 8. Commands to reproduce

All read-only, from `csi-spl-orc`, as the env SA; prd only through c-001.

### 8.1 Routes by total server time

```bash
ENV=prd ROUTE_HOURS=24 ROUTE_TOP=40 ROUTE_LIMIT=200000 ./run -a do_spl_hub_route_latency
```

### 8.2 Routes by query shape

```bash
ENV=prd ROUTE_HOURS=24 ROUTE_TOP=40 ROUTE_LIMIT=200000 ROUTE_QUERY=1 ./run -a do_spl_hub_route_latency
```

### 8.3 Statements by DB time

```bash
ENV=prd INSIGHTS_HOURS=24 INSIGHTS_TOP=25 ./run -a do_spl_db_insights
```

### 8.4 DB load and counters

```bash
ENV=prd SECTION=load ./run -a do_spl_db_health
```

### 8.5 One plan of a store statement

```bash
ENV=prd SQL="EXPLAIN (ANALYZE, BUFFERS) <the store statement with literals>" ./run -a do_spl_db_query
```
