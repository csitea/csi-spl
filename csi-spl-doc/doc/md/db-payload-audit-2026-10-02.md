# DB payload audit: less data and metadata to and from the database (2026-10-02)

Owner topic t1 #spool-hub-devel `66233cdc`. The owner asked:

> "Is it possible that we could reduce the amount of data or metadata (technical
> metadata) that we are passing to and from the database?"

and then:

> "are we doing all of the database operations properly? AKA are there any
> multiple obsolete fetches? Could we combine some fetches? Are there any open
> DB handles lingering?"

This lane measures and proposes. It changes no code. Each cut the owner
accepts becomes its own lane.

## 1. Answer

1. **Yes, and one read carries most of it.** The DM seed
   (`/v1/view/topics?dm=true&limit=50&per_topic=50`, `stores/channel.ts`
   `loadDmActivity`) pulls about 106 KB from Postgres and sends 92 KB of JSON
   (13.9 KB gzip) on every page load. The web app uses it only to count unread
   DMs and order the DM list. It reads `from`, `to`, `msg_id`, `received_at`
   and `typed_by` from each inlined message, and never reads the body,
   envelope, signature, deliveries or reactions. If the hub counted DM unread
   itself, as it already does for channels, this read would drop to **~9.9 KB
   JSON / 1.3 KB gzip and ~20 KB from the DB**.
2. **Repeated fetches: yes, but small ones.** Every view request re-reads the
   same membership rows (`role, channel_order` + `channel_humans`, one round
   trip). The first screen does this 7 times. `/api/v1/auth/session` runs one
   read inside `BEGIN .. SET rls .. COMMIT`, which costs 3 round trips more
   than it needs. A WUI send spends 5 round trips, and 2 of them could be
   folded into others. Most reads that could be combined already are (pgx
   batches: the tenant scope rides the query in one round trip).
3. **Lingering DB handles: none found.** The details are in §4.

## 2. How it was measured

- Tree `91385c6c` (origin/master at measurement). The hub runs over the real
  session door (fake IdP sign-in), in the `TestRoundTripsPerRequest` rig,
  against **local Postgres 16** (`postgres:16-alpine` in docker,
  non-superuser `spool_app` so RLS binds). The hub's pool reaches that
  Postgres through a proxy that **parses the PG wire protocol**. For each
  statement it records the SQL, the rows, the DataRow bytes and the bytes per
  column. It also records round trips (ReadyForQuery) and the bytes in each
  direction.
- Seed per run, in a fresh tenant: 20 lobby lines and 12 topics x 3 lines in
  #lobby; 4 agent peers on one pinned box, with 25 human -> agent DMs each
  plus 5 box-signed agent -> human DMs each (24 DM topics, 120 DMs). Every
  body is 192 B of markdown.
- **n = 3 runs x 5 requests per route.** Every number below was the same in
  all 3 runs to within ±1.5 %, or the table gives its min..max.
- Harness source: `db-payload-audit-2026-10-02.harness.go.txt`. Copy it to
  `csi-spl-api/src/go/spool-hub-api/internal/hub/zz_payload_audit_test.go` and
  run
  `SPOOL_TEST_PG_DSN=... AUDIT_OUT=<dir> AUDIT_BOX_REPLIES=1 go test ./internal/hub -run TestPayloadAudit -v -count=1`.
  It is not committed as a test, because hub Go code was out of this lane's
  scope.
- **Not measured on prd.** The read-only prd query (§6) was refused by this
  agent's permission layer. The prd shape (body sizes, DM counts per owner)
  needs the owner's go. The local seed has short bodies, so it understates
  the env and body share on prd, where agent reports run to KBs.

## 3. Per route (first screen + live socket)

"DB down" is the bytes Postgres sent the hub; "DB up" is what the hub sent
Postgres. The minimum round trips is the figure the hub's
`TestRoundTripsPerRequest` budgets.

| route | DB round trips | statements | DB rows | DB down B | DB up B | JSON B | gzip B |
|---|---|---|---|---|---|---|---|
| `GET /api/v1/auth/session` | 6..8 | 7 | 9..11 | 583..1 228 | 523..1 479 | 697..787 | 367..380 |
| `GET /v1/view/me` | 1 | 3 | 2 | 107 | 323 | 348 | 237 |
| `GET /v1/view/channels` | 6..8 | 12 | 8 | 607..1 350 | 1 319..4 292 | 963 | 374 |
| `GET /v1/view/roster` | 2..3 | 7 | 6 | 544..1 171 | 754..2 324 | 376 | 329 |
| **DM seed** `topics?dm=true&per_topic=50` | 5..9 | 12 | 270 | **106 001..107 565** | 11 444..18 237 | **92 099..92 122** | **13 542..13 722** |
| Flow `topics?limit=12&per_topic=3` | 4..5 | 10..12 | 42..44 | 17 540..17 825 | 2 767..6 356 | 14 144..14 149 | 3 137..3 171 |
| channel page `topics?channel=lobby&limit=20&per_topic=30` | 4..5 | 10..12 | 130..132 | 51 039..51 348 | 6 126..9 910 | 43 916..43 935 | 6 012..6 128 |
| `GET /v1/view/topics/{lobby}` | 4..7 | 10 | 46 | 14 314..15 214 | 2 807..4 800 | 13 805..13 820 | 2 142..2 151 |
| WS hello (2nd tab) | 0 | 0 | 0 | 0 | 0 | welcome 238 + presence 61 | (no WS compression) |
| WS `subscribe all` | 0 | 0 | 0 | 0 | 0 | 33 | |
| WS `send` (lobby) -> ack + message per tab | 5..6 | 13..15 | 2..3 | 416..595 | 2 827..3 048 | ack 254, message 1 101 per tab | |

