# DB payload audit, round 2: dig more, or are we at diminishing returns? (2026-10-02)

Owner topic t1 #spool-hub-devel `66233cdc`. After round 1
(`db-payload-audit-2026-10-02.md`) shipped cuts 1, 2, 3, 6, 7 and 8 (5 has
also landed since; 4 is in flight), HUM-10 asked:

> "wow those were HUGE improvements ... can we dig more the same way"

> "or is the case that we would need some kind of total change of the
> protocol - aka we are hitting the low of demiishing returns in this case"

This lane measures and proposes. It changes no code. Each cut the owner
accepts becomes its own lane.

## 1. Answer

1. **On the DB/payload axis we are at the plateau.** Since round 1, the first
   screen moves 70 % fewer DB bytes, 75 % less JSON and 68 % less gzip, in
   11 DB round trips instead of 24. What is left is **~5.8 KB gzip and ~47 ms
   of DB time** (local PG16). The same first load fetches **~340 KB gzip of
   JS** and takes **~5 s to paint the Flow list**. The hub and DB are now about
   1..2 % of the bytes and about 1 % of the time.
2. **Two cheap cuts are still worth doing: WS compression and a delta
   catch-up on reconnect** (§4, R2-1 and R2-2). Each of the others is worth
   less than 5 % of what is left.
3. **No protocol change.** A delta/sync protocol would save at most ~1 % of
   time-to-Flow, at a high cost. Only one structural item deserves a measured
   decision: a **server-maintained topic summary**, which would replace the
   recursive topic walk. Its case is the prd tail (the walk's p95 is 250 ms),
   not the median, and it needs the prd numbers in §6 first. **The seconds are
   in the WUI's JS** (TBT ~2 s, the CLE-77934 lane), not in the protocol.

## 2. How it was measured

- **Rig:** round 1's harness (`db-payload-audit-2026-10-02.harness.go.txt`)
  with the same seed (20 lobby lines, 12 topics x 3, 4 agent peers x 25 DMs
  + 5 box replies, 192 B bodies), the same route list and the same n = 5
  requests per route. It runs over the real session door against **local
  `postgres:16-alpine`** as the non-superuser `spool_app` (RLS binds), on the
  satellite (e2-standard-16).
- **Additions** (`db-payload-audit-round2-2026-10-02.harness.go.txt`):
  1. Probe `dm-seed` is what the WUI now sends:
     `topics?dm=true&limit=50&dm_counts=true` (cut 1, `stores/channel.ts`
     `loadDmActivity`). The round-1 probe stays as `dm-seed-r1`.
  2. Each request records `wall us` and `db wait us`, both medians of the 5.
     `db wait` is the time the hub waits on Postgres: from each Sync/Query
     until ReadyForQuery, summed. The proxy now parses a client message before
     it forwards it. When it parsed after forwarding, a fast ReadyForQuery
     could overtake its Sync, and the timer read 0.
  3. One extra run with `log_min_duration_statement=0` gives Postgres' own
     parse/bind/execute time per statement.
- **Trees, n = 3 runs each:**
  - **before** = `91385c6c`, round 1's tree, rerun from a `git archive`
    export. It reproduces round 1's table (DM seed DB down 106 001..107 565 B,
    WS frame 1 099..1 102 B).
  - **now** = `e6f862c3` (origin/master at measurement). It carries cuts 1,
    2, 3, 5, 6, 7 and 8. It does **not** carry cut 4 (c-010, in flight).
- Bytes and statement counts were identical across the 3 runs, except where
  a min..max is shown. Times are the median of 5 requests in each run; the
  three runs' medians are given as a..b..c.
- **The WUI side** is not re-measured on a deployed host. The first-load
  harness needs the dev m3-e2e credential, which this machine does not hold,
  and creating it would mutate dev. Instead I cite the CLE-77933 and CLE-77934
  measurements by commit, and add a static measurement of the current bundle:
  `nuxt generate` on `e6f862c3`, gzip -9 per file.

