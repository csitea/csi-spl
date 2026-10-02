# Feature Specification: the messaging backbone — keep the Postgres log, or move the spool onto Kafka?

**Feature ID**: `059-messaging-backbone` · **Status**: Proposed (assessment; nothing is built until the owner picks a-e)
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

## 7. Open question for the owner

Pick a-e. If you pick a broker, also say whether boxes should consume from it directly, which means a new credential on every box and a fleet-wide sidecar cut-over, or whether the hub stays the gateway (recommended).

## 8. How this was measured

- prd: `ENV=prd SQL='<one SELECT>' ./run -a do_spl_db_query` (read-only transaction, operator RLS scope), as the prd SA, 2026-10-02 02:58-03:02Z.
- Box: `find /var/spool-hub -path '*/outbox/*.json' -mmin -1440` → 1,683, parsed for `kind`, `to`, `sig`, size.
- Code: `grep -cvE '^\s*(//|$)'` over the files named in section 3.1; total Go (non-test) 39,427 lines; the queue in `store/postgres.go` lines 360-500, `hub/relay.go` 145 lines.
- Code map: tree `b7270cb8` (branch base) / `9cdb038e` (origin/master at writing).
- Sources (checked 2026-10-02): GCP Managed Kafka pricing <https://cloud.google.com/managed-kafka/pricing> and sizing <https://docs.cloud.google.com/managed-service-for-apache-kafka/docs/plan-cluster-size> (min 3 vCPU, 1-8 GiB per vCPU, 1 vCPU = 0.6 DCU, 1 GiB = 0.1 DCU, $0.09/DCU-h in us-central1; europe-north1 not checked); Confluent Cloud <https://confluent.io/confluent-cloud/pricing> (Basic: first eCKU free, then $0.14/eCKU-h); Pub/Sub free tier 10 GiB a month (I believe, not re-checked today; it is CLE-77929's figure).

<!-- version: 0.1.0 · updated: 2026-10-02 -->
