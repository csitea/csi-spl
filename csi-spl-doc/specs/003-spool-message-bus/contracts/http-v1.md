# Contract: Hub transport v1 (box CLI hides this; agents never call it)

Stateless Cloud Run, **HTTPS + WebSocket**. The box CLI/MCP is the only client;
agents never call these endpoints directly (Constitution VIII).

Normative sources, in order: `../../002-box-agent-messaging/contracts/trust-modes.md` §4–§5
(binding owner decision), then this file, then
`../../006-spool-hub-rental/contracts/http-rental.md` (tenant, pins, billing).
The inner message is the frozen 002 object
(`../../002-box-agent-messaging/contracts/message-schema.md`), unchanged.

Tenant = request **Host** (`<tenant>.<product-domain>`, from cnf). No path
prefix, and no `tenant_id` field in `v:1`.

## Endpoint inventory (every row maps to an FR in `../spec.md`)

```
WS   /v1/ws                     # hello, roster, send envelope, recv frames      FR-001, 003–006
POST /v1/files                  # upload bytes, box proof → { file_id, sha256, bytes }   FR-007
GET  /v1/files/{file_id}        # tenant-scoped capability: bytes or short-lived signed URL   FR-007
GET  /v1/pins                   # owned by 004/006 (authorized_keys sync)
POST /v1/pins                   # owned by 004/006 (tenant-root signed)
DELETE /v1/pins/{box_id}        # owned by 004/006 (tenant-root signed)
GET  /healthz                   # liveness                                        FR-001
GET  /version                   # { version, commit, built_at }                   FR-001
```

**Removed from v1 pending OQ-02 / OQ-04** (were in the 0.1.0 draft of this
file; they are listed here so that nobody implements them from an old copy):

| Endpoint | Why removed |
|---|---|
| `POST /v1/messages` | send moved to the WS envelope; per-agent `sig` no longer exists in hub mode |
| `GET /v1/messages?as=&task_id=` | open, unsigned read of an inbox; recv is WS frames after box hello |
| `GET /v1/events` (SSE) | live-tail transport undecided (OQ-04) |

## WS `/v1/ws`

Frame catalogue. The **field sets** come from trust-modes §4–§5. The frame
`type` discriminator, ack frames, and close codes are **not yet specified**
(OQ-03, OQ-05, OQ-08).

| # | Direction | Content | Hub rule |
|---|---|---|---|
| 1 | box → hub | hello `{ box_id, ts, sig }`, box key | pin lookup `(tenant, box_id)`; unknown → close. Last hello wins: an older socket for the same `box_id` is closed |
| 2 | box → hub | roster: agent ids from the dir scan `$SPOOL_ROOT/*/` | duplicate id **on this box** → 409; same id on another box is fine. Re-sent when the set changes |
| 3 | box → hub | send `{ from_box, to_box?, msg, sig }` | `from_box` == hello box; verify `sig`; resolve `to_box` (FR-005); idempotent on `msg_id` (FR-010); reply `delivery` |
| 4 | hub → box | send result `{ msg_id, task_id, ts, delivery }` | `delivery` ∈ `sent`, `queued` |
| 5 | hub → box | recv frame: envelope for an agent announced on this box | the box re-verifies `sig` against its **locally synced** pin; missing → local refuse `78` |

Signing payload: `jq -cS '{from_box,to_box,msg}'` over the envelope without
`sig`; the inner `msg` has no `sig`. The canonical-JSON rules are 002
`contracts/canonical-json.md`.

## POST /v1/files / GET /v1/files/{file_id}

- POST requires box proof (the mechanism is OQ-10). Anonymous PUT → refused.
- Bytes stored at `t/<tenant_id>/files/<sha256>` in **one** bucket. No metadata
  object. The hub computes `file_id` = sha256 of the received bytes.
- GET is a tenant-scoped **capability**: knowing the sha256 inside the tenant
  is enough, and no box key is required. Another tenant's `file_id` → 404.
- GET streams bytes or hands back a short-lived signed URL (TTL in
  `./limits.md`). The URL is never logged or persisted (Constitution VII). The
  box CLI re-hashes and refuses a mismatch without writing a partial file.

## Trust & ingress

- **Box key** is both the door and the author of a frame (hello, envelope,
  file PUT). The hub does not verify agent identity; `from` is asserted by the box.
- **Tenant root key** only pins/revokes box pubkeys (004/006).
- **IAM/OIDC** is not part of the public product. On a private deploy it MAY
  sit in front and MUST run before box-key verification (OQ-06).
- Same-box mail does not touch the hub (`delivery=local`) unless
  `$SPOOL_MIRROR_LOCAL` is true (`./flush.md`).

## Failure semantics

| Failure | Response |
|---|---|
| unpinned box at hello | close; nothing stored |
| bad envelope `sig`, or `from_box` ≠ hello box | refuse (`bad_sig`), nothing stored; CLI exit `78` |
| ambiguous `to` without `to_box` | 409 `ambiguous_to_box` |
| `to_box` has no live socket | persist with TTL, `delivery=queued` (not an error) |
| notify transport down (after M1) | row still lands in PG; tail stale until catch-up |
| GCS down | refuse file PUT (exit `1`); text-only send: OQ-11 |
| hub unreachable | box keeps cross-box sends pending-flush; flush later (`./flush.md`) |

## Invariants

- Same inner `v:1` JSON on the wire as `002` writes to disk (no migration).
- Cloud Run is stateless: no mail, queue, file bytes or WS session state on container disk.
- Kind of agent is not a field, only the `from`/`to` id prefix.
- No per-kind routes.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:24:00+03:00 -->