The DM seed's DB bytes break down as follows (one run, all three identical):

| statement | rows | bytes | heaviest columns |
|---|---|---|---|
| inline messages (`store/view_topics_batch.go`) | 120 | 79 580 | `env` 54 500 (68 %), three `uuid::text` columns 4 320 each |
| topic walk (`store/view_postgres.go` `statement()`) | 24 | 18 072 | `first_msg` 9 616 (the whole first msg, for a 140-char subject), `parties` 4 640 (from@box + to@box of EVERY message) |
| deliveries | 120 | 7 920 | `msg_id::text` 4 320 |
| door + clones + reactions | 4 | ~150 | |

## 4. Database operations: repeats, combinable fetches, lingering handles

| check | finding | evidence (n) |
|---|---|---|
| open / leaked pool connections | **none.** `pool.Stat().AcquiredConns()` is 0 after every request, and the pool ends at 1 total / 1 idle | 8 routes x 5 requests x 3 runs = 120 reads |
| idle in transaction | **none lingering.** `pg_stat_activity` sampled every 0.2 s through 3 runs: 135 idle, 14 active, 1 idle-in-transaction of age 0.00 s (between two statements of one transaction) | 150 samples |
| unclosed `rows` | **none.** All 45 non-test `.Query(` sites close through `scanRows` (`defer rows.Close()`) or `defer br.Close()`. The 7 my grep heuristic flagged were read by hand: all close | static, 45 sites |
| same data read twice in one request | the tenant-scope `set_config` runs once per statement (x2..x6 a request), but it is pipelined in the same batch, so it costs ~20 B down / ~100 B up and **0 extra round trips** | every route |
| same data read once per request, repeated across the screen | the view door reads `role, channel_order` + `channel_humans` on **every** view request (1 round trip, 2 statements). The first screen does this **7 times** | every view route |
| a transaction for one read | `/api/v1/auth/session`: `BEGIN`, `SET app.rls_scope`, the tenant list, `COMMIT` = 3 round trips more than one batch (`store/memberships.go`) | 6..8 round trips, n=15 |
| combinable topic reads | a topics read is door (1) + walk (1) + messages (1) + deliveries+reactions (1) = 4..5 round trips. Deliveries could ride the messages statement (LATERAL `json_agg`) | 4..5, n=15 |
| send path | 5 round trips: a pre-insert `SELECT ts, received_at ... WHERE msg_id` (dedupe), the door, `INSERT messages`, `INSERT deliveries ... 'queued'` + `pg_notify`, then the cap `UPDATE` + `UPDATE deliveries SET state='sent'`. For the box-wui fan-out, the dedupe read could be `INSERT .. ON CONFLICT DO NOTHING RETURNING`, and the row could be written 'sent' straight away | n=15 sends |
| send upload | 2.8 KB goes up for a 192 B body. The INSERT writes the body 3 times: `body`, `msg` (jsonb) and `env` (bytea, which holds the msg again) | n=15 sends |
| pool ping | pgxpool's default `ShouldPing` sends a `-- ping` round trip before handing out any connection idle for more than 1 s (pgx v5.9.2 `pgxpool/pool.go`: `IdleDuration > time.Second`). On a quiet prd hub, the first request of most bursts pays it | seen in the run; `HealthCheckPeriod` already checks in the background |
| tenant row on send | cached: `GetTenant` x3 back to back = 0 DB statements (hot cache, 5 s TTL). It is re-read only after the TTL | n=3 |

## 5. Proposed cuts (not implemented)

Before/after numbers are n = 3 runs. JSON "after" figures are exact: the
same captured responses re-encoded with the cut applied. DB "after" figures
are computed from the per-column bytes measured in §3.

