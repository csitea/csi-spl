# Feature Specification: the messaging backbone — keep the Postgres log, or move the spool onto Kafka?

**Feature ID**: `059-messaging-backbone` · **Status**: Decided 2026-10-02: no broker; replicate Kafka's mechanisms on Postgres + files (§9). Spike measured (§10); plan in §11
**Created**: 2026-10-02 · **Lane**: CLE-77931 · **Owner topic**: t1 `302961a0`
**Builds on**: CLE-77929's asks-only comparison (t1 `12d34d3a`, msg `ded808c0`; `fleet_asks` rdb 0097, `csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md` §4.3). That answer covered the asks to the orchestrator. This one covers the whole stack, and it agrees with it.
**Related**: `030-spool-wire-fastpath` (latency), `053-spool-live-delivery` (per-delivery ack, planned), `058-multi-machine-fleet` (many machines).

## 1. The owner's question, verbatim

t1 `12d34d3a`, 02:32Z: "We should not be reinventing the wheel. Let's just implement a mechanism which resembles the main principle of how Kafka works but adjust it for our architecture. Let's have the same guiding principles but use whatever we have: a database, a file system, distributed nodes (those are the agent boxes), the agents"

t1 `2efb3e78`, 02:50Z: "would it be much easier, instead of reinventing the wheel, to actually integrate Kafka into the system?"

t1 `302961a0`, 02:55-02:56Z: "Instead of reinventing the wheel and building a Kafka-like system, should we just integrate Kafka and implement the whole messaging thing on top of Kafka?" ... "Because Kafka is open source, if we do that we will eliminate, first of all, quite a lot of trial and error and whatever reinvent-the-wheel things which are related to messaging. Kafka has all of those things. Basically trick the responsibility of the agents: make them just read certain Kafka things and react to them." ... "Kind of bring complexity to introduce simplicity type of thing"

## 2. The short answer

**No, not the whole stack. Keep Postgres as the log, option (a), and add the one Kafka property we are missing: an instant wake-up across hub processes.**

- **Throughput is not our problem.** prd carries about 1,700 messages a day: about 0.02 a second on average, 44 in the busiest minute of the week. Kafka is built for hundreds of thousands a second.
- **Most of our failures would happen on Kafka too.** Lost escalations, unsigned posts, two machines on one box id and test boxes in the live spool are about state, keys and identity. A broker has none of those. Section 4 checks each one.
- **Kafka would not remove much code.** About 450 of 39,427 Go lines (about 1%) are the queue and the relay that Kafka would replace. Everything else stays: box auth, signing, the browser push, the file mailboxes, rosters, channels, the fallback responder, search, and edit/move/archive. Kafka would be added next to the Postgres message table, not swapped in for it, because messages are rows that get edited, moved, reacted to and searched.
- **"Agents just read Kafka" moves the hard part to every box.** The boxes have no public IP and authenticate with ed25519 keys pinned on the hub. A Kafka client on each box needs a broker it can reach plus its own Kafka credential, which is a second secret on every box. The agents still read files, so a sidecar still has to turn a Kafka record into a file and a terminal poke. That is what the desk sidecar does today.
- **The Kafka property we do lack is cross-process push.** A message stored by one hub process reaches a socket held by another process only through a database poll every 5 s. Browser sockets on a retired revision miss lines until the page polls and re-dials. Postgres `LISTEN/NOTIFY` fixes that at $0, as a hub-internal change that running agents do not see.

## 3. Today's messaging, measured

### 3.1 The path of one message

