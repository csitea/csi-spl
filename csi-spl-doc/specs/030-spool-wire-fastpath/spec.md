# Feature Specification: the wire fast path — delivery and visibility under 0.3 s

**Feature ID**: `030-spool-wire-fastpath` · **Milestone**: M3
**Created**: 2026-09-21 · **Lane**: WIRE-PROTOCOL-FASTPATH (CLE-3436)

**Owner input (verbatim, 2026-09-21)**: "we need to change the client's and
server protocol to enable faster comms".

**Owner architecture question (verbatim, 2026-09-21)**: "could it be that this
file based does not work here in the web ui approach, aka should we use some
kind of web sockets + streaming approach from the client till the server and
back".

**Builds on**: 002 (the file is the record), 003 (`contracts/http-v1.md` the box
socket, `contracts/wui-live-ws.md` the browser socket), 020 (inner `v:2`
readers, the mixed-fleet rule), 027 (the hub's own hot path), 028 (the terminal
leg). Coordinates with CLE-3435 (end-to-end latency budget), CLE-3434 (the desk).

**Contracts (this dir)**: `contracts/fastpath-v1.md` — the hello capability
negotiation and the frames it enables.

---

## 0. The answer to the owner's question, with the numbers

**Short answer: the file is not the problem, and the sockets are already there.
Do not rebuild 002.**

Both interactive legs are **already WebSockets and neither polls**: the browser
holds one socket to the hub (`/v1/wui/ws`) and the box sidecar holds one
(`/v1/ws`). The hub already pushes the **whole message body** on both — there is
no notify-then-fetch to remove. The "file" is only the box-side mailbox, and it
is the durable, replayable record every CLI agent reads.

Measured on this box against the live hubs on 2026-09-21. **Version**: hub
`0.1.17`, commit `39a5a25ae53df8436359ad64f49e42dcb271bb03`, `GET /version` on
both `dev.api.spool-hub.ai` and `api.spool-hub.ai`. **Tree**: `csi-spl`
@ `24d44a1`. **n** is per row.

| hop | p50 | p95 | n | what it is |
|---|---:|---:|---:|---|
| **cold connection box→hub** (DNS cached) | **220.6 ms** | **266.5 ms** | 20 | TCP + TLS + first byte. **Paid per `spool send`** |
| **terminal notifier, synchronous** | **~80-94 ms** | **~86-109 ms** | 12+12 | `spool-notify.sh`, its *cheapest* path (no live pane, exit 5). See §0.4 |
| one round trip box↔hub | 61.5 ms | 66.6 ms | 20 | irreducible; TCP connect phase |
| `spool send` process, local mode | 21.5 ms | 28.2 ms | 20 | whole CLI: spawn + runtime init + cnf + file write |
| **the file mailbox write** | **0.062 ms** | — | 26k+ | `Store.DeliverTo`, 80-byte chat line |
| sign + verify + frame encode/decode | **~0.26 ms** | — | 10k+ | the entire in-process protocol, 80-byte line |

Commands that produce these (each carries its own check):

```
curl -s -o /dev/null -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}\n' https://dev.api.spool-hub.ai/version   # x20
go test ./internal/spool -run '^$' -bench BenchmarkDeliver -benchmem -count 3
go test ./internal/wire  -run '^$' -bench BenchmarkProtocol -benchmem -count 3
```

### 0.1 What this rules OUT

- **The file mailbox is not the latency.** 0.062 ms is **0.1 % of one round
  trip** and 0.0003 of the 300 ms budget. Replacing 002 with a streaming store
  would buy back a tenth of a millisecond and cost the durable, replayable,
  CLI-readable log that every agent on a box depends on. **Do not do it.**