## 3. Before / now, per route

| route | DB rt before -> now | DB down B before -> now | JSON B before -> now | gzip B before -> now | DB wait ms before -> now (3 runs) |
|---|---|---|---|---|---|
| **first screen** (session + me + channels + roster + DM seed + Flow) | **24 -> 11** | **125 170 -> 37 284 (-70 %)** | **108 465 -> 27 404 (-75 %)** | **17 937..18 211 -> 5 824..5 842 (-68 %)** | **58.1..59.1..54.5 -> 48.3..47.0..47.2 (-17 %)** |
| `GET /api/v1/auth/session` | 6..8 -> 3..5 | 371..910 -> 299..886 | 517 -> 517 | 321 -> 321 | 4.3..3.5..3.6 -> 2.7..2.9..2.2 |
| `GET /v1/view/me` | 1 -> **0** | 107 -> 0 | 348 | 238 | 0.9 -> 0 |
| `GET /v1/view/channels` | 6..8 -> 1..2 | 607..1 350 -> 414..1 116 | 963 | 374 | 7.9..7.1..7.2 -> 6.0..5.8..5.6 |
| `GET /v1/view/roster` | 2..3 -> 1..2 | 544..1 171 -> 437..1 064 | 376 | 326 | 3.4..4.4..3.0 -> 2.2..2.3..2.2 |
| **DM seed** (before `per_topic=50`, now `dm_counts=true`) | 5..9 -> 3..4 | **106 001..107 565 -> 21 925..22 219** | **92 112 -> 11 051** | **13 508..13 768 -> 1 411..1 429** | **28.9..31.6..28.6 -> 27.0..25.1..26.5** |
| Flow `topics?limit=12&per_topic=3` | 4..5 -> 3..4 | 17 540..17 825 -> 14 209..14 494 | 14 149 -> 14 149 | 3 169 -> 3 150 | 12.7..11.6..11.1 -> 10.4..10.9..10.7 |
| channel page `topics?channel=lobby&limit=20&per_topic=30` | 4..5 -> 3..5 | 51 039..51 348 -> 46 272..46 581 | 43 939 -> 43 929 | 6 060..6 289 -> 6 013..6 051 | 12.5..17.9..14.8 -> 13.8..13.1..13.3 |
| topic `GET /v1/view/topics/{lobby}` | 4..7 -> 3..8 | 14 314..15 214 -> 14 207..15 393 | 13 820 | 2 141..2 186 -> 2 126..2 141 | 4.7..5.5..5.0 -> 4.1..3.9..4.0 |
| WS `send` (lobby), per send | 5..6 -> **2** | 416..595 -> 144 | ack 254 | | |
| WS `message` frame, per open tab | | | **1 099..1 102 -> 704..707** | (no WS compression) | |

The first screen's DB wait is a sum of sequential requests. The WUI sends
part of them in parallel, so its real wait is lower.

Of the 5 WS sends in each run, 1 cost 4 round trips / 9 statements instead
of 2 / 4. That is the cap/bookkeeping write, which runs once per batch, not
per send (same in all 3 runs).

**Bytes fell 3..4x. DB time fell only 17 %.** The reason is §4.1: what is left
is the topic walk's time, not rows.

## 4. Where a first screen and a round trip spend time and bytes NOW

### 4.1 DB: the recursive topic walk is ~60 % of the first screen's DB time

From Postgres' own log (extra run, `log_min_duration_statement=0`, now tree,
5 requests per route):

| statement | bind (plan) ms | execute ms | rows |
|---|---|---|---|
| DM walk (`WITH RECURSIVE w`, `channel IS NULL`) | 4.6..5.4 | **14.6..17.3** | 24 |
| Flow walk | 4.0..5.2 | 2.1..2.7 | 13 |
| channel page walk | 4.3..5.2 | 4.1..4.2 | 21 |
| WUI send (`WITH ins AS (INSERT ...)`, cut 7) | | 0.9 median | 1 |