| # | cut | before -> after | files it would touch | risk |
|---|---|---|---|---|
| **1** | **DM seed without inline messages.** The hub returns per-DM `unread` (against the reader's cursors, the way channels-v1 §5.2 already does with `read=`) plus the `count`/`last_ts`/`participants` it already sends; the WUI drops `per_topic=50` | JSON **92.1 KB -> 9.9 KB**, gzip **13.5..13.7 KB -> 1.3 KB**; DB down **106 KB -> ~20 KB**; drops 3 statements (messages, deliveries, reactions) and 1..2 round trips | hub `hub/view.go` (topics handler), `store/view_topics_batch.go`; WUI `stores/channel.ts`, `utils/channel-feed.mjs` (`unreadFromDms`, `dmTotalsFromDms`), `plugins/notify.client.ts` | **medium**: the DM badge semantics of CLE-77845 / CLE-77873 / CLE-77889 (own lines never new, `<new>/<total>`) move to the hub; needs mock + e2e. CLE-77930 owns channel unread, so coordinate |
| 1b | fallback for 1: keep `per_topic`, add a thin projection (`fields=meta`: msg_id, received_at, from, to, from_box, to_box, typed_by, channel) | JSON 92.1 -> 29.4 KB, gzip 13.9 -> 5.5 KB; DB down 106 -> ~48 KB (no `env`, no deliveries/reactions) | same files; the WUI change is one query param | low |
| **2** | **Topic walk: distinct parties, subject-only first message.** `array_agg(DISTINCT ...)` instead of every from@box/to@box; select the subject's first N chars instead of the whole `m.msg` | DB walk per topics read: DM seed 18.1 -> ~8.0 KB, Flow 7.6 -> ~3.7 KB (subject 3 360 B / 1 680 B; parties 800 B / 396 B as sent today). JSON unchanged | `store/view_postgres.go` `statement()` only | **low**: hub-only. Keep the participant order and the subject rule (first line, at most `subjectMax` = 140 runes, `hub/view.go:38`, cut in Go today) |
| **3** | **WS `message` frame: drop the `envelope` copy.** Each frame carries the msg twice, as `envelope` and as `env.msg`. The WUI reads only `env` (`utils/live-ws.mjs` `messageFromFrame`) | **1 101 B -> 706 B per frame per open tab** (-36 %). `hub/wui.go:193` sets no `CompressionMode` (coder/websocket default: disabled), so this is wire bytes | `hub/wui.go` fan-out frame (~line 838); hub tests that read `Envelope` (`wui_test.go innerOf`) | low: only the WUI speaks `/v1/wui/ws` |
| 4 | view message JSON: drop `env.sig` (the WUI deletes it), empty `files`/`reactions`, the default `deliveries:[box-wui sent]`, and `env.msg.task_id` when it equals the topic's | Flow 14.1 -> 11.5 KB (gzip 3.12 -> 2.09 KB); channel page 43.9 -> 36.4 KB (gzip 6.2 -> 6.0); lobby topic 13.8 -> 11.1 KB (gzip 2.10 -> 2.04) | `hub/view.go` encoder; WUI `utils/view-api.mjs` (normalisers must default the missing fields) | low; on the wire mostly cosmetic after gzip, except Flow. It saves browser parse work (CLE-77934 measured ~1.9 s of JS after the Flow list) |
| 5 | per-session door memo: cache `role, channel_order` + `channel_humans` for a short TTL, cleared by the membership/channel-member writers (the `hotCache` pattern, `store/hotcache.go`) | -1 round trip and -2 statements on every view request; **-7 round trips per first screen** | store door read + its writers | medium: membership revocation is then seen within the TTL (hotCache states 5 s) |
| 6 | `/api/v1/auth/session` tenant list as one batch instead of `BEGIN..COMMIT` | 6..8 -> ~3..5 round trips | `store/memberships.go` | low |
| 7 | send path: `INSERT .. ON CONFLICT DO NOTHING RETURNING` instead of the dedupe read; write box-wui deliveries as 'sent' | 5 -> ~3..4 round trips per WUI send | `store/postgres.go`, `store/acks.go` | medium: dedupe and replay semantics (same msg_id resend must return the stored ts) |
| 8 | pool ping: `ShouldPing` on idle > 30 s (background `HealthCheckPeriod` remains) | -1 round trip on the first request of a burst per connection | `store/postgres.go` (pool config) | low |
| 9 | (storage, listed only) the body is stored 3 times per message (`body`, `msg`, `env`) | ~2.8 KB up per 192 B send | schema + every reader | **high**: search/GIN, edits and the signed envelope all depend on it. Not proposed now |

Brief exclusions that overlap: `store/postgres.go` (cuts 7 and 8) and
`hub/view.go` channels (CLE-77930) were out of scope for this lane. Each cut
that touches them needs its own lane, and that lane must be disjoint from
CLE-77930 and CLE-77949.

**Top 3 by bytes saved per page load: cut 1 (or 1b), cut 2, cut 3.**

## 6. Prd numbers still to take (needs the owner's go)

Read-only, as the prd service account, through the named action. One statement
each:

```bash
cd csi-spl-orc && ENV=prd SPL_PROXY_PORT=55953 SQL="select count(*) n, round(avg(octet_length(env))) env_avg, percentile_disc(0.95) within group (order by octet_length(env)) env_p95, round(avg(octet_length(convert_from(env,'UTF8')::jsonb->'msg'->>'body'))) body_avg, count(*) filter (where channel is null) dm_n from messages where tenant_id='t1' and expires_at > now()" ./run -a do_spl_db_query
```

```bash
cd csi-spl-orc && ENV=prd SPL_PROXY_PORT=55953 SQL="select state, count(*), max(now()-state_change) from pg_stat_activity where datname = current_database() group by 1" ./run -a do_spl_db_query
```