| hop | what | where |
|---|---|---|
| 1 | an agent writes `spool send`: outbox file, a pending signed envelope, then the submit socket (030) to its box's sidecar | `internal/hubclient/flush.go`, `submit.go` |
| 2 | the sidecar (`spool hub-run`) holds ONE outbound websocket to the hub; the hello is an ed25519 challenge against the box's pinned key | `internal/hub/ws.go` `handleWS`, `helloRefusal`; `pins` rdb 0001 |
| 3 | the hub stores the row once (`messages`, PK `(tenant, msg_id)`, `ON CONFLICT DO NOTHING`), enqueues one `deliveries` row per target box, fans out to the browser sockets it holds, and routes channel posts per member box | `ws.go` `commitRowTyped`; `store/postgres.go` `InsertMessage`, `Enqueue` |
| 4 | push: `ClaimSent`, then a socket write; `Unclaim` when the write fails. A box that is offline gets the queue on its next hello (`drain`, then `queue_end`) | `ws.go` `push`, `drain` |
| 5 | across hub processes (2-3 revisions live during a deploy): every process polls the queue of the sockets it holds every **5 s** | `hub/relay.go`, `SPOOL_HUB_QUEUE_RELAY` |
| 6 | the receiving sidecar verifies the signature against the local pin, writes `<root>/<ID>/inbox/<msg_id>.json` (deduplicated by file name) and pokes the agent's terminal | `hubclient.go` `receive`; `spool/spool.go` `deliverTo`; `notify/queue.go` |
| 7 | browsers: `/v1/wui/ws`, subscriptions per task / channel / peer / all; `fanoutWUI` loops over the browser sockets **of this process only** | `hub/wui.go` |
| 8 | on top: catch-up on reconnect (`acd575ad`), channel back-fill (rdb 0066), fallback responder (rdb 0067), the unanswered escalation (SPL-1225), fleet relay for agents on another machine (`ecd5ac77`), orchestrator asks (`fleet_asks` rdb 0097) | `relay.go`, `fallback.go`, `box_ask.go` |

The hub runs as ONE Cloud Run instance (`min_instances: 1`, `max_instances: 1`, `csi-spl-cnf/csi-spl/all.env.yaml`), because browser fan-out does not cross processes.

### 3.2 The numbers

prd read-only via `ENV=prd ./run -a do_spl_db_query`, 2026-10-02 ~03:00Z, tree `9cdb038e`. The box numbers are from this box's spool root over the same 24 h.

| measure | value | n / source |
|---|---|---|
| hub messages per day, last 7 full days | 723 .. 3,059; median 1,555 | `messages` grouped by day; 12,098 rows in 7 days |
| peak minute, 7 days | **44** (2026-09-27 17:53Z); next 34, 34 | `messages` grouped by minute |
| channel posts | 20-40 % of a day | `channel IS NOT NULL` |
| human posts | 89 .. 387 a day | `from_id LIKE 'HUM-%'` |
| size, body + signed envelope | daily average 1.4 .. 4.6 KB; largest body 26 KB | `octet_length` |
| box fan-out | 13,320 deliveries for 12,080 messages = **1.10 per message** | `deliveries`, 7 days |
| hub queue latency (stored to written to the socket) | p50 0.000 s, p95 0.005 s | `sent_at - received_at`, n = 13,250 |
| sender clock to hub stored | p50 0.60 s, p95 1.53 s (includes box clock skew) | `received_at - ts`, n = 12,098 |
| hub to box, end to end | p50 6 ms, p95 0.72 s, max 4.7 s | spec 053 §4.4, n = 149 prd |
| still queued | 70 rows, **all for test or CI boxes** (`box-e2e-a` since 09-25, `box-rcp-…`, `box-ci`) | `deliveries WHERE state='queued'` |
| DB | 85 MB in total, `messages` 68 MB; db-f1-micro, `max_connections` 25 | `pg_database_size` |
| tenants | 7 with traffic in retention; t1 has 2,653 of 3,408 in the last 24 h | per tenant |
| this box, local spool | 1,683 messages in 24 h, peak hour 152, peak minute 27; 128 senders, 118 recipients; 0 signed (local mode); body p50 696 B, p95 2.4 KB, max 10 KB | `find /var/spool-hub -path '*/outbox/*.json' -mmin -1440` |
| to the orchestrator | 588 of 1,683 (CLE-001); 163 are asks (blocker/task, from CLE-77929) | outbox `to` |
| browser sockets on a retired revision | 26 of 112 outlived their revision, by p50 636 s / p90 2,662 s | `internal/hub/revision.go` header (prd) |

