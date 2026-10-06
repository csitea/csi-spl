# 094 Hub multi-instance: N >= 2 hub instances, one delivery contract

Status: **v0.1, spec only, 2026-10-06.** No code, terraform, cnf or Cloud Run
setting was touched by this lane; `max_instances` stays 1 until R18 has the
owner's go (money) and R15 has landed (connections).
Availability plan: [row R17](../../doc/md/availability-plan-20261004.md)
(weakness 2.1.1), implemented by row R18.
Topic: t1 `2c74edd5-d87d-4ceb-a5f7-a700085ba461`. Author: c-364.
Builds on: [059 messaging backbone](../059-messaging-backbone/spec.md)
sections 6.1, 6.2 and 11 (the wake bus, steps S1 and S3, both on trunk and live).

## 0. Why

The hub is one Cloud Run instance (`min_instances = max_instances = 1`). Every
box socket and every browser socket ends on it, so a routing stall after a
rollout refuses everything until a fresh revision gets the slot:

| when (2026-10-06, prd) | what | ended by |
|---|---|---|
| 04:12:56 .. 04:25:38Z | 12 min 44 s of 429 "no available instance", ~1161 refusals, revision 00452-2zs | a fresh revision 00453-8c6 |
| 04:56:49 .. 04:57:48Z | 69 of 977 requests 429 on the r3 rollout, revision 00454-f5b | the deploy action's own fresh revision 00455-fb6 (msg ca8a1031) |

The plan's incidents I-01..I-05 (21 bursts, 1 490 x 429 over 16 days) are the
same class. R01 heals a stall after the fact; only a second instance removes
the single slot. The owner (2026-10-06, after the outage): the hub must not be
capped at one instance.

Lifting the cap is unsafe today: several frames still reach only the sockets
held by the process that produced them (section 2.3). This spec closes those
gaps and states the delivery contract that makes N instances correct.

## 1. Measured before (tree `3bb3306ed66290fb45d81654aeadaa9ae67ca2ee`)

### 1.1 Live settings, n = 2 envs (dev, prd), 2026-10-06

Read as each env's project SA (throwaway `CLOUDSDK_CONFIG`,
`CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`, `--account` on the call):
`gcloud run services describe csi-spl-hub-<env> --region=europe-north1`.

| env | maxScale | minScale | sessionAffinity | cpu-throttling | concurrency | ready revision |
|---|---|---|---|---|---|---|
| dev | 1 | 1 | false | false | 1000 | csi-spl-hub-dev-00456-vrj |
| prd | 1 | 1 | false | false | 1000 | csi-spl-hub-prd-00455-fb6 |

### 1.2 Code and cnf (each line carries its check)

| fact | check |
|---|---|
| cap in cnf | `grep -n 'm[ai][xn]_instances' csi-spl-cnf/csi-spl/all.env.yaml` -> 320 `min_instances: 1`, 321 `max_instances: 1` |
| affinity follows the cap (ffa68befc) | `grep -n session_affinity csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf` -> 53 `= var.max_instances > 1` |
| pool per process | `grep -n DB_MAX_CONNS csi-spl-cnf/csi-spl/all.env.yaml` -> 357 `"8"`; the listener is one more, outside the pool (`internal/store/wake.go:85-95`, `pgx.ConnectConfig`) |
| DB tier | `grep -n 'tier:' csi-spl-cnf/csi-spl/all.env.yaml` -> 179 `db-f1-micro`: 25 connections, 3 superuser-reserved, 2 cloudsqladmin (cnf comment 352-356) |
| a box socket is found in process memory | `internal/hub/ws.go:336` `register`: `s.boxes[(tenant, box)] = x`; `ws.go:377` `boxSession` reads the same map |
| the box wake bus | `internal/hub/wake.go` `RunWake`; channel `spool_wake` (`internal/store/wake.go:19`), payload `<tenant>|<box>`, sent in the commit transaction; every process `LISTEN`s, `heldBox` drops a box it does not hold, `pushQueued` claims each row (no double send) |
| the browser wake bus | `internal/hub/wui_wake.go`; channel `spool_wui` (`internal/store/wui_wake.go:18`), payload `<tenant>|<msg_id>` or `<tenant>|f:<member>` (flow marks); the storer marks its own msg id (`fannedSet`, 4096) |
| the backstop | `internal/hub/relay.go` `RunRelay`: every 5 s each process pushes the queued and unacked rows of the boxes IT holds |