- The two first-screen walks (DM + Flow) cost about 27 ms of the ~47 ms. Each
  walk pays ~4.5..5 ms of **planning** on every read. That planning is
  deliberate: `force_custom_plan` beats the generic plan on prd, 27 ms custom
  vs 71 ms generic (`view_postgres.go:111-116`). So planning cannot be cut
  cheaply.
- On prd the walk is `p50 22 ms, p95 250 ms` per read (prd t1, reader HUM-10,
  n=10, after CLE-77914; `grep -n 'p50 2 900 -> 22 ms'
  csi-spl-api/src/go/spool-hub-api/internal/store/view_postgres.go` -> 129).
  At the median the walk is cheap. At p95 it is visible.
- **N+1: none.** The statement count is fixed per request, whatever the rows:
  the DM seed is 6 statements for 24 topics / 120 DMs, and Flow is 7 for 12
  topics. Lingering handles: `pool acquired after` was 0 for every request of
  every run (8 routes x 5 x 3).

### 4.2 Hub CPU, network, WS

- **Hub CPU (wall - DB wait):** ~1..3 ms per route, including the loopback
  HTTP, JSON encoding and gzip. Example: DM seed 29.2 - 27.0 = 2.2 ms.
- **Network to the browser:** ~5.8 KB gzip for the whole first screen's API.
  The hub already gzips JSON of 1 KB or more (`hub/compress.go`) and sends a
  body-hash ETag (`hub/etag.go`).
- **Network hub <-> DB on prd:** 11 round trips per first screen instead of
  24. I believe, unchecked, that a Cloud Run -> Cloud SQL round trip costs
  ~0.5..1 ms, so ~6..12 ms per first screen remains on that leg.
- **WS:** 707 B per `message` frame per open tab, with no compression
  (`hub/wui.go:193` sets no `CompressionMode`). Its content is a 192 B body
  plus ~515 B of envelope: `cursor` (106 B, the base64url of
  `received_at|msg_id`, both already in the frame), `channel` x2, `task_id`
  x2, `files:[]`, `sig:""`, `from_box`/`to_box` `box-wui`.
- **Reconnect / backfill:** on reconnect the WUI calls `channel.catchUp()`
  (`composables/useSpoolEvents.ts:79`). It re-reads a **whole channel page**:
  `listMessages` -> `listTopics({limit: 20, perTopic: 50})`
  (`utils/spool-client.mjs:841`). That is ~44 KB JSON / ~6 KB gzip and ~13 ms
  of DB per tab per reconnect, even when nothing was missed. Every hub deploy
  re-dials every tab (`checkRevision`, 15 s). The hub supports an `after=`
  cursor only on the single-topic read (`hub/view.go:863`), not on the topics
  list.
- **Polling:** light. `GET /v1/wui/revision` every 15 s per tab (browsers
  throttle background tabs to ~1/min), read-sync push every 5 s only when a
  cursor moved (`utils/read-sync.mjs`), `build.json` every 5 min. The 4 s
  poll in `useSpoolEvents.ts` runs only in mock mode.
- **Cache headers:** fine. `/_nuxt/**` is `max-age=31536000, immutable`;
  documents are `max-age=0, must-revalidate`; images get 1 h +
  stale-while-revalidate (`csi-spl-wui/firebase.json`); hub JSON is
  `private, no-cache` + ETag. One gap: the ETag is a hash of the finished
  body, so a 304 saves the network but **not the DB work** (R2-5).

### 4.3 WUI JS: where the seconds are

