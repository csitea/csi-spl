# Contract: Hub HTTP for a rented tenant

Extends `003/contracts/http-v1.md`. Public rental deployment.

Tenant is selected by the request URL (`Host` or `/t/<tenant>/` — one scheme
in cnf). All rows are scoped to that tenant.

## Send

`POST /v1/messages` — body is `v:1` including `sig`. Verify pin of `from` in
**this tenant**. No IAM. Unpinned/bad sig → 400.

## Recv (replaces open GET-by-as on public hubs)

```
POST /v1/recv
{ "as": "CLE-07", "ack": false, "task_id": "<uuid or omit>", "ts": "<RFC3339 Z>", "sig": "<b64>" }
```

Sign canonical `del(.sig)` with `as`’s key. `|ts-now|>5m` → 400.
`ack: true` records ack for `as` only.

Private deployments MAY still offer `GET /v1/messages?as=` behind org IAM;
the **product** CLI uses POST /v1/recv whenever `$SPOOL_HUB_URL` is set.

## Pins

`POST /v1/pins` `{ "id", "pubkey", "ts", "sig" }` — `sig` = **tenant root**.
`DELETE /v1/pins/{id}` — body `{ "ts", "sig" }` root-signed.
`GET /v1/pins` — list pubkeys (not secret). Optional but useful for sync.

## Files

`POST /v1/files` — counts against tenant PUT quota.
`GET /v1/files/{id}` — tenant-scoped; knowing sha256 is the capability
(content addressing). Still no cross-tenant.

## Billing codes

`402` unpaid (send/pin). `429` quota. Recv not gated by quota.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T14:10:00Z -->