So OQ-05 ("max-instances = 1, so live dispatch is an in-process socket map",
spec 003 plan) is still the assumption, but its two main paths (a queued row
for a box, a new message for a browser) are already cross-process since spec
059 S1/S3. What is left is section 2.3.

## 2. Model

### 2.1 Terms

- **instance**: one hub process (one Cloud Run container instance). Its id
  `iid` = `$K_REVISION` + `/` + a random 6-hex per process start
  (`revisionOr` already makes the second half for lde).
- **holder**: the instance a socket terminates on. A socket has exactly one
  holder for its life; Cloud Run never moves an open WebSocket.
- **frame bus**: Postgres `LISTEN/NOTIFY` on the database every instance
  already uses (the 059 choice: $0, no new service, at ~1 700 messages/day
  far below any NOTIFY limit). Pub/Sub stays 059's exit ramp (6.4); only the
  `Waker` implementation would change.

### 2.2 The delivery contract

1. **Durable first.** A message, edit, reaction, delete, move, merge, archive
   or issue change is committed to Postgres before any frame about it is
   sent. The database is the only truth; a frame is a hint that something
   committed.
2. **Any instance, same answer.** Every REST read and every catch-up read
   (`view-v1 after=<cursor>`, the box hello drain) is answered from the
   database by whichever instance gets the request. Nothing a client needs
   lives only in one instance's memory (section 2.3 lists what does today).
3. **Every holder hears every commit.** Each commit that has a live frame is
   announced once on the frame bus; every instance listens; an instance acts
   only for the sockets it holds. Delivery to a socket = the holder writes
   the frame.