At **10x** (about 30,000 messages a day, about 440 in the peak minute) Postgres sees about 0.35 inserts a second on average and 7 a second at peak. The f1-micro is idle at 1x (spec 029: 1 % of disk, peak 5 of 25 backends). 10x is not a capacity event for any option below.

## 4. Failure modes: what Kafka would and would not change

| # | failure | measured | root cause | would Kafka fix it? | fix on what we have |
|---|---|---|---|---|---|
| F1 | escalations to the orchestrator get lost (`692aefe8`, `2f7996aa`) | about 160 asks a day (CLE-77929) | an ask had no state and no re-raise | **partly.** A consumer group plus offsets gives "the next holder carries on where the last stopped". The ack, the re-raise and telling the owner are still application code | **done**: `fleet_asks` rdb 0097 + `do_spl_asks_tick` (landed `df4fa286..b7270cb8`) |
| F2 | human posts never reached a box (csitea) | 144 posts | the tenant had no `box-wui` pin, so the hub stored the rows **unsigned**, and `routeChannel` skips unsigned rows | **no.** Signing and pins are ours on any transport | `POST /v1/operator/replay-unsigned` (CLE-77876) |
| F3 | sockets on retired revisions | 26 / 112 browser sockets, p50 636 s. A box socket on an old revision stays live, so its queue is split between revisions (058 H1) | sockets live in process memory, and there is no push between processes, only the 5 s poll | **yes**: any shared bus lets every process push | **`LISTEN/NOTIFY`** (section 6, step 1) |
| F4 | two machines on one box id | 058 H1: they evict each other with 4409 in a loop | identity: one pin, one socket per (tenant, box) | **no.** A consumer group would quietly hand the partition to one machine, which hides the same misconfiguration | own box id per machine (058 F2, done) |
| F5 | tests leaking into the live spool | 70 queued rows for test/CI boxes on prd, the oldest 7 days | test boxes seated on prd tenants | **no.** It needs separate topics or clusters, which is the same discipline as separate tenants | prd e2e tenant only + expiry (already 7 days) |
| F6 | "sent" does not mean heard | spec 053 §3 | `deliveries.state='sent'` is set on the socket write; there is no consumer ack | **the same idea**: commit the offset after processing | 053 `TAck` (planned S1/S2, not built: `grep -rn TAck csi-spl-api` finds nothing) |
| F7 | cross-process delivery adds up to 5 s | `relay.go` tick 5 s | polling | **yes** | **`LISTEN/NOTIFY`** (section 6, step 1) |

Kafka changes F3 and F7, the same two that `LISTEN/NOTIFY` changes. It changes F1 and F6 in shape only: they still need the per-message state that `fleet_asks` and 053 already define. It does not touch F2, F4 or F5.

### 4.1 What Kafka would not do for us, on any option

- **Auth to boxes without a public IP.** Boxes dial out to the hub, and the hub checks an ed25519 hello against a pinned key. Kafka adds its own auth (SASL or IAM), so every box would carry a second credential, or the hub stays the gateway.
- **Browser live push.** Browsers do not speak Kafka. The hub keeps `/v1/wui/ws`, the subscriptions and `fanoutWUI`.
- **Hub signing** of browser posts with the `box-wui` key, and verifying on the box.
- **The file mailboxes and the terminal poke.** Agents read `<root>/<ID>/inbox`. Writing a file costs 0.062 ms (spec 030, "do not replace"), so a sidecar must still turn each record into a file and a poke.
- **Tenant isolation.** RLS (rdb 0014) is one model. Kafka ACLs per topic would be a second one to keep in step with it.
- **The message as a mutable row**: edit, kind change, move, archive, reactions, search, history. Kafka is append-only, so the `messages` table stays the system of record either way.
- **Rosters, presence, channel membership, the fallback responder, back-fill.** These are product rules, not transport.

### 4.2 Kafka's principles, mapped to what we already have (the 12d34d3a ask)