| measure | value | source |
|---|---|---|
| initial JS (entry + 3 modulepreload) | 151 KB gzip (443 KB raw) | `nuxt generate` on `e6f862c3`, this lane |
| `rel=prefetch` chunks | 96 links, 189 KB gzip | same |
| whole build | 216 JS chunks, 1 026 KB gzip; `index.html` 12.5 KB gzip | same |
| cold first load before the rail, prd e2e | 215 requests / 610 KB (101 of them prefetch, 345 KB); 7 requests / 49 KB cut since | `ac37ff38`, `28e257b3`, `bfb770a6` (CLE-77933, n=2 / n=10) |
| dev, d1440 warm, p50/p90 | rail 3 292 / 4 167 ms, Flow list 5 011 / 6 702 ms, TBT 2 110 ms | `22341ea9` (CLE-77934, n=10, 9ce33809) |
| phone m390, CPU 4x | rail 12 009 ms, Flow list 19 444 ms | same |
| JS after the Flow list paints | ~1.9 s of microtask JS in the next 2.5 s | `f717580f` (CLE-77934) |
| rail -> Flow main-thread JS | 4.6 -> 0.5 s desktop after lazy rail tabs | `0d43d7a8` (CLE-77934, n=10) |

### 4.4 The shares

| resource | hub + DB (first screen) | WUI (first screen) | hub + DB share |
|---|---|---|---|
| bytes to the browser | ~5.8 KB gzip API | ~340 KB gzip JS (151 initial + 189 prefetch) + 12.5 KB html | **~1.6 %** |
| time | ~47 ms DB + ~10 ms hub CPU, sequential, local | ~5 000 ms to the Flow list (dev p50) | **~1 %** (p50); up to ~10 % if both walks hit the prd p95 of 250 ms |
| message round trip | 2 DB round trips, ~1 ms of INSERT; 707 B per tab | render of 1 row | negligible |

## 5. The next cuts, ranked by win / risk

| # | cut | before -> after | files | risk |
|---|---|---|---|---|
| **R2-1** | **WS permessage-deflate** on `/v1/wui/ws`. Browsers negotiate it on their own, so the WUI does not change | `message` frame **707 -> ~166 B** with context takeover (-76 %), or ~441 B without it (-38 %). Simulated over n=40 real 192 B bodies (from spec 059) on the captured frame; it applies to every frame type | `hub/wui.go:193` (`AcceptOptions.CompressionMode`) + a test | **low**. Context takeover keeps one flate state per socket (memory per open tab); choose the mode by measuring RSS with N tabs |
| **R2-2** | **Reconnect catch-up as a delta**: a `since=<cursor>` on the topics list. The WUI sends the last cursor it holds (`live-ws.mjs` already keeps one per task) and falls back to the full page after a long gap | per tab per reconnect: ~44 KB JSON / ~6 KB gzip, 3..5 round trips, ~13 ms DB -> ~0 rows when nothing was missed. Every hub deploy multiplies it by every open tab | `hub/view.go` topics handler, `store/view_postgres.go`; WUI `stores/channel.ts` `catchUp`, `utils/spool-client.mjs` | **low-medium**. Edits, moves and reactions made during the gap need a path (their frames, or the fallback) |
| R2-3 | WS frame trims, **after** cut 4 (c-010) lands: drop `cursor` (rebuild it from `received_at` + `msg_id`), `env.channel`, `env.msg.task_id`, empty `files`, empty `sig`, default `box-wui` boxes | 706 -> 481 B raw (-32 %). After R2-1 it is worth only ~10 % more | `hub/wui.go` fan-out frame; WUI `utils/live-ws.mjs` `messageFromFrame` | low. Must not collide with c-010 |
| R2-4 | DM counts in SQL: `dm_counts` still pulls 120 meta rows (12.9 KB) and counts them in Go. A `GROUP BY` returns 24 | DM seed DB down ~22 -> ~10 KB; DB time ~-1..2 ms (the walk, not the rows, holds the time) | `store/view_topics_batch.go`, `hub/view.go` | medium. The CLE-77845 / 77873 / 77889 rules (own lines are never new) move into SQL |
| R2-5 | A cheap validator **before** the DB: a per-tenant change stamp, so an unchanged repeat read answers 304 after 1 round trip | repeat reads (focus, catch-up, revision re-dial): ~3..5 round trips and ~10..27 ms -> 1 round trip | hub door + every writer (send, edit, move, archive, reactions, membership, retention) | **medium-high**. A missed bump is a stale screen. It is the first step of a sync protocol |
| R2-6 | Walk planning (~4.5..5 ms per walk) | no safe cheap cut: the generic plan is worse on prd (71 vs 27 ms) | — | not proposed |