4. **At-least-once, idempotent at the edge.** A box row is claimed before it
   is pushed (`pushQueued`, unchanged), so a wake, a relay tick and a hello
   drain never send one row twice. A browser frame carries the ids the store
   already dedups on (`msg_id`, the edit's revision); a duplicate is harmless,
   a gap is healed by the catch-up read.
5. **A lost notify costs latency, never data.** NOTIFY is not durable: a
   listener that is reconnecting misses what was sent meanwhile. The relay
   (box rows, 5 s) and the browser's catch-up on reconnect / revision change
   cover it. Target: cross-instance p95 < 1 s with the bus, <= 5 s without it.
6. **Correctness never depends on session affinity** (2.4).

### 2.3 What is still per process (the gap list R18 closes)

Found with `grep -n 'range s.wui\|s.wui\b' internal/hub/*.go` (14 non-test files) and
the `Server` struct (`internal/hub/server.go`). Each row: what breaks with 2
instances, and the fix.

| # | state / path | today | breaks with N = 2 | fix |
|---|---|---|---|---|
| G1 | edit, delete, hide (`edit.go:296`, `edit.go:442`, `demo_moderation.go:290`) | `fanoutEdited` / `fanoutDeleted` / `fanoutHidden` walk `s.wui` | a browser on the other instance shows the old text until it reloads | frame bus, `spool_frame` (2.5) |
| G2 | reactions, merge, move, topic archive, issues (`reactions.go:172`, `merge.go:259`, `message_move.go:362`, `topic_archive.go:353`, `issues.go:414`) | same | same | same |
| G3 | channel sidebar frame (`wui.go:1192` `fanoutChannel`, `fanoutChannelFrame`) | same | a new / renamed channel appears only on one instance | same |
| G4 | box presence frames (`channels.go:342` `presence`) and the `left` map (`ws.go:357` `drop`) | in process; other instances learn "offline" only when the shared stamp ages out (2 x the presence period) | a box that left shows online elsewhere for up to the TTL | publish the presence frame on the bus; a receiver also sets its `left[k]` |
| G5 | human presence `s.online` (`channels.go:402`, read by `search.go:467`) | a count of this process's browser sockets | a member on instance B reads offline to viewers on A | per-instance counts carried on the bus (`hum_online` +1/-1 with `iid`), summed per (tenant, member); an `iid` silent for 2 x the presence period is dropped (crash) |
| G6 | box roster broadcast (`ws.go:487` `broadcastRoster`) | to boxes in `s.boxes` | a box on B never hears a roster change from A | bus, box-addressed frame |
| G7 | tail followers (`ws.go:988` `notifyTail`) | to `s.sessions` that follow the task | a `spool tail --follow` on B misses lines stored via A | bus, box-addressed frame (payload = the env ref; the holder loads the row, as `FanoutRow`) |
| G8 | "last hello wins" (`ws.go:336` `register` closes the old socket 4409) | only if both sockets are on one instance | a box that redials onto B while its half-dead socket still sits on A is held twice; rows can be claimed by the dead socket and wait for the ack timeout | `box_seat` announcement on hello: every other instance closes its socket of that (tenant, box) with 4409; a per-box seat generation in the hello transaction fences a late announcement |
| G9 | upload tokens (`server.go:503` `mintToken`, `resolve.go:213` `bearerAny`, `demo.go:52`) | a per-process map | a token minted over a box socket on A is refused (`unknown_token`) by a PUT that lands on B: the box client has no cookie jar, so no affinity can save it | store `sha256(token)`, tenant, box, member, expires in Postgres (RLS like every tenant table; an insert per mint, a primary-key read per upload); never the token itself |
| G10 | member socket close (`demo_stay.go:126` `closeMemberSockets`, after `SweepDemo`) | closes this process's sockets of the ended members | the sweep that wins the rows returns `Ended`; the other instance's sockets of those members stay open | bus, `close_member` frame |
| G11 | per-instance limiters: edge per-IP caps and global socket cap (`edge.Guard`), `keysLim`, `evLim`, `searchRate` | per process | each limit becomes N x as loose | accept for N = 2 and say so in cnf; the global cap is per instance on purpose (it guards that instance's memory) |
| G12 | sweepers: files (`file_retention.go:47`), demo, backfill | every process runs them | files: N GCS listings per period, deletes race harmlessly; demo: one winner (claim in the store) | a `pg_try_advisory_lock` per sweep: one instance runs it, the others skip that tick |
| G13 | `fileUsage`, `humans`, `hosts` caches | per process | a cache on B is stale for its TTL after a write on A | accept (each has a TTL or re-reads); list them in the code comment of each |

Already cross-instance, unchanged: a queued row for a box (`spool_wake`), a new
message for browsers (`spool_wui`), flow marks (`f:`), the escalation sweeps
(`fallback_deliveries` claim per msg), the role lease (`fleet_leases`).

### 2.4 Session affinity

- Cloud Run session affinity is a best-effort cookie (`GAESA`) for HTTP
  requests from a browser. It never applies to the box client (no cookie jar)
  and it does not survive a scale-in, a rollout or an instance crash. So it
  cannot be a correctness mechanism; contract item 6.
- After 2.3 nothing needs it. Its only benefit would be cache locality (G13),
  and its cost was measured in ffa68befc: ~4.1 KB of uncompressible cookie
  per signed-in `/lobby` load against 1.5 KB of payload.
- **Proposed: affinity stays OFF with N >= 2** (Q2). R18 changes
  `04-cloud-run-service.tf:53` from `var.max_instances > 1` to a cnf flag
  `hub.cloud_run.session_affinity` (default `false`), in the same commit that
  raises the cap, so the GAESA cost does not come back silently. If a later
  measurement shows a cache that matters, turn it on by cnf with that number.

### 2.5 The frame bus: one more channel

`spool_wake` and `spool_wui` stay as they are. One new channel carries
everything in 2.3 that is a live frame:

- channel `spool_frame`, payload (UTF-8, < 7 900 bytes, NOTIFY's limit is
  8 000): `v1|<iid>|<tenant>|<kind>|<json>`.
- `kind`: `wui` (a browser frame + its audience: task, channel or member set),
  `box` (a box frame + target boxes, or "all boxes of tenant"),
  `box_seat` (tenant, box, seat gen), `hum_online` (tenant, member, +1/-1),
  `close_member` (tenant, members, reason).
- A receiver skips its own `iid` (the producer already delivered locally),
  then runs the SAME local fan-out function the producer ran (`fanoutEdited`
  etc. are split into "build frame" and "deliver to my sockets").
- **Too big for one notify**: the payload carries a reference instead of the
  frame (`ref:<table>/<id>`), and the receiver loads the row, as
  `wuiWakeWorker` already does with `FanoutRow`. A receiver that cannot load
  it sends its browsers of that tenant a `resync` frame (the WUI runs its
  catch-up read). Never truncate.
- **When it is sent**: inside the committing transaction where the write
  already is one (`pg_notify` is delivered on COMMIT, never on ROLLBACK, as
  `spool_wake`), else right after the commit on the same pool connection.
  Never before the commit (contract 1).
- **Listening**: the existing listener connection adds `LISTEN spool_frame`;
  no new connection (the S3 rule).
- **Kill switch**: `SPOOL_HUB_WAKE_FRAME` (default on), like `SPOOL_HUB_WAKE`
  and `SPOOL_HUB_WAKE_WUI`. Off = today's in-process fan-out only.
- **Memory store**: fans out in process, as `ListenWakes` does, so unit tests
  and lde need no Postgres; a test can run two `Server`s on one memory store
  to get two instances.

### 2.6 How a frame for a socket on another instance is delivered

| producer on A | bus | holder B |
|---|---|---|
| box row committed for box X | `spool_wake` `<t>|X` in the tx | `heldBox(t,X)` -> `pushQueued` claims and sends (unchanged) |
| message stored | `spool_wui` `<t>|<msg_id>` in the tx | `holdsWUI(t)` -> `FanoutRow` -> `fanoutWUI` (unchanged) |
| edit / reaction / move / ... (G1-G3) | `spool_frame` `wui` | its browsers in the audience get the same frame |
| box hello on A (G8) | `spool_frame` `box_seat` | B holds X with a lower seat gen -> close 4409 |
| presence / roster / tail (G4, G6, G7) | `spool_frame` `box` / `wui` | its sockets get the frame; G4 also sets `left` |
| upload token minted on A (G9) | none: a database row | B's `bearerAny` reads the row |

## 3. Connection budget (depends on R15)

Per instance: pool `SPOOL_HUB_DB_MAX_CONNS` (8) + 1 listener = 9.
Usable on `db-f1-micro`: 25 - 3 reserved - 2 cloudsqladmin = 20, of which
~4 are kept for operator psql (`do_spl_*`), so 16 for the hub.

| shape | instances alive | connections | fits 16? |
|---|---|---|---|
| today, steady | 1 | 9 | yes |
| today, rollout overlap | 2 | 18 | no, already 2 over (the cnf comment counts 16, not the listener) |
| N = 2, steady | 2 | 18 | no |
| N = 2, rollout overlap | 4 | 36 | no |

So R18 cannot ship on the shared-core tier at pool 8. Two ways out:

1. **R15 first (the plan's order):** prd on a dedicated-core tier, ~100
   connections: N = 2 with a rollout overlap needs 36, leaving ~60. The pool
   stays 8.
2. dev only, without R15: `SPOOL_HUB_DB_MAX_CONNS: "3"` on dev puts the
   rollout overlap at 4 x 4 = 16. Good enough for the R18 proof run on dev
   (low traffic); never for prd.

Rule R18 adds as a cnf comment and a conf-validator check:
`(max_instances x 2) x (DB_MAX_CONNS + 1) <= db usable - 4`
(the factor 2 is the rollout overlap: old and new revision both at max).

## 4. Rollout and rollback

### 4.1 Order (each step on dev, then prd, before the next)

| step | what | gate before the next |
|---|---|---|
| M1 | code: G1-G13 behind `SPOOL_HUB_WAKE_FRAME` (default on), with N = 1 still | module tests + 5.1 green; prd runs a day with no new ERROR line from the bus |
| M2 | `upload_tokens` migration (DDL first on dev + prd, the store rule), then the code that reads it | `PRE_PUSH_TIER=full` green; an upload on prd works |
| M3 | R15 applied (owner's go) | `instances describe` shows the new tier; `max_connections` >= 100 |
| M4 | cnf `max_instances: 2`, `min_instances` per Q1, affinity per Q2, the budget check (3); the 030 apply with the owner's go | the R18 proof (6) on dev, then prd |

### 4.2 Rollback

- Bus defect, N still 1: `SPOOL_HUB_WAKE_FRAME=false` in cnf + the hub
  deploy; the hub falls back to in-process fan-out, as today.
- N = 2 misbehaves: cnf `max_instances: 1` + the 030 apply (an apply, so
  the owner's go, as every apply). Open sockets on the removed instance
  close; boxes redial with backoff (OQ-05 reconnect), browsers reconnect and
  catch up. Nothing durable is lost (contract 1).
- `upload_tokens` stays after a rollback; it is correct for N = 1 too.

### 4.3 What a rollout looks like with N = 2

The new revision starts its instances while the old ones still hold sockets.
Both revisions listen on the same database, so a frame produced on the new
revision reaches a browser still on the old one: the Bug B class
(`revision.go`) stops depending on the WUI's revision re-dial. The
re-dial stays (it moves sockets off a retired revision).

## 5. Test plan

### 5.1 Unit and store tests (Go, `internal/hub`, memory and Postgres)

| test | asserts | control |
|---|---|---|
| `TestTwoInstancesEditFanout` (G1-G3) | two `Server`s on one store; a browser socket on B, an edit / reaction / move / archive / channel frame produced on A; B's browser gets each frame once | `SPOOL_HUB_WAKE_FRAME=false`: B's browser gets 0 frames |
| `TestTwoInstancesPresence` (G4, G5) | box leaves A -> B's roster reads offline at once; member opens a tab on B -> A's search reads online | bus off: B reads online until the TTL |
| `TestTwoInstancesSupersede` (G8) | box X hello on A, then on B -> A's socket closed 4409 within 1 s; a late `box_seat` with a lower gen closes nothing | bus off: both sockets stay open |
| `TestUploadTokenAnyInstance` (G9) | mint on A, upload on B -> 200; expired -> 401 `expired_token`; the DB holds only the hash | the per-process map (old path) -> 401 `unknown_token` |
| `TestTwoInstancesCloseMember` (G10) | demo stay ends via A's sweep; B's socket of that member is closed 4401 | bus off: B's socket stays |
| `TestSweepOneLeader` (G12) | two `RunSweeper`s; the files sweep runs once per period | lock off: twice |
| `TestFrameTooBig` | a frame over 7 900 bytes goes as `ref:`; the receiver loads it; an unloadable ref sends `resync` | — |
| `TestFrameNotSentOnRollback` | a write that rolls back announces nothing (Postgres only) | — |

Every new test has its control in the same file, so a test that cannot fail
is caught (the "new testid passes vacuously" trap).

### 5.2 Gates

`bash csi-spl-api/src/bash/tests/run-all-tests.sh`; store and migration
changes run `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (Postgres); the
clean-code gate (new functions <= 80 lines).

### 5.3 Live checks before raising the cap (dev, N = 1)

- The welcome frame (box and browser) carries `iid` (2.1), so a probe can see
  which instance holds each socket.
- `do_spl_delivery_probe` gains `PROBE_CROSS=1`: it keeps opening sender
  sockets until the sender's `iid` differs from the receiver's, and reports
  only those pairs. With N = 1 it reports n = 0 cross pairs, which is the
  control that the filter works.

## 6. The R18 proof (done = both, on dev then prd)

| claim | how | pass |
|---|---|---|
| a rollout with 2 instances refuses nothing | a real hub deploy with `max_instances: 2`; Cloud Run request logs for the service from deploy start to +15 min, `httpRequest.status = 429` | 0 x 429, n = every request in the window (stated) |
| cross-instance delivery < 1 s | `ENV=<env> DRY_RUN=0 PROBE_CROSS=1 PROBE_N=100 ./run -a do_spl_delivery_probe` (test tenant `e2e` only) | n >= 100 cross-instance pairs, max < 1 s, 0 misses; the same run with `SPOOL_HUB_WAKE_FRAME=false` shows the gap for edits (control) |
| a box on the other instance | a box socket on A, a message sent via B, time to the box's inbox | n >= 100, p95 < 1 s (today's S1 target is < 100 ms) |
| connections | `do_spl_db_health` during the rollout | peak <= the budget in 3 |

Each claim is reported with the cnf version / revision it ran on, the sha and
n (the cross-lane rule).

## 7. Out of scope

- The code (R18), the `max_instances` change and its money (R18, owner's go),
  the DB tier (R15, owner's go), the ingress front (R16).
- Moving off Postgres NOTIFY (059 section 6.4 exit ramp).
- Multi-region.

## 8. Open questions for the owner (asked by R18, not by this lane)

| # | question | options |
|---|---|---|
| Q1 | `min_instances` with the cap at 2 | 1: pay for the second instance only under load, but a stall right after a rollout may still find no warm spare; 2: a warm spare always (the plan's ~+45 EUR/mo per env) |
| Q2 | session affinity with N >= 2 (2.4) | off (proposed: nothing needs it, it costs ~4.1 KB per page load); on |