| Kafka principle | the spool today | gap |
|---|---|---|
| topic / partition | one queue per (tenant, to_box) in `deliveries`; one per role in `fleet_asks` | none at our volume |
| idempotent producer | `msg_id` PK, `ON CONFLICT DO NOTHING`; the box dedups by file name | none |
| retention + replay | `expires_at` (7 days queue, tiered retention), hello `drain`, catch-up `acd575ad`, back-fill 0066 | a "replay from offset N" read; today replay is "everything still queued" |
| consumer group | `fleet_leases` role holder (0094) + the per-box socket | none for roles |
| commit after processing | `fleet_asks` ack/done; 053 `TAck` planned | build 053 S1/S2 |
| ordering | per (tenant, task) by `received_at, msg_id` | none needed beyond that |
| **push to every consumer the moment a record lands** | **only inside one process; between processes a 5 s poll** | **build section 6 step 1** |

## 5. Options

Prices are list prices checked 2026-10-02 (sources at the end). The estate today is about $60-65 per env per month (047 §4, estimate). The satellite VM, e2-highmem-4 always on, is about $145 a month on top (cnf `060-gcp-vm-satellite`).

| | (a) Postgres as the log, hardened | (b) GCP Pub/Sub | (c) GCP Managed Kafka | (d) Confluent Cloud Basic | (e) Redpanda/Kafka self-hosted |
|---|---|---|---|---|---|
| **extra per env per month, today** | **$0** | ~$0 (10 GiB free; we move ~0.3 GB) | **≥ $140-200** (min 3 vCPU; 2.1-3.0 DCU × $0.09/h) + SSD billed at 100 GB per vCPU + private networking | ~$0 (first eCKU free) | $0 on the satellite; ~$15-30 for its own small VM + disk |
| **at 10x** | $0 | ~$0 | same (capacity unused) | ~$0 (one eCKU) | same |
| **both envs, today** | $0 | $0 | **≥ $280-400**, about 3-6x today's whole estate | ~$0 | $0-60 |
| **ops** | none new | low (managed, IAM) | medium: VPC, Private Service Connect, Cloud Run VPC egress | low, but a new vendor, account and billing | **high**: upgrades, disk, TLS, SASL, backups; one node is a single point of failure for prd messaging |
| **reachability** | already works: boxes dial out, the hub holds the sockets | the hub reaches it over HTTPS with the env SA. Boxes would need an SA key each, so keep the hub as the gateway | **private only** (Private Service Connect): the hub needs VPC egress; boxes cannot reach it without a VPN | public TLS endpoint | the satellite accepts only IAP:22 today and the hub has no VPC egress: new ingress or peering, TLS and SASL |
| **local dev / test** | the memory store + docker postgres:16, as today | Pub/Sub emulator container | a Kafka/Redpanda container | a Kafka/Redpanda container | the same container |
| **effort, first useful step** | **2-3 days** (section 6) | 1-2 weeks (bus + terraform + IAM) | 2-3 weeks (cluster, networking, terraform, client) | 1-2 weeks + account | 1-2 weeks + ongoing upkeep |
| **effort, "agents read Kafka" (the whole stack)** | n/a | 4-8 weeks | 6-10 weeks | 4-8 weeks | 4-8 weeks |
| **what breaks for running agents** | nothing (hub-internal; acks negotiated by hello feature as in 053 §5) | nothing while hub-internal; a fleet-wide sidecar cut-over if boxes consume directly | same as (b), and boxes cannot reach a private cluster | same as (b), plus a Kafka key on every box | same as (b), plus every box reaching the satellite |
| **code it removes** | the 5 s relay poll becomes a backstop | ~450 Go lines (queue + relay, ~1 %), and adds the client and the bus code | same | same | same |
| **risk** | low; LISTEN needs one held connection of 25 (pool 8) | low; a new failure domain on the delivery path | cost, networking | vendor terms; data leaves GCP | prd messaging on an agent machine |

What each option adds that we do not have: (b)-(e) let the hub run more than one instance and several regions behind one bus. (a) gets the same for the 2-3 revisions of a deploy, and for several instances in one region, as long as they share one Postgres.

## 6. Recommendation and the first strangler step

**Recommendation: (a).** At 1,700 messages a day the Postgres log already gives us topics, idempotent producers, retention, replay and per-role consumers (section 4.2). What it lacks is cross-process push, and `LISTEN/NOTIFY` gives that at $0, inside the hub, invisible to running agents. Of the brokers, (b) Pub/Sub is the next step if we ever need several regions or about 100x, and step 1 builds the seam for it.

