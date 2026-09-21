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
| **terminal notifier, synchronous** | **170.5 ms** | **178.0 ms** | 12 | `spool-notify.sh`, its *cheapest* path (no live pane, exit 5) |
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
  `ysg-box`, a different repo and a different lane — reported, not touched.)

### 0.2 What it rules IN — the two real costs

**C1 — one cold connection per reply (220.6 ms p50, 266.5 ms p95).**
`hubclient.SendMessage → sendNow → Dial(role=cli)`
(`internal/hubclient/flush.go`) opens a **brand-new WebSocket per outbound
message**: TCP, TLS, HTTP upgrade, challenge, hello, welcome — then one frame,
then close. The sidecar is holding a *warm, authenticated socket to the same
hub* the whole time. Every desk-agent reply pays ~220 ms to rebuild what is
already open, before its hello even starts.

**C2 — the terminal leg blocks the socket read loop (170.5 ms p50).**
`notify.Run` is called **synchronously** inside `spool.Store.writeBox`, which
runs inside `Session.receive`, which runs inside the sidecar's `readLoop`. So
for 170 ms per delivered message the box **cannot read its next `recv` frame**.
Two messages back to back: the second waits 170 ms behind the first *and then
pays its own*. That is head-of-line blocking on the delivery leg — and it is
paid for a step whose own contract (028 FR-006) says it "never fails a
delivery" and is "logged and forgotten".

Together C1 and C2 are **~390 ms p50** on a 300 ms budget, in hops that carry no
message semantics at all. Neither is a protocol-format problem; both are
*connection-lifetime* and *concurrency* problems.

### 0.3 The recommendation

**Stream on the interactive path; keep the file as the durable log.** This is
ORC's reading and the measurement supports it:

1. **FP-1 — the terminal leg stops blocking the read loop.** Queue it per
   recipient, drain it on a worker. Order per agent is preserved; the socket
   keeps reading. Removes C2 (~170 ms) from the delivery leg.
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

| | FP-1 (async terminal leg) | FP-2 (local submit socket) |
|---|---|---|
| wins | ~170 ms on every delivery | ~220 ms on every reply |
| risk | a notifier now runs after `writeBox` returns; a crash in the gap loses the *poke*, never the message (the file is already written) | a new local IPC surface on the box; needs a fallback path and a permissions story (0700, owner-only) |
| size | small, contained in `internal/notify` + the sidecar | larger: new listener, new frame, capability negotiation |
| reversible | yes — one cnf flag back to synchronous | yes — remove the socket and the CLI dials as today |

FP-1 is small, safe and wins the larger share of a *delivery*; it lands first.
FP-2 wins the reply leg and is the piece that needs the capability negotiation
in §2.

---

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
- `ysg-box` fleet tooling, including the 2-second `outbox-watch.sh` scan.