**Not found: N+1** (§4.1), **excess polling** (§4.2) and **cache-header
gaps** (§4.2). They need no cuts.

## 6. Protocol changes: what they would reach

Reused, not redone: spec 059 (CLE-77931, `specs/059-messaging-backbone/spec.md`)
decided **no broker; keep Postgres as the log**. Its reasons hold here: prd
carries ~1 700 messages a day, so throughput is not the problem. A broker
would not shrink one read of the first screen.

| change | what it removes | win | cost | verdict |
|---|---|---|---|---|
| **P1 server-maintained topic summary**: a `topics` row (last_at, n, kinds, parties, subject, first_at) upserted in the send's INSERT CTE; unread through the read-cursor join | the recursive walk: ~27 of ~47 ms of first-screen DB locally; on prd the walk's p50 22 ms, **p95 250 ms**, per topics read | p50: ≤ 1 % of time-to-Flow. p95: up to ~0.5 s of ~5 s | rdb migration + backfill. Every writer (send, edit, move, archive, delete, kind change, retention) must keep the row right. ~1 lane-week plus a bug tail | **decide on prd numbers** (§7). Worth it only if the walk's p95 is still in the hundreds of ms |
| P2 delta/sync protocol with a client store (IndexedDB, "changes since seq N") | warm-load and reconnect reads | ≤ 5.8 KB gzip and ≤ ~50 ms of hub per warm load: ~1 % of time-to-Flow. A cold load gains nothing | a sequence per tenant, tombstones for edit/move/delete/reaction, multi-device invalidation. High | **no**. R2-2 + R2-5 take its useful part for a fraction of the cost |
| P3 binary framing (CBOR / protobuf) on the WS | JSON key text | after R2-1 a frame is ~166 B; binary saves perhaps 50..100 B more | a codec on both sides, plus debuggability | **no** |

**Recommendation: plateau.** Two more cuts (R2-1, R2-2) are worth doing:
**-76 % WS bytes per frame** and **~44 KB less per tab per reconnect**. Each
is low risk and its own small lane. After them the hub + DB stay at ~1 % of
time-to-Flow. No protocol change wins more than ~1 % at the median. P1 is the
one structural candidate, and only on prd tail evidence. The next real seconds
are in the WUI's JS: TBT ~2.1 s and ~1.9 s of JS after the Flow list paints
(the CLE-77934 lane).

## 7. Prd numbers still to take (the owner's go; sent to CLE-001)

Read-only, as the prd service account, through the named actions:

```bash
cd csi-spl-orc && ENV=prd TENANT_ID=t1 READER=HUM-10 MEASURE_N=20 MEASURE_JIT=off MEASURE_ONLY=walk_all,walk_dm ./run -a do_spl_db_hot_measure
```

That gives the walk's p50/p95 today. It decides P1.

```bash
cd csi-spl-orc && ENV=prd SPL_PROXY_PORT=55953 SQL="select count(*) n, round(avg(octet_length(env))) env_avg, percentile_disc(0.95) within group (order by octet_length(env)) env_p95, count(*) filter (where channel is null) dm_n, count(distinct task_id) topics from messages where tenant_id='t1' and expires_at > now()" ./run -a do_spl_db_query
```

That gives the body and topic shape that scales the local seed's numbers.