### 6.1 Step 1 — the hub wake bus (one flow: delivery to a box socket held by another process)

1. A `Wake` interface in `internal/hub` with two methods: `Publish(tenant, box | wui-scope)` and `Subscribe`.
2. Postgres implementation: after `commitRowTyped` stores and enqueues, run `pg_notify('spool_wake', '<tenant>|<box>')` in the same transaction, so a rolled-back row never wakes anyone. Each hub process `LISTEN`s on one dedicated connection and calls the existing `drain` for the sockets it holds. The memory store implements it in process, so tests and lde need no Postgres.
3. Keep the 5 s relay as the backstop. Slow it to 30 s only after step 1 has been live for a week without a gap.
4. Measure: cross-process delivery p95 before (≤ 5 s) and after (target < 100 ms) with `do_spl_delivery_probe` across a deploy; control: the same probe with the bus off.
5. Rollback: `SPOOL_HUB_WAKE=off` falls back to the poll.

### 6.2 Step 2 — browsers on another process

Carry the WUI fan-out events (`task`, `channel`, `peer`) on the same channel. A browser on a retired revision then keeps getting lines until it reloads (F3). This is the precondition for `max_instances > 1`.

### 6.3 Step 3 — 053 S1/S2 (`TAck`)

"Sent" becomes "a live agent was poked" (F6). Spec 053 owns it; this spec only orders it after step 1.

### 6.4 Exit ramp

If the owner later picks (b) or (c)/(d), only the `Wake` implementation changes. Boxes, browsers, signing and the store stay as they are, and the same strangler order applies: hub-internal first, boxes last and only if a box ever needs to consume directly.

## 7. Open question for the owner (answered 2026-10-02, §9)

Pick a-e. If you pick a broker, also say whether boxes should consume from it directly, which means a new credential on every box and a fleet-wide sidecar cut-over, or whether the hub stays the gateway (recommended).

## 8. How this was measured

- prd: `ENV=prd SQL='<one SELECT>' ./run -a do_spl_db_query` (read-only transaction, operator RLS scope), as the prd SA, 2026-10-02 02:58-03:02Z.
- Box: `find /var/spool-hub -path '*/outbox/*.json' -mmin -1440` → 1,683, parsed for `kind`, `to`, `sig`, size.
- Code: `grep -cvE '^\s*(//|$)'` over the files named in section 3.1; total Go (non-test) 39,427 lines; the queue in `store/postgres.go` lines 360-500, `hub/relay.go` 145 lines.
- Code map: tree `b7270cb8` (branch base) / `9cdb038e` (origin/master at writing).
- Sources (checked 2026-10-02): GCP Managed Kafka pricing <https://cloud.google.com/managed-kafka/pricing> and sizing <https://docs.cloud.google.com/managed-service-for-apache-kafka/docs/plan-cluster-size> (min 3 vCPU, 1-8 GiB per vCPU, 1 vCPU = 0.6 DCU, 1 GiB = 0.1 DCU, $0.09/DCU-h in us-central1; europe-north1 not checked); Confluent Cloud <https://confluent.io/confluent-cloud/pricing> (Basic: first eCKU free, then $0.14/eCKU-h); Pub/Sub free tier 10 GiB a month (I believe, not re-checked today; it is CLE-77929's figure).

## 9. The owner's decision, verbatim

t1 `302961a0`, 03:47Z: "Okay so I guess then we just replicate what Kafka does as closely as possible because it has already figured out the wheel." 03:48Z: "But in any case it will be nice to find out what the results are that were established from the tests."

t1 `12d34d3a`, 03:50Z: "Yeah we will not use Kafka. We will just replicate Kafka's working mechanisms."

t1 `2f7996aa` (relayed by CLE-003): "Keep the Kafka style." and "The longer strategy/plan is to have a Kafka-like implementation up until, for example, it's proven that it will not work."

So there is no broker, and §10 is the "prove it will not work" check.

