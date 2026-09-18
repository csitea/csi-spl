# Contract: Hub transport for a rented tenant

Extends `003/contracts/http-v1.md`. Public rental. See `SPEC-spool-trust-modes.md`.

Tenant from URL. **Send/recv = WebSocket. Files/pins = REST.**

## WebSocket `wss://<tenant-host>/v1/ws`

1. Hello `{ "box_id", "ts", "sig" }` — box key, pin table.
   **Last hello wins** (new socket closes the old one for that `box_id`).
   Tenant Host: `<tenant>.spool-hub.ai` (env in binaries).
2. Announce = scan `$SPOOL_ROOT/*/` (agent-id dirs).
3. Send envelope `{ "from_box", "to_box", "msg", "sig" }`.
   Ambiguous `to` without `to_box` → 409. Live WS → `delivery=sent`; else
   hub queue (TTL cnf) and `delivery=queued` (no receiver ack).
4. Recv/ack frames for announced agents on this connection.
   Renter-chosen `box_id`; same id different key → 409.

No open `GET /v1/messages?as=`. No per-agent recv signature (the box hello is the proof).

## REST
## Pins

`POST /v1/pins` `{ "box_id", "pubkey", "ts", "sig" }` — `sig` = **tenant root**. Pins **boxes**.
`DELETE /v1/pins/{box_id}` — body `{ "ts", "sig" }` root-signed.
`GET /v1/pins` — list pubkeys (not secret). Optional but useful for sync.

## Files

`POST /v1/files` — **box key required**; counts against tenant PUT quota.
`GET /v1/files/{id}` — tenant-scoped **capability** (sha256). No box key
on GET. No cross-tenant.

## Billing codes

`402` unpaid (send/pin). `429` quota. Recv not gated by quota.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:45:00Z -->