- **A binary / length-prefixed frame is not justified.** The brief admits one
  only if JSON encode/decode is a real cost. It is not: the *entire* in-process
  protocol — canonicalise, sign, verify, encode and decode — is ~0.26 ms for an
  interactive line, ~0.4 % of one round trip. A binary frame would risk the
  canonical signing bytes (CLE-3388's rules) to save noise. **Rejected, on the
  measurement.**
- **There is no polling loop on either interactive leg** to remove. (The 2-second
  `outbox-watch.sh` scan the owner may be thinking of is fleet tooling in
  a separate fleet-tooling repo, a different lane — reported, not touched.)

### 0.2 What it rules IN — the two real costs

**C1 — one cold connection per reply (220.6 ms p50, 266.5 ms p95).**
`hubclient.SendMessage → sendNow → Dial(role=cli)`
(`internal/hubclient/flush.go`) opens a **brand-new WebSocket per outbound
message**: TCP, TLS, HTTP upgrade, challenge, hello, welcome — then one frame,
then close. The sidecar is holding a *warm, authenticated socket to the same
hub* the whole time. Every desk-agent reply pays ~220 ms to rebuild what is
already open, before its hello even starts.

**C2 — the terminal leg blocks the socket read loop (~80-94 ms p50).**
`notify.Run` is called **synchronously** inside `spool.Store.writeBox`, which
runs inside `Session.receive`, which runs inside the sidecar's `readLoop`. So
for ~80-94 ms per delivered message the box **cannot read its next `recv`
frame**. Two messages back to back: the second waits that long behind the first
*and then pays its own*. That is head-of-line blocking on the delivery leg — and it is
paid for a step whose own contract (028 FR-006) says it "never fails a
delivery" and is "logged and forgotten".

Together C1 and C2 are **~300-315 ms p50** on a 300 ms budget, in hops that
carry no message semantics at all. Neither is a protocol-format problem; both are
*connection-lifetime* and *concurrency* problems.

### 0.4 A correction to this spec's own first draft

The first version of this table read **170.5 ms p50** for the notifier. That
number was wrong and the way it was wrong is worth keeping, because it is the
shape of error this repo's measurement rule exists to catch.

It was not merely stale. The tree measured (`dc102e7`) already contained
CLE-3435's notifier fix (`4206bcb`). The defect was in the *invocation*: the
command was run through a `sudo -u <BOX_USER> env … bash` hop, and **that hop
alone costs 21.0 ms p50** (`sudo -u <BOX_USER> env X=1 bash -c true`, n=12);
the remainder
looks like cold page cache on the script's first runs.

Clean re-measurement, no sudo hop, tree `dc102e7`, n=12, exit-5 path:
**94.0 ms p50 / 109.0 ms p95**. CLE-3435, who owns that path, reads
**80 ms p50 / 86 ms p95** (n=12, tree `4206bcb`) on a cleaner invocation.
Both are used above; theirs is the one to quote.

The conclusion the table supports does not move - the notifier is still two
orders of magnitude above the file hop and still blocks the read loop - but a
number that was going to be traded against protocol complexity was out by ~2x,
and it was out because of how it was called, not what it measured.

### 0.3 The recommendation

**Stream on the interactive path; keep the file as the durable log.** This is
ORC's reading and the measurement supports it:

1. **FP-1 — the terminal leg stops blocking the read loop.** Queue it per
   recipient, drain it on a worker. Order per agent is preserved; the socket
   keeps reading. Removes C2 (~80-94 ms) from the delivery leg.
   **Owned by CLE-3435**, not by this lane: ORC assigned it event-driven
   notify / pane render / receipt, and it asked this lane not to spend budget
   there. A working implementation built here before that was known (a
   per-recipient `notify.Queue` plus `spool.Store.WithNotifier`) was handed to
   CLE-3435 rather than landed, so the two lanes do not collide. This spec
   keeps FR-002/FR-003 as the requirement it must satisfy.
2. **FP-2 — a box reply goes out over the sidecar's ALREADY-WARM socket**
   instead of dialling a new one. The CLI hands the signed envelope to the
   local sidecar over a unix socket; the sidecar writes it on the hub session it
   already holds. Removes C1 (~220 ms) from the reply leg. The CLI still writes
   the outbox and the pending file **first**, so the durable record and the
   crash-safety of `contracts/flush.md` are unchanged, and the fallback when no
   sidecar is listening is exactly today's `role=cli` dial.
3. **Nothing about the message envelope changes.** `v:1` stays frozen, `v:2`
   readers stay as 020 left them, and the canonical signing bytes are untouched.

**Trade-offs the owner decides:**

| | FP-1 (async terminal leg, CLE-3435) | FP-2 (local submit socket, this lane) |
|---|---|---|
| wins | ~80-94 ms on every delivery | ~220 ms on every reply |
| risk | a notifier now runs after `writeBox` returns; a crash in the gap loses the *poke*, never the message (the file is already written) | a new local IPC surface on the box; needs a fallback path and a permissions story (0700, owner-only) |
| size | small, contained in `internal/notify` + the sidecar | larger: new listener, new frame, capability negotiation |
| reversible | yes — one cnf flag back to synchronous | yes — remove the socket and the CLI dials as today |

FP-2 is what this lane builds: it is the largest single cost either lane has
measured (220.6 ms p50), it is unambiguously a client/protocol change, and it is
the piece that needs the capability negotiation in §2. FP-1 lands in CLE-3435's
lane against the same FR-002/FR-003.

---

## 0.5 The result, measured live on dev

FP-2 landed. `do_spl_wire_probe` measures the reply leg both ways against a
live hub: same probe box, same message shape, same CLI process spawn in both
legs, so the delta is the connection and nothing else.

**Version**: hub `0.1.17`, commit `39a5a25ae53df8436359ad64f49e42dcb271bb03`
(`GET https://dev.api.spool-hub.ai/version`, printed by the probe itself).
**Tree**: probe landed at `5784d1d`. **Tenant**: `t1` on dev, probe box
`box-wire-probe`, which sends only to itself. **n**: 20 per leg (a 10-per-leg
run half an hour earlier agreed: 608.0 / 281.0).

| leg | p50 | p95 | min | max |
|---|---:|---:|---:|---:|
| **dial** — pre-030, a cold socket per send | 588.0 ms | 1580.4 ms | 536 | 1607 |
| **submit** — 030, the sidecar's warm socket | **231.5 ms** | **401.2 ms** | 118 | 424 |
| **delta** | **−356.5 ms** | **−1179.2 ms** | | |

Reproduce:

```
ENV=dev TENANT_ID=t1 WIRE_N=20 DRY_RUN=0 ./run -a do_spl_wire_probe
```

Three things worth reading carefully before this number is re-used:

1. **It is the REPLY LEG, not the whole round trip.** It is one hop of
   CLE-3435's budget, not the budget.
2. **Both legs include the CLI process spawn** (21.5 ms p50 on its own), and
   both ran on a box carrying ~20 live agents, which is why the absolute
   numbers are above the 220.6 ms transport figure in §0. The *delta* is the
   claim; the absolutes are this box on this afternoon.
3. **It was measured against the DEPLOYED 0.1.17 hub, and that is not a
   caveat — it is the design.** FP-2 is box-side. The hub serves the identical
   envelope either way and cannot tell the paths apart, which is exactly what
   the byte-identity control asserts. A hub deploy ships the new binary; it is
   not what makes the win appear.

### 0.6 Deployment status

**FP-2 is deployed and serving on dev and prd** as image tag `0.1.18`, rolled
2026-09-21 13:34 (revision `csi-spl-hub-dev-00032-rlz`; deploy and post-deploy
smoke jobs green in both envs). Its commit `74394b9` contains FP-2 — checked
with `git merge-base --is-ancestor fb0dac9 74394b9`, not read off a run colour.

The keepalive fix (§0.7) landed after that image was built, so it ships in
`0.1.19`.

**A tag bump is three files per env, and getting that wrong turns trunk red.**
The tag is derived into `<env>.env.json` and
`<env>/tf/030-cloud-run-hub.vars.tfvars`, because terraform owns the image.
Bumping the yaml alone fails `cloud-actions.tst.sh` ("action `…:0.1.18` vs 030
`…:0.1.17`") and `tpl-gen-step-render-parity.tst.sh`, in two separate CI jobs.
This lane did exactly that and reverted (`cba622e`).

Rendering the other two is **`./run -a do_tpl_gen`** from `csi-spl-iac`: a plain
HOST action — a pinned tpl-gen checkout and a Python venv writing into the cnf
tree. It is *not* `make do-generate-config-for-step`, which goes through the
tf-runner and is the one this repo treats as one stack per box. The revert
message here originally confused the two and gave unsafe-sounding advice for a
command that is in fact safe; CLE-3437 corrected it.

**`/version` is not the image tag.** `GET /version` read `0.1.17` while both
services ran image `0.1.18`: the tag comes from cnf `hub.image.ref`, but the
version *string* comes from the repo-root `.version`, baked in by
`csi-spl-api/src/bash/build.sh` as `-X main.version`. Nothing kept them in step,
so a deploy checked by the version string alone reads one release behind what is
actually running. `2e4c1ce` moves both together. **The `commit` field is the one
that never lies** — prefer it for any deploy check.

### 0.7 Keepalive — a dead socket stops being a silent one

Found while this lane was open, by CLE-3438's acceptance bot and CLE-3434's
live reading of a stalled desk. **The hub has pinged its peers since 017
FR-SEC-004; the client never did.** A box socket that black-holed left the
sidecar blocked in `wsjson.Read` for ever on a session it still believed was up:

```
16:10:51  hub session up / submit listener up
16:19:18  last message written to CLE-00's inbox
16:30:01  hub session up          <- a RESTART, not a recovery
```

CLE-3434's reading is what settles it: `GET /v1/view/roster` said
`box-desk online=FALSE` while `ss -tnp` still showed the socket `ESTAB`.

**Nothing was lost.** The messages from that window landed at 16:30:01, the
instant the sidecar reconnected and the hub's queue drained. The durable path
worked exactly as designed; the liveness path did not exist. Those are different
defects with different fixes, and only one of them was broken — worth stating,
because the symptom reads as loss.

A `role=box` session now pings every 30 s and closes the socket when no pong
arrives within 10 s; the read loop then fails and `Run` redials with the backoff
it already had. It can only END a session, never fail a message. It does not
make a stall impossible — it **bounds** it, to ~40 s instead of "until a human
notices". `KeepAlive` / `KeepAliveTimeout` on `hubclient.Client` are the knobs.

## 1. Requirements

- **FR-001** — Every change in this spec is justified by a measurement in §0 or
  by one added to the benchmarks named there. A change with no number behind it
  does not ship.
- **FR-002** — The terminal leg (028) MUST NOT block the sidecar's socket read
  loop. Deliveries to one agent keep their order; a slow or hanging notifier
  delays no other message and no other agent.
- **FR-003** — The terminal leg keeps every guarantee 028 gives it: it never
  fails a delivery, it never rings a message that was not written (FR-003
  there), and `SPOOL_NOTIFY_CMD` unset still means "behave exactly as before".
- **FR-004** — A box reply SHOULD reuse a warm hub connection when the box runs
  a sidecar, and MUST fall back to today's `role=cli` dial when it does not.
  No message is lost or duplicated by either path or by a reconnect across it.
- **FR-005** — Capability negotiation: a peer announces what it can do in the
  `hello`; an old client against a new hub, and a new client against an old hub,
  both keep working unchanged (the 020 mixed-fleet rule).
- **FR-006** — Signatures and canonical bytes are unchanged. `v:1` stays frozen.
  A message that crosses a fast path MUST be byte-identical to the same message
  across the slow one.
- **FR-007** — Rollback is a cnf flag per fast path, no redeploy of a peer
  required, and no stored data migrated.

## 2. Capability negotiation

The `hello` frame gains one optional field, `caps`, a sorted list of short
tokens. It is **not signed** — exactly as `msg_versions` is not (020
`migration.md` §3) — so `HelloPayload` and every existing signature are
untouched (FR-006).

```
hello: { type, box_id, ts, nonce, sig, role, agents?, channels?, msg_versions?, caps? }
```

Rules:

- Absent or empty `caps` = a pre-030 peer. The hub MUST behave exactly as it
  does today for it. This is what keeps every deployed box working.
- The hub answers with its own `caps` on the `welcome`. A client that sees a
  capability missing MUST use the old path; it MUST NOT fail.
- An unknown token is ignored, never an error, in both directions. That is what
  lets a newer box talk to an older hub.
- A capability is a *permission to use a faster path*, never a change to what a
  message means. Removing one from cnf returns the pair to the slow path on the
  next hello, which is the rollback in FR-007.

Tokens defined by this spec live in `contracts/fastpath-v1.md`.

## 3. Migration and rollback

- **FP-1** ships in the box binary. No peer coordination: it changes when a
  local process runs, not what crosses the wire. Rollback: `SPOOL_NOTIFY_ASYNC=0`
  restores the synchronous call.
- **FP-2** ships in the box binary too; the hub is unaffected, because the
  envelope the sidecar writes on its warm socket is the same envelope the CLI
  would have written on a cold one. Rollback: stop the sidecar listener
  (`SPOOL_SUBMIT_SOCKET` unset) and every CLI falls back to the `role=cli` dial.
- No stored row, no envelope and no signature changes, so there is nothing to
  migrate and nothing to undo in the database.

## 4. Controls (the tests that would catch this being wrong)

- A `v:1`-only box (no `msg_versions`, no `caps`) exchanges mail both ways.
- A new client against a hub that advertises no `caps` falls back and succeeds.
- A hanging notifier delays neither the next message to the same agent nor any
  message to another agent, and the socket keeps reading (FR-002).
- Order per recipient is preserved under concurrent deliveries.
- A message sent over a fast path is **byte-identical** to the same message sent
  over the slow one, signature included (FR-006).
- No message is lost or duplicated across a reconnect that straddles the paths.

## 5. Out of scope

- The model's own turn (~14 s on the owner's live path). Not ours to fix, and it
  dwarfs everything in §0 — which is exactly why this spec refuses to spend risk
  on hops that cost microseconds.
- The hub's internal DB ordering (027, and CLE-3435's hop table).
- The browser leg's render cost (CLE-3434).
- The separate fleet-tooling repo, including its 2-second `outbox-watch.sh` scan.