## 10. The spike: NATS JetStream vs single-node Kafka vs today's path vs the Kafka-like design on Postgres

### 10.1 What ran

- **Where:** dev only, on the box machine. Throwaway containers on 127.0.0.1: `nats:2.11-alpine -js`, `apache/kafka:4.1.0` (KRaft, one node) and `postgres:16-alpine`. prd and the live spool root were not touched.
- **Brokers:** one Go harness, `spike/` (`spike run -backend nats|kafka|pgq -test 1..4`). A consumer is a separate process that the test can SIGKILL. It receives, "pokes" (appends a line to a file), then acks.
  - **pgq** is the Kafka-like design on Postgres: one queue row per consumer group, claimed with `FOR UPDATE SKIP LOCKED` under a 5 s lease (Kafka's acquisition lock, NATS's AckWait), acked by marking the row done, and woken by `LISTEN/NOTIFY`.
  - **kafka** commits after each record (`CommitRecords`), which matches our per-message ack.
  - **kafka-batch** is Kafka's usual mode: mark the processed records and auto-commit them every 200 ms.
- **Today's path (the control):** `internal/hub/spike059_test.go` (build tag `spike`, CI never compiles it). It runs the real hub, Postgres store, box websocket, `hubclient` and inbox files in one process.
- **The four tests:**

  | # | test | pass |
  |---|---|---|
  | T1 | 1,000 posts, each to 2 consumer groups, 200 a second (about 270x prd's peak minute of 44) | 0 lost, 0 duplicated, p95 < 3 s |
  | T2 | 2 dispatchers in one group; the first is killed when 500 of the 1,000 are out | 0 lost, 0 duplicated |
  | T3 | a consumer is killed on the 5th of 10 posts, after receiving it and before the poke and the ack; then a fresh consumer starts | the 5th is redelivered, 0 lost, 0 duplicated |
  | T4 | 1,000 posts at 100 a second; the broker (or hub) is restarted at 40 % | 0 lost, 0 acked post replayed |

  Losses and duplicates are counted by msg id. n = 1 run of each test per backend, except pgq T2-T4 (n = 3), today's path T3 (n = 4) and kafka T1/T4 (n = 2). The table shows the first complete run. Tree `bf67561c` + this lane's files.

### 10.2 Results

| | T1 lost / dup, p50 / p95 | T2 lost / dup (failover gap) | T3 redelivered? lost / dup | T4 lost / dup (max gap) | RAM idle after load | image |
|---|---|---|---|---|---|---|
| **today's path** (hub + box socket + inbox file) | 0 / 0, 10 / 24 ms | 0 / 0 (takeover of the box id) | **no: 6 of 10 lost**, 0 dup | 0 / 0 (2.0 s hub restart, p99 0.68 s) | n/a | n/a |
| **pgq: the Kafka-like design on Postgres** | 0 / 0, 4 / 6 ms | 0 / 0; p95 1.3-1.7 s while the dead claim's 5 s lease runs out | **yes**, 0 / 0 (5.2 s = the lease) | 0 / 0 (restart 1.4 s, gap 1.9 s) | 22 MiB | 420 MB |
| **NATS JetStream** | 0 / 0, 0.9 / 1.3 ms | 0 / 0 (13 ms gap) | **yes**, 0 / 0 (5.0 s = AckWait) | 0 / 0 (restart 0.8 s, gap 2.1 s) | **13 MiB** | 40 MB |
| **Kafka, commit per record** | 0 / 0, **4.0 / 8.4 s** (run 1: 1.9 / 3.6 s) | 0 / 0, p95 9.5 s | **yes**, 0 / 0 (6.0 s = session timeout) | 0 / **2** (gap 12 s) | **440 MiB** | 678 MB |
| **Kafka, batched commit (its normal mode)** | 0 / 0, 12 / 32 ms | 0 / **3** (4.5 s gap) | **yes**, 0 / **4** | 0 / **5** (gap 27 s) | 440 MiB | 678 MB |

### 10.3 What the numbers say

1. **Nothing measured shows that the Kafka-like design on Postgres will not hold.**
   - pgq passed all four tests: 0 lost and 0 duplicated in every run, n = 3 for T2-T4.
   - It did 4 / 6 ms (p50 / p95) at 200 posts a second into 2 groups. That is about 270x prd's peak minute, on the same `postgres:16` we run.
   - Its one slow number is by design. The posts a killed consumer had claimed wait out the 5 s lease (T2 p95 1.3-1.7 s, T3 5.2 s), the same as NATS's AckWait and Kafka's 6 s session timeout.
2. **Today's path has one real hole: there is no consumer ack (T3).**
   - The hub marks a delivery `sent` when it writes the frame to the socket.
   - A box that dies before its inbox write loses that message and every frame already in flight: 6 of 10, n = 4 runs.
   - The hub then holds **0 queued rows** for the box, so a reconnect cannot bring them back (control: `QueuedFor` after the crash = 0).
   - In production the same window opens whenever a socket dies with frames still in its buffers: a laptop sleeping, NAT, a revision retired.
   - This is the gap that consumer commits (§11, S2) close, and it is spec 053's `TAck`.
3. **Kafka is the worst fit for our shape.**
   - It acks one message at a time per agent, and a sync commit per record capped it at about 115 records a second here, so T1's p95 reached 3.6-8.4 s.
   - Its normal batched commit is fast but replays up to 200 ms of work after a failover, crash or restart (3, 4 and 5 duplicates).
   - It uses 440 MiB of RAM idle, against 13-22 MiB for the others.
4. **NATS JetStream is the best broker here:** fastest, smallest, and it passed every test. It is still a broker to run, secure and reach from boxes without a public IP (§4.1, §5). It stays the reference point, not the plan.
5. **Duplicates are survivable on every path,** because the box already dedups by file name (`<ts>--<from>--<slug>-<id>.json`). Caveat: that same dedup hides duplicate frames from today's-path T2/T4, so those zeros count inbox files, not frames. T1 counts frames (`Session.Delivered`).

### 10.4 Decision inputs

- **Code the broker would replace, against what it adds** (non-blank, non-comment lines):
  - Hub delivery code a broker could take over: relay 145, fallback 237 + 171, leases 78 + 60, asks 162 + 110 (**963 Go**).
  - The bash sweeps and leases: dispatch lease 416, unanswered sweep 278, asks tick 136, unheard report 43, responder sweep 25 (**898**).
  - The broker bridge and consumer in the spike: **413 Go** for three backends, about 100-150 each, plus 94 for the consumer loop. A real bridge would also need auth, per-box credentials, a WUI path and ops scripts (§4.1).
  - Most of the 963 + 898 is product logic: who responds, when to escalate, the lease. A broker would still need it, as consumer code.
- **Failure classes:**
  - unheard posts: a broker shows them as consumer lag and so does §11 S4; a responder rule is still ours.
  - double dispatch: a consumer group fixes it, and so does §11 S5 on Postgres.
  - poking dead panes: no broker knows a pane. That is 053's ack outcome, on any path.
- **Ops on the box machine:**
  - NATS: one 40 MB container with a file store.
  - Kafka: a JVM, 440 MiB idle; its CLI tools need the advertised listener to be reachable from inside the container.
  - pgq: nothing new, because it is the Postgres we already run.

## 11. The plan: each Kafka concept and our implementation

The plan is one design for the whole stack. CLE-77931 builds the whole-stack rows. CLE-77929 builds the asks rows in §11.2, as agreed on 302961a0. Every step goes hub first and is negotiated by a hello feature, so running boxes and old sidecars behave as today (the 053 §5 rules).

### 11.1 Messages and deliveries (CLE-77931)

| Kafka | ours | today | step |
|---|---|---|---|
| broker + commit log | the hub (Cloud Run) + Cloud SQL Postgres; `messages` is the record, `deliveries` the per-consumer log | yes | — |
| topic | a delivery target: a box `(tenant, to_box)`; a channel is a topic fanned out to member boxes; a browser subscribes per task / channel / peer | yes | — |
| **partition + offset** | **one partition per `(tenant, to_box)`; `deliveries.seq` is assigned from `box_offsets.next_seq` under the per-box advisory lock `Enqueue` already takes, so seq order = commit order** (a plain identity column could commit out of order and let a reader skip a row) | no offset; `received_at` only | **S1** (rdb next free number) |
| producer `acks=all` | the hub answers `sent` only after the Postgres commit | yes | — |
| idempotent producer | `messages` PK `(tenant, msg_id)` `ON CONFLICT DO NOTHING`; the box re-sends a pending file with the same id | yes (T4: 21 re-sends, 0 dup) | — |
| fetch long-poll / leader notify | `pg_notify('spool_wake', tenant|box)` in the commit transaction; every hub process `LISTEN`s and pushes to the sockets it holds; the 5 s relay poll stays as the backstop | 5 s poll | **S1** |
| **consumer commit after processing** | **the box sends `commit {seq, outcome}` after the inbox write + poke (outcome = 053's TAck); the hub stores `box_offsets.committed_seq`. A hello replays `seq > committed_seq`, not "rows still queued"** | none: "sent" = written to the socket (T3: 6 / 10 lost) | **S2** (FeatureCommit). Acceptance: spike T3 on today's path reads 0 lost |
| idempotent consumer | the inbox file name dedups a replayed seq | yes | — |
| consumer seek / replay | hello `from_seq`; browsers reconnect with a `since` cursor (`received_at, msg_id`) and get the gap from the DB, on any process | revision poll + catch-up read | **S3** |
| cross-instance fan-out | browser events on the same wake channel, so `max_instances > 1` becomes possible | one instance only | **S3** |
| consumer lag | per box `next_seq - 1 - committed_seq` and the age of the oldest uncommitted row: `do_spl_consumer_lag` + an alert; feeds 053's escalation | the unheard sweep (heuristic) | **S4** |
| retention | queue rows expire after `QueueTTL` (7 days); committed rows are pruned; tiered message retention unchanged. An uncommitted row for a dead box (the 70 test-box rows on prd) is reported as lag, not kept silently | expiry only | **S4** |
| consumer group (one member active) | a box id = a group with one live member (the last hello wins, 4409); a takeover = a rebalance (058) | yes | — |
| consumer group for a role | a channel post routed to the **role holder's** box (`fleet_leases`) instead of every member box, so a dispatcher seated on two machines handles each post once | per member box (058 H7) | **S5**, with CLE-77911 |
| exactly-once (transactions) | not copied: at-least-once + the idempotent consumer, as the spike shows that is enough | — | — |

### 11.2 Asks to the orchestrator (CLE-77929): a work queue = Kafka's share group (KIP-932)

CLE-77929's table, as sent on 302961a0 (msg 468ccbbd):

| Kafka (share group) | asks today (rdb 0097, on trunk) | delta |
|---|---|---|
| topic | `role` (orch; dispatch next) within a fleet | none |
| record key + idempotent producer | `ask_id` = the spool msg_id; put ON CONFLICT DO NOTHING | none |
| acquire (acquisition lock) | `ack` = acked_by `<ID>@<box>` | **an acquisition lock timeout:** an acked ask not closed within `ASKS_LOCK_MIN` goes back to available and is re-delivered |
| accept / reject | `done` / `declined` (reason required) | none |
| release / redelivery | re-raise of an unacked ask after `ASKS_RERAISE_MIN` | none |
| delivery count | `raised_n` | **a max delivery count:** at N, the ask goes to the owner instead of being re-raised forever |
| membership / rebalance | the fleet lease's orch holder; a handover message to a new holder | none |
| retention / replay | closed asks pruned after 7 days; `do_spl_asks_open ASKS_ALL=1` + the journal | none |
| log on disk per broker | `<spool root>/asks/<id>.json` + `journal.log` | none |

The pgq prototype in §10 is this same share-group shape (row claim + lease + per-record ack), and it passed T2-T4 n = 3.

### 11.3 Order

S1 (offset + wake), then S2 (commit; closes the T3 loss), then S3 (browsers), then S4 (lag + retention), then S5 (role group). The asks deltas go in parallel. Each step lands on dev and prd before the next one starts.

<!-- version: 0.2.0 · updated: 2026-10-02 -->
