# Contract: Hub transport for a rented tenant

Extends `003/contracts/http-v1.md`. Public rental. See `SPEC-spool-trust-modes.md`.

Tenant from URL. **Send/recv = WebSocket. Files/pins = REST.**

## WebSocket `wss://<tenant-host>/v1/ws`

1. Hello `{ "box_id", "ts", "sig" }` — box key, pin table.
2. Announce `{ "agents": ["CLE-07", ...] }`.
3. Send envelope `{ "from_box", "to_box", "msg": <v:1 no sig>, "sig" }`.
   Two boxes may both have `msg.to=CLE-07`; `to_box` disambiguates; missing
   `to_box` + ambiguous → 409. Second pin of same `box_id` different key → 409.
4. Recv/ack frames for announced agents on this connection.

No open `GET /v1/messages?as=`. No per-agent recv signature (the box hello is the proof).

## REST
## Pins

`POST /v1/pins` `{ "box_id", "pubkey", "ts", "sig" }` — `sig` = **tenant root**. Pins **boxes**.
`DELETE /v1/pins/{box_id}` — body `{ "ts", "sig" }` root-signed.
`GET /v1/pins` — list pubkeys (not secret). Optional but useful for sync.

## Files

`POST /v1/files` — counts against tenant PUT quota.
`GET /v1/files/{id}` — tenant-scoped; knowing sha256 is the capability
(content addressing). Still no cross-tenant.

## Billing codes

`402` unpaid (send/pin). `429` quota. Recv not gated by quota.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T15:20:00Z -->
